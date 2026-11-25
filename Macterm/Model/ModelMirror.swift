import Foundation
import Observation
import os

private let logger = Logger(subsystem: appBundleID, category: "ModelMirror")

// The model of the app: the copy of the model on the Mac server (design/010
// §4), and the objects that the views draw from it. `ModelMirror` is the one
// writer of `SplitBranch` and `TerminalTab`: their setters are `fileprivate`,
// so the compiler refuses a change from any other file. A change goes to the
// server as a request (`ModelWriter`), and comes back here in a batch.

/// One split of the tree. `first`, `second` and `direction` never change: a
/// new shape makes new branches with the same `id`, so a view keyed by it
/// keeps its identity. Only the ratio changes in place.
@MainActor @Observable
final class SplitBranch: Identifiable {
    let id: UUID
    let direction: SplitDirection
    fileprivate(set) var ratio: CGFloat
    let first: SplitNode
    let second: SplitNode

    init(id: UUID = UUID(), direction: SplitDirection, ratio: CGFloat = 0.5, first: SplitNode, second: SplitNode) {
        self.id = id
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

extension SplitNode {
    /// Whether both nodes are the same object (the same pane or branch).
    func isSame(as other: SplitNode) -> Bool {
        switch (self, other) {
        case let (.pane(a), .pane(b)): a === b
        case let (.split(a), .split(b)): a === b
        default: false
        }
    }
}

/// A tab: a tree of panes, as the server's model has it.
@MainActor @Observable
final class TerminalTab: Identifiable {
    let id: UUID
    fileprivate(set) var customTitle: String?
    fileprivate(set) var splitRoot: SplitNode
    fileprivate(set) var focusedPaneID: UUID?
    /// When set, the split tree renders only this pane (zoom). The server
    /// keeps it in memory: it outlives a quit of the app, not a restart of
    /// the server.
    fileprivate(set) var zoomedPaneID: UUID?

    /// Bumped by every ratio change that should ANIMATE: the keyboard resize
    /// (`AppState.splitResize`, sent with `animated`). The batch of that
    /// request carries its `cause`, and the mirror bumps this in the same
    /// change (design/010 §4). `SplitLayout.animationKey` folds it in, so the
    /// frames that follow animate like a split. A divider drag and the
    /// control CLI's `pane resize-split` do not bump it: a drag must follow
    /// the pointer, and a script that sets a ratio then reads pane widths
    /// must see the geometry it asked for. In memory only.
    fileprivate(set) var animatedResizeGeneration = 0

    init(id: UUID, splitRoot: SplitNode, focusedPaneID: UUID?, customTitle: String? = nil) {
        self.id = id
        self.splitRoot = splitRoot
        self.focusedPaneID = focusedPaneID
        self.customTitle = customTitle
    }

    /// The fallback "Terminal" stays English: `tab list` reports this title
    /// and `tab select` matches it, so it is CLI output too.
    var autoTitle: String {
        let panes = splitRoot.allPanes()
        if panes.isEmpty { return "Terminal" }
        return panes.map(\.sidebarSegmentTitle).joined(separator: " | ")
    }

    var sidebarTitle: String { customTitle ?? autoTitle }

    /// The sidebar row's single-tab title (#227): a rename always wins, and an
    /// unrenamed split of four or more panes is too dense to enumerate — its
    /// row just counts them. Smaller splits render per-pane containers in the
    /// sidebar, so this only surfaces for the single-tab row shapes.
    var sidebarRowTitle: String {
        if customTitle == nil {
            let paneCount = splitRoot.allPanes().count
            if paneCount >= 4 {
                return String(localized: "\(paneCount) panes", comment: "Sidebar title of a tab with four or more panes")
            }
        }
        return sidebarTitle
    }

    /// The AI-agent logo for this tab's sidebar row: the focused pane's
    /// running agent, else the first pane running one. nil when no pane has
    /// an agent in the foreground (the user's chosen tab icon shows instead).
    var agentIcon: AgentIcon? {
        if let icon = focusedPane?.agentIcon { return icon }
        for pane in splitRoot.allPanes() {
            if let icon = pane.agentIcon { return icon }
        }
        return nil
    }

    /// The tab's status dot. Running comes from the panes' run state. Done
    /// comes from the session's flag `Pane.attention.unseen`.
    var executionState: TerminalExecutionState {
        let panes = splitRoot.allPanes()
        if panes.contains(where: { $0.executionState == .running }) { return .running }
        if panes.contains(where: \.attention.unseen) { return .done }
        return .idle
    }

    /// The tab's done dot is red: the ended run of a pane failed
    /// (`Pane.attention.failed`). Running wins over failed, and failed wins
    /// over the success of another pane.
    var completionFailed: Bool {
        executionState == .done && splitRoot.allPanes().contains { $0.attention.unseen && $0.attention.failed }
    }

    var focusedPane: Pane? {
        guard let focusedPaneID else { return nil }
        return splitRoot.findPane(id: focusedPaneID)
    }

    /// A pane of the tab rang the bell, and nobody showed it since
    /// (`Pane.attention.bell`). The Dock badge counts tabs
    /// (`BellBadge.tabCount`).
    var hasUnseenBell: Bool {
        splitRoot.allPanes().contains(where: \.attention.bell)
    }

    /// Looking at the tab marks every pane seen, not only the focused pane.
    /// Otherwise a split pane next to the focused one keeps its dot.
    func markSeen() {
        for pane in splitRoot.allPanes() {
            pane.markSeen()
        }
    }
}

/// The GUI's copy of the model on the Mac server (design/010 §4): the state
/// of `state.subscribe`, then each event batch, applied in one main-actor
/// turn. The views read the objects that it builds from the values:
/// `projects`, the `TerminalTab`s of each project and their `Pane`s.
///
/// Objects keep their identity across batches: a tab, a branch and a pane
/// with the same id are the same object, so SwiftUI animates a change of
/// the tree as it did a change in memory, and a pane keeps its surfaces and
/// its session link. A pane that leaves the model goes to
/// `onPanesRemoved`, which destroys its surfaces.
@MainActor @Observable
final class ModelMirror {
    /// Nil until `install`, and on a server with no model.
    private(set) var data: MactermProtocol.ModelData?
    /// The zoomed pane of each tab that has one, by tab id. The server keeps
    /// zoom in memory only, so it is not in `data`.
    private(set) var zoomed: [String: String] = [:]
    /// The batch that `data` includes last. A batch with a `seq` that is not
    /// higher is in `data` already.
    private(set) var seq: UInt64 = 0
    private(set) var epoch: UInt64?
    /// The server cannot write its model (design/010 §2): every request
    /// fails with `model_readonly`.
    private(set) var readonly = false
    /// Batches that came before `install`, in order.
    @ObservationIgnored private var early: [(ServerEventBatch, Bool)] = []

    // MARK: The objects

    /// Every project of the model, the hidden ones too, in the server's
    /// order.
    private(set) var projects: [Project] = []
    /// The tabs of each project, in order.
    private(set) var tabsByProject: [UUID: [TerminalTab]] = [:]
    /// The active tab of each project that has one.
    private(set) var activeTabIDs: [UUID: UUID] = [:]
    /// The project that the key window showed last (`select.set`).
    private(set) var selectedProjectID: UUID?
    /// Every pane of the model, by id.
    @ObservationIgnored private(set) var panes: [UUID: Pane] = [:]
    /// Panes that the app made for a request that is on its way: the
    /// projection takes these objects, so a new pane keeps its start
    /// command and its environment.
    @ObservationIgnored private var registered: [UUID: Pane] = [:]
    /// The tab of each tab id, in any project.
    @ObservationIgnored private var tabTable: [UUID: TerminalTab] = [:]
    @ObservationIgnored private var tabProjects: [UUID: UUID] = [:]
    /// The tabs that each project showed, most recent first, for Recent Tab
    /// and for the order of the tab switcher. GUI only.
    @ObservationIgnored private var tabHistory: [UUID: RecencyStack<UUID>] = [:]
    /// The wire id of each id that is not a UUID string as the app writes
    /// it (a model that another client wrote).
    @ObservationIgnored private var wireIDs: [UUID: String] = [:]
    /// While set, a change of a project's active tab is not a visit: the
    /// Ctrl+Tab cycle (`ModelWriter.tabPeek`).
    @ObservationIgnored var peeking = false

    /// Panes that left the model in a batch, with the server's record of
    /// each (`pane.removed`). The app destroys their surfaces and ends a
    /// remote pane's session.
    @ObservationIgnored var onPanesRemoved: (([Pane], [MactermProtocol.PaneRemoved]) -> Void)?
    /// The project list changed: made, removed, renamed, moved, by any
    /// client. `ProjectStore` passes it to its `onSave` (the Spotlight index).
    @ObservationIgnored var onProjectsChanged: (() -> Void)?
    /// A project's active tab changed. The key window's own tab record
    /// follows it (`AppState`).
    @ObservationIgnored var onActiveTabChanged: ((UUID) -> Void)?

    // MARK: Ids

    /// The UUID of a wire id. A wire id that is not a UUID maps to a stable
    /// UUID made from its text, and `wire(_:)` gives the text back.
    func uuid(_ text: String) -> UUID {
        if let id = UUID(uuidString: text) { return id }
        let id = Self.stableUUID(text)
        wireIDs[id] = text
        return id
    }

    /// The wire id of `id`.
    func wire(_ id: UUID) -> String {
        wireIDs[id] ?? id.uuidString
    }

    private static func stableUUID(_ text: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var hash2: UInt64 = 0x8422_2325_CBF2_9CE4
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
            hash2 = (hash2 &+ UInt64(byte)) &* 0x9E37_79B9_7F4A_7C15
        }
        for i in 0 ..< 8 {
            bytes[i] = UInt8(truncatingIfNeeded: hash >> (UInt64(i) * 8))
            bytes[i + 8] = UInt8(truncatingIfNeeded: hash2 >> (UInt64(i) * 8))
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: Reads

    func project(_ id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// The singleton with this alias: `pinned`, `scratch` or `quick`
    /// (design/010 §11, §2). A lookup, never a behavior.
    func project(alias: String) -> Project? {
        projects.first { $0.alias == alias }
    }

    /// The projects of the sidebar tree: the ones that `project list`, the
    /// palette and Spotlight show.
    var treeProjects: [Project] {
        projects.filter(\.isTreeProject)
    }

    func tabs(of projectID: UUID) -> [TerminalTab] {
        tabsByProject[projectID] ?? []
    }

    func activeTabID(of projectID: UUID) -> UUID? {
        activeTabIDs[projectID]
    }

    func activeTab(of projectID: UUID) -> TerminalTab? {
        guard let id = activeTabIDs[projectID] else { return nil }
        return tabTable[id]
    }

    func tab(_ id: UUID) -> TerminalTab? {
        tabTable[id]
    }

    /// The project that holds tab `id`.
    func projectID(ofTab id: UUID) -> UUID? {
        tabProjects[id]
    }

    /// Every tab of every project, by project.
    var allTabs: [(projectID: UUID, tab: TerminalTab)] {
        projects.flatMap { p in tabs(of: p.id).map { (p.id, $0) } }
    }

    func pane(_ id: UUID) -> Pane? {
        panes[id]
    }

    /// The project and the tab of a pane.
    func locate(pane id: UUID) -> (projectID: UUID, tab: TerminalTab)? {
        for (projectID, tabs) in tabsByProject {
            if let tab = tabs.first(where: { $0.splitRoot.contains(paneID: id) }) { return (projectID, tab) }
        }
        return nil
    }

    /// The tabs of a project, the active one first, then most recent first.
    func recencyOrder(of projectID: UUID) -> [UUID] {
        let tabs = tabs(of: projectID)
        let valid = Set(tabs.map(\.id))
        var seen = Set<UUID>()
        var order: [UUID] = []
        if let active = activeTabIDs[projectID], valid.contains(active) {
            order.append(active)
            seen.insert(active)
        }
        for id in tabHistory[projectID]?.items ?? [] where valid.contains(id) && seen.insert(id).inserted {
            order.append(id)
        }
        for tab in tabs where seen.insert(tab.id).inserted {
            order.append(tab.id)
        }
        return order
    }

    /// The model's record of pane `id`, as the server has it.
    func paneValue(_ id: UUID) -> MactermProtocol.Pane? {
        let wireID = wire(id)
        for p in data?.projects ?? [] {
            for t in p.tabs {
                if let found = Self.findPane(wireID, in: t.root) { return found }
            }
        }
        return nil
    }

    private static func findPane(_ id: String, in node: MactermProtocol.SplitNode) -> MactermProtocol.Pane? {
        switch node {
        case let .pane(p): p.id == id ? p : nil
        case let .split(s): findPane(id, in: s.first) ?? findPane(id, in: s.second)
        }
    }

    /// The server took `model.import`: no batch carries the flag, so the
    /// mirror sets it.
    func noteImported() {
        data?.importedV1 = true
    }

    // MARK: Registered panes

    /// Takes a pane that the app made for a request it sends now. The
    /// batch of the request finds it here.
    func register(_ pane: Pane) {
        registered[pane.id] = pane
    }

    /// Forgets the panes of a request that failed.
    func unregister(_ ids: [UUID]) {
        for id in ids {
            registered[id] = nil
        }
    }

    // MARK: Install and apply

    /// Forgets the state: a new connection, which can be a new server.
    func reset() {
        data = nil
        zoomed = [:]
        seq = 0
        epoch = nil
        early = []
    }

    /// Takes the state of `state.subscribe`, then the batches that came
    /// after it and before it was installed.
    func install(_ state: MactermProtocol.StateSubscribe.Result) {
        epoch = state.epoch
        seq = state.seq
        data = state.model
        readonly = state.readonly
        zoomed = Dictionary(state.zoomed.map { ($0.tab, $0.pane) }, uniquingKeysWith: { _, last in last })
        let waiting = early
        early = []
        for (batch, _) in waiting {
            applyValues(batch)
        }
        project(animatedTabs: [], removed: [])
    }

    /// Applies one batch. A batch from before the installed state is
    /// skipped. With `animated`, a ratio change of the batch animates
    /// (`TerminalTab.animatedResizeGeneration`).
    func apply(_ batch: ServerEventBatch, animated: Bool = false) {
        guard epoch != nil else {
            early.append((batch, animated))
            return
        }
        guard batch.seq > seq else { return }
        let changedTabs = applyValues(batch)
        var removed: [MactermProtocol.PaneRemoved] = []
        for case let .model(.paneRemoved(e)) in batch.events {
            removed.append(e)
        }
        project(animatedTabs: animated ? changedTabs : [], removed: removed)
    }

    /// Applies the values of a batch to `data`. Returns the ids of the tabs
    /// that a `tab.set` changed.
    @discardableResult
    private func applyValues(_ batch: ServerEventBatch) -> Set<String> {
        guard batch.seq > seq else { return [] }
        seq = batch.seq
        guard var model = data else { return [] }
        var changed: Set<String> = []
        // The server sends what was made or changed first (`tab.order`
        // before the `tab.set` of a new tab), so the order of tabs is set at
        // the end of the batch.
        var orders: [String: [String]] = [:]
        for case let .model(event) in batch.events {
            switch event {
            case let .projectChanged(e):
                if let i = model.projects.firstIndex(where: { $0.id == e.project.id }) {
                    model.projects[i] = Self.project(e.project, tabs: model.projects[i].tabs, activeTab: model.projects[i].activeTab)
                } else {
                    model.projects.append(Self.project(e.project, tabs: [], activeTab: nil))
                }
            case let .projectRemoved(e):
                model.projects.removeAll { $0.id == e.id }
            case let .tabOrder(e):
                guard let i = model.projects.firstIndex(where: { $0.id == e.project }) else {
                    logger.error("model mirror: tab.order for a project that the mirror does not have")
                    continue
                }
                model.projects[i].activeTab = e.activeTab
                orders[e.project] = e.ids
            case let .tabChanged(e):
                // The server sends a project's `project.set` before its tabs.
                guard let i = model.projects.firstIndex(where: { $0.id == e.project }) else {
                    logger.error("model mirror: tab.set for a project that the mirror does not have")
                    continue
                }
                for p in model.projects.indices where p != i {
                    model.projects[p].tabs.removeAll { $0.id == e.tab.id }
                }
                if let t = model.projects[i].tabs.firstIndex(where: { $0.id == e.tab.id }) {
                    model.projects[i].tabs[t] = e.tab
                } else {
                    model.projects[i].tabs.append(e.tab)
                }
                zoomed[e.tab.id] = e.zoomed
                changed.insert(e.tab.id)
            case let .tabRemoved(e):
                if let i = model.projects.firstIndex(where: { $0.id == e.project }) {
                    model.projects[i].tabs.removeAll { $0.id == e.id }
                }
                zoomed[e.id] = nil
            case let .selectionChanged(e):
                model.selection = .init(activeProject: e.activeProject)
            default:
                // `project.order`: each project's `sort_order` has the
                // order. `pane.removed`: the pane's tab event has it.
                break
            }
        }
        for (id, ids) in orders {
            guard let i = model.projects.firstIndex(where: { $0.id == id }) else { continue }
            let tabs = Dictionary(model.projects[i].tabs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            model.projects[i].tabs = ids.compactMap { tabs[$0] }
        }
        data = model
        return changed
    }

    /// A project with the fields of `project.set` and the tabs that the
    /// mirror has: `tab.order` and `tab.set` carry those.
    private static func project(_ info: MactermProtocol.ProjectInfo, tabs: [MactermProtocol.Tab], activeTab: String?) -> MactermProtocol
        .Project
    {
        .init(
            id: info.id,
            name: info.name,
            path: info.path,
            color: info.color,
            sortOrder: info.sortOrder,
            createdAt: info.createdAt,
            parent: info.parent,
            sidebar: info.sidebar,
            singleTab: info.singleTab,
            removable: info.removable,
            alias: info.alias,
            tabs: tabs,
            activeTab: activeTab
        )
    }

    // MARK: The projection

    /// Builds the objects from `data`, and keeps every object whose id
    /// stays. Writes a property only when its value changes, so a view
    /// redraws only for what changed.
    private func project(animatedTabs: Set<String>, removed: [MactermProtocol.PaneRemoved]) {
        let model = data ?? .init()
        let newProjects = model.projects.map { Project(model: $0, id: uuid($0.id), parent: $0.parent.map(uuid)) }
        let projectsChanged = newProjects != projects
        if projectsChanged { projects = newProjects }

        var seenPanes: Set<UUID> = []
        var newTabsByProject: [UUID: [TerminalTab]] = [:]
        var newActive: [UUID: UUID] = [:]
        var newTabTable: [UUID: TerminalTab] = [:]
        var newTabProjects: [UUID: UUID] = [:]
        for p in model.projects {
            let projectID = uuid(p.id)
            var tabs: [TerminalTab] = []
            for value in p.tabs {
                let tabID = uuid(value.id)
                let tab = tabTable[tabID] ?? TerminalTab(id: tabID, splitRoot: .pane(placeholderPane), focusedPaneID: nil)
                update(tab, from: value, projectID: projectID, animated: animatedTabs.contains(value.id), seen: &seenPanes)
                tabs.append(tab)
                newTabTable[tabID] = tab
                newTabProjects[tabID] = projectID
            }
            newTabsByProject[projectID] = tabs
            if let active = p.activeTab.map(uuid), newTabTable[active] != nil { newActive[projectID] = active }
        }
        tabTable = newTabTable
        tabProjects = newTabProjects
        if !Self.sameTabs(newTabsByProject, tabsByProject) { tabsByProject = newTabsByProject }
        let oldActive = activeTabIDs
        if newActive != activeTabIDs { activeTabIDs = newActive }
        let selected = model.selection.activeProject.map(uuid)
        if selected != selectedProjectID { selectedProjectID = selected }

        // The panes that left the model.
        let gone = panes.filter { !seenPanes.contains($0.key) }.map(\.value)
        for pane in gone {
            panes[pane.id] = nil
        }
        for id in seenPanes {
            registered[id] = nil
        }
        if !gone.isEmpty || !removed.isEmpty { onPanesRemoved?(gone, removed) }
        if projectsChanged { onProjectsChanged?() }

        // Tab history and the active-tab funnel.
        for (projectID, active) in newActive where oldActive[projectID] != active && !peeking {
            if let previous = oldActive[projectID] {
                tabHistory[projectID, default: RecencyStack(limit: 50)].push(previous)
            }
            tabHistory[projectID]?.remove(active)
        }
        for (projectID, _) in tabHistory where newTabsByProject[projectID] == nil {
            tabHistory[projectID] = nil
        }
        let changedActive = Set(newActive.keys).union(oldActive.keys).filter { newActive[$0] != oldActive[$0] }
        if !changedActive.isEmpty {
            // Every selection path lands here: it wakes the adaptive
            // foreground poll on a tab switch.
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
            for projectID in changedActive {
                onActiveTabChanged?(projectID)
            }
        }
    }

    private static func sameTabs(_ a: [UUID: [TerminalTab]], _ b: [UUID: [TerminalTab]]) -> Bool {
        guard a.count == b.count else { return false }
        for (key, tabs) in a {
            guard let other = b[key], other.count == tabs.count else { return false }
            for (x, y) in zip(tabs, other) where x !== y {
                return false
            }
        }
        return true
    }

    /// A pane that a new tab holds for one moment, before its tree is set.
    @ObservationIgnored private let placeholderPane = Pane(
        projectPath: NSHomeDirectory(),
        projectID: UUID(),
        sessionName: "macterm-placeholder"
    )

    private func update(_ tab: TerminalTab, from value: MactermProtocol.Tab, projectID: UUID, animated: Bool, seen: inout Set<UUID>) {
        if tab.customTitle != value.customTitle { tab.customTitle = value.customTitle }
        var branches: [UUID: SplitBranch] = [:]
        Self.collectBranches(tab.splitRoot, into: &branches)
        let root = build(value.root, projectID: projectID, branches: branches, seen: &seen)
        if !root.isSame(as: tab.splitRoot) { tab.splitRoot = root }
        let focused = value.focused.map(uuid)
        if tab.focusedPaneID != focused { tab.focusedPaneID = focused }
        let zoom = zoomed[value.id].map(uuid)
        if tab.zoomedPaneID != zoom { tab.zoomedPaneID = zoom }
        if animated { tab.animatedResizeGeneration &+= 1 }
    }

    private static func collectBranches(_ node: SplitNode, into table: inout [UUID: SplitBranch]) {
        guard case let .split(branch) = node else { return }
        table[branch.id] = branch
        collectBranches(branch.first, into: &table)
        collectBranches(branch.second, into: &table)
    }

    private func build(
        _ node: MactermProtocol.SplitNode,
        projectID: UUID,
        branches: [UUID: SplitBranch],
        seen: inout Set<UUID>
    ) -> SplitNode {
        switch node {
        case let .pane(value):
            let id = uuid(value.id)
            let pane = panes[id] ?? registered[id] ?? makePane(value, id: id, projectID: projectID)
            panes[id] = pane
            if pane.projectID != projectID { pane.rebind(projectID: projectID) }
            seen.insert(id)
            return .pane(pane)
        case let .split(value):
            let id = uuid(value.id)
            let first = build(value.first, projectID: projectID, branches: branches, seen: &seen)
            let second = build(value.second, projectID: projectID, branches: branches, seen: &seen)
            let direction: SplitDirection = value.dir == .vertical ? .vertical : .horizontal
            let ratio = CGFloat(value.ratio)
            if let old = branches[id], old.direction == direction, old.first.isSame(as: first), old.second.isSame(as: second) {
                if old.ratio != ratio { old.ratio = ratio }
                return .split(old)
            }
            return .split(SplitBranch(id: id, direction: direction, ratio: ratio, first: first, second: second))
        }
    }

    /// A pane that the model has and the app did not make in this run: a
    /// pane of a restore, or of another client. Its new session starts in
    /// the folder that the model kept (`cwd`), else where it was made.
    private func makePane(_ value: MactermProtocol.Pane, id: UUID, projectID: UUID) -> Pane {
        let pane = Pane(
            projectPath: value.cwd ?? value.originPath,
            projectID: projectID,
            id: id,
            sessionName: value.session.isEmpty ? nil : value.session
        )
        if pane.isRemote { pane.hostSessionDirectory = value.hostSessionDir }
        return pane
    }
}
