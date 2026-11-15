import Foundation

// The tab model: `SplitBranch`, `TerminalTab` and `Workspace`, and
// `ModelWriter`, the one way to change them. Their setters and mutators are
// `fileprivate`, so the compiler refuses a change from any other file. The
// writer's verbs are the requests of design 010 §3; at the cut-over to the
// server's model, only their bodies change.

/// One split of the tree. `first`, `second` and `direction` never change: a
/// structural change builds new branches (`SplitNode`'s tree operations) and
/// keeps each branch's `id`, so a view keyed by it keeps its identity. Only
/// the ratio changes in place, for the divider drag (`ModelWriter.splitRatio`).
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

    /// This branch with the given parts replaced, under the same `id`. The
    /// receiver itself when nothing changes, so an unchanged subtree keeps
    /// its objects.
    func with(ratio: CGFloat? = nil, first: SplitNode? = nil, second: SplitNode? = nil) -> SplitBranch {
        let newRatio = ratio ?? self.ratio
        let newFirst = first ?? self.first
        let newSecond = second ?? self.second
        if newRatio == self.ratio, newFirst.isSame(as: self.first), newSecond.isSame(as: self.second) {
            return self
        }
        return SplitBranch(id: id, direction: direction, ratio: newRatio, first: newFirst, second: newSecond)
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

/// A single tab — owns a split-pane tree.
@MainActor @Observable
final class TerminalTab: Identifiable {
    let id: UUID
    fileprivate(set) var customTitle: String?
    fileprivate(set) var splitRoot: SplitNode
    fileprivate(set) var focusedPaneID: UUID?
    /// When set, the split tree renders only this pane (zoom). The tree
    /// itself is untouched — clearing this restores the full layout.
    /// Transient: not persisted across launches.
    fileprivate(set) var zoomedPaneID: UUID?

    /// Bumped by every ratio change that should ANIMATE — the keyboard
    /// resize (`resize(_:delta:)`), i.e. Resize Split Left/Right/Up/Down from
    /// a keybind, the palette or a menu. `SplitLayout.animationKey` folds it
    /// in, so the frames that follow in the same transaction animate like a
    /// split. A divider drag and the control CLI's `pane resize-split` set
    /// the ratio through `ModelWriter.splitRatio`; neither bumps this, so
    /// both land immediately — a drag must follow the pointer, and a script
    /// that sets a ratio then reads pane widths must see the geometry it
    /// asked for. In memory only, never persisted.
    fileprivate(set) var animatedResizeGeneration = 0
    /// Most-recent-first stack of previously focused pane IDs
    /// (excludes the currently focused pane).
    @ObservationIgnored
    fileprivate(set) var paneFocusHistory = RecencyStack<UUID>(limit: 20)

    /// Record a focus change, pushing the previous pane onto history.
    fileprivate func focusPane(_ paneID: UUID) {
        guard paneID != focusedPaneID else { return }
        if zoomedPaneID != nil, zoomedPaneID != paneID { zoomedPaneID = nil }
        if let current = focusedPaneID { paneFocusHistory.push(current) }
        paneFocusHistory.remove(paneID)
        focusedPaneID = paneID
    }

    /// Pick the next focus target after a pane is removed from the tree.
    /// Walks the history stack (skipping panes no longer in the tree), then
    /// falls back to the first pane in tree order.
    fileprivate func nextFocusAfterClose() -> UUID? {
        let valid = Set(splitRoot.allPanes().map(\.id))
        paneFocusHistory.prune(keeping: valid)
        if let recent = paneFocusHistory.popValid(in: valid) { return recent }
        return splitRoot.allPanes().first?.id
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

    var executionState: TerminalExecutionState {
        let panes = splitRoot.allPanes()
        if panes.contains(where: { $0.executionState == .running }) { return .running }
        if panes.contains(where: { $0.executionState == .done }) { return .done }
        return .idle
    }

    /// Whether the tab's `.done` is a failure — some pane's run reported one
    /// (`Pane.completionFailed`) — which turns its status dot red. A running
    /// pane outranks it exactly as it outranks done, and it outranks a sibling
    /// pane's success: a split where one pane failed and another passed shows
    /// the failure.
    var completionFailed: Bool {
        executionState == .done && splitRoot.allPanes().contains(where: \.completionFailed)
    }

    var focusedPane: Pane? {
        guard let focusedPaneID else { return nil }
        return splitRoot.findPane(id: focusedPaneID)
    }

    @discardableResult
    func acknowledgeCommandCompletion() -> Bool {
        var didAcknowledge = false
        for pane in splitRoot.allPanes() {
            didAcknowledge = pane.acknowledgeCommandCompletion() || didAcknowledge
        }
        return didAcknowledge
    }

    /// Whether any pane of this tab rang BEL and hasn't been looked at since.
    /// The tab is the unit the Dock badge counts (`BellBadge.tabCount`).
    var hasUnacknowledgedBell: Bool {
        splitRoot.allPanes().contains(where: \.hasUnacknowledgedBell)
    }

    /// Looking at the tab acknowledges every pane's bell, not just the
    /// focused pane's — the same whole-tab rule `acknowledgeCommandCompletion`
    /// follows, for the same reason: a split pane that rang would otherwise
    /// keep the badge up while the user sits right next to it.
    @discardableResult
    func acknowledgeBell() -> Bool {
        var didAcknowledge = false
        for pane in splitRoot.allPanes() {
            didAcknowledge = pane.acknowledgeBell() || didAcknowledge
        }
        return didAcknowledge
    }

    init(
        projectPath: String,
        projectID: UUID,
        sessionSlug: String? = nil,
        command: String? = nil,
        env: [String: String]? = nil
    ) {
        id = UUID()
        let pane = Pane(projectPath: projectPath, projectID: projectID, sessionSlug: sessionSlug, command: command, env: env)
        splitRoot = .pane(pane)
        focusedPaneID = pane.id
    }

    init(id: UUID, splitRoot: SplitNode, focusedPaneID: UUID?, customTitle: String? = nil) {
        self.id = id
        self.splitRoot = splitRoot
        self.focusedPaneID = focusedPaneID
        self.customTitle = customTitle
    }

    // MARK: - Split/resize/close operations

    //
    // These live on TerminalTab so both the main-window workspace flow and the
    // quick terminal can share the same split-tree mutation logic. Persistence
    // is the caller's: AppState calls saveWorkspaces itself after each, and
    // QuickTerminalSplitState reports through `onStructureChange`.

    /// Toggle zoom for `paneID`. While zoomed, the tab renders only that pane;
    /// toggling off (or zooming a different pane) restores the full split view.
    fileprivate func toggleZoom(paneID: UUID) {
        guard splitRoot.findPane(id: paneID) != nil else { return }
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
        } else {
            zoomedPaneID = paneID
            focusPane(paneID)
        }
    }

    /// Split the focused pane (or a specific pane) in `direction`, placing the
    /// new pane at `position`. Returns the new pane ID if created.
    /// A `command` spawns in the new pane via libghostty's `initial_input`
    /// (the layout `run:` path — typed into the fresh shell verbatim).
    /// `newPaneWorkingDirectory` overrides cwd inheritance without changing
    /// the source pane's project-scoped session slug. `env` is extra
    /// environment for the new pane's shell. With `focus: false`, preserve
    /// focus, history and zoom; the caller must start a hidden pane.
    @discardableResult
    fileprivate func split(
        paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition = .second,
        command: String? = nil,
        env: [String: String]? = nil,
        newPaneWorkingDirectory: String? = nil,
        focus: Bool = true
    ) -> UUID? {
        // Bail before any side effect if the pane isn't in this tab — otherwise
        // an unknown ID would clear the user's zoom and rebalance ratios for a
        // split that never happens (mirrors toggleZoom/makeGrid's guard).
        guard let pane = splitRoot.findPane(id: paneID) else { return nil }
        // Inherit the source pane's cwd. For a LOCAL pane, prefer the shell's
        // OSC 7-reported pwd (most accurate when shell integration is active),
        // then the foreground process's actual kernel cwd (works without shell
        // integration), and only then the pane's original project path. For a
        // REMOTE pane, `currentPwd` is a remote-filesystem path with no host
        // prefix — inheriting it would spawn the sibling as a LOCAL shell in a
        // bogus dir instead of a remote zmx session — so skip the live cwd and
        // inherit the scp-style `projectPath` verbatim. An explicit
        // `newPaneWorkingDirectory` (the "Project" split preference) wins over
        // the whole chain; the preference resolver passes nil rather than the
        // project root whenever it has no usable LOCAL cwd, precisely so the
        // remote/unattached cases keep falling through to it.
        let livePwd = pane.liveLocalWorkingDirectory()
        let sourcePath = newPaneWorkingDirectory ?? livePwd ?? pane.projectPath
        let sourceProjectID = pane.projectID
        let (newRoot, newID) = splitRoot.splitting(
            paneID: paneID,
            direction: direction,
            position: position,
            projectPath: sourcePath,
            projectID: sourceProjectID,
            command: command,
            env: env
        )
        splitRoot = newRoot
        if focus {
            // A foreground split reveals and focuses the new pane.
            zoomedPaneID = nil
            if let newID { focusPane(newID) }
        }
        if Preferences.shared.autoTilingEnabled { splitRoot = splitRoot.rebalanced() }
        return newID
    }

    /// Insert a mirror of `paneID` beside it — a second pane attached to the
    /// same zmx session (#345). Returns the new pane's ID, or nil when the
    /// pane isn't in this tab.
    ///
    /// Deliberately does NOT focus the new pane, unlike `split`. A mirror is a
    /// second view of work the user is already looking at, so stealing focus
    /// would move it away from the pane they are actually using — and, once
    /// leadership follows focus, would hand the pty size to the new view for
    /// no reason.
    fileprivate func mirror(paneID: UUID, direction: SplitDirection, position: SplitPosition) -> UUID? {
        guard let source = splitRoot.findPane(id: paneID) else { return nil }
        let mirrored = Pane(mirroring: source)
        let (newRoot, inserted) = splitRoot.inserting(
            pane: mirrored,
            at: paneID,
            direction: direction,
            position: position
        )
        guard inserted else { return nil }
        splitRoot = newRoot
        // Inserting reveals a new pane — exit zoom so it's visible.
        zoomedPaneID = nil
        if Preferences.shared.autoTilingEnabled { splitRoot = splitRoot.rebalanced() }
        return mirrored.id
    }

    /// Split a pane into a `rows`×`columns` grid of equal cells (row-major),
    /// optionally spawning `command` in every NEW pane. The source pane
    /// becomes the top-left cell and keeps its running shell — a command
    /// can only be injected at spawn (`initial_input`), so the caller runs
    /// text into it separately if needed. `newPaneWorkingDirectory` overrides
    /// cwd inheritance for every new cell, exactly as in `split`. Returns the
    /// new pane IDs.
    @discardableResult
    fileprivate func makeGrid(
        paneID: UUID,
        rows: Int,
        columns: Int,
        command: String? = nil,
        newPaneWorkingDirectory: String? = nil
    ) -> [UUID] {
        guard rows >= 1, columns >= 1, rows * columns > 1,
              splitRoot.findPane(id: paneID) != nil
        else { return [] }
        var created: [UUID] = []
        // Build the row column first (splitting the newest pane each time
        // keeps top-to-bottom order), then widen each row left-to-right.
        var rowHeads = [paneID]
        for _ in 1 ..< rows {
            guard let previous = rowHeads.last,
                  let newID = split(
                      paneID: previous,
                      direction: .vertical,
                      command: command,
                      newPaneWorkingDirectory: newPaneWorkingDirectory
                  )
            else { break }
            rowHeads.append(newID)
            created.append(newID)
        }
        for head in rowHeads {
            var current = head
            for _ in 1 ..< columns {
                guard let newID = split(
                    paneID: current,
                    direction: .horizontal,
                    command: command,
                    newPaneWorkingDirectory: newPaneWorkingDirectory
                )
                else { break }
                created.append(newID)
                current = newID
            }
        }
        // Equal cells regardless of the auto-tiling preference — a grid is
        // an explicit request for uniformity.
        splitRoot = splitRoot.rebalanced()
        focusPane(paneID)
        return created
    }

    /// Split the focused pane along its longer on-screen axis (Ghostty's
    /// `new_split` / BSP behavior): a wide pane splits left/right, a tall pane
    /// splits top/bottom. Falls back to a horizontal split when the focused
    /// pane's NSView isn't attached yet and has no measurable bounds. The
    /// caller passes the size the pane is drawn at, because the model holds
    /// no view.
    @discardableResult
    fileprivate func autoSplit(
        paneID: UUID,
        drawnSize: CGSize = .zero,
        command: String? = nil,
        env: [String: String]? = nil,
        newPaneWorkingDirectory: String? = nil
    ) -> UUID? {
        split(
            paneID: paneID,
            direction: SplitDirection.auto(for: drawnSize),
            command: command,
            env: env,
            newPaneWorkingDirectory: newPaneWorkingDirectory
        )
    }

    /// Adjust the nearest matching-axis split ratio around the focused pane.
    /// The keyboard path, and the one ratio change that animates (see
    /// `animatedResizeGeneration`).
    fileprivate func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        guard let paneID = focusedPaneID else { return }
        splitRoot = splitRoot.resizing(paneID: paneID, direction: direction, delta: delta)
        animatedResizeGeneration &+= 1
    }

    /// Swap the focused pane with its neighbor in `direction` — the pane that
    /// Focus Left/Right/Up/Down would go to. The focused pane moves and keeps
    /// focus; the tree shape and the ratios stay. Returns false (tree
    /// unchanged) when there is no focused pane or no neighbor that way.
    @discardableResult
    fileprivate func moveFocusedPane(_ direction: PaneFocusDirection) -> Bool {
        guard let paneID = focusedPaneID,
              let neighborID = splitRoot.nearestPane(from: paneID, direction: direction)
        else { return false }
        splitRoot = splitRoot.swappingPanes(paneID, neighborID)
        return true
    }

    /// Set an absolute ratio on the nearest matching-axis split around a pane
    /// (control CLI `pane resize-split`). Returns false when the pane sits in
    /// no split of that axis.
    fileprivate func setSplitRatio(paneID: UUID, axis: SplitDirection, ratio: CGFloat) -> Bool {
        guard let newRoot = splitRoot.settingRatio(paneID: paneID, axis: axis, ratio: ratio) else { return false }
        splitRoot = newRoot
        return true
    }

    /// Move a pane to a resolved drop target (grab-handle drag): detach it —
    /// the tree collapses around it — and merge its single-pane tree back in
    /// through `mergeTree`, so pane drags share the exact placement code (and
    /// grammar: whole-edge, divider, local) of a sidebar tab drop. The `Pane`
    /// object is reused as-is; surface and shell are untouched. Returns false
    /// (tree unchanged) for a target aimed at the moved pane itself, a pane
    /// the tree doesn't contain, or the only pane in the tab.
    @discardableResult
    fileprivate func movePane(_ paneID: UUID, to target: TabDropResolution.Target) -> Bool {
        switch target {
        case let .pane(destinationID, _),
             let .divider(destinationID, _):
            guard destinationID != paneID else { return false }
        case .rootEdge:
            break
        }
        guard let pane = splitRoot.findPane(id: paneID),
              let detached = splitRoot.removing(paneID: paneID)
        else { return false }
        let original = splitRoot
        splitRoot = detached
        guard mergeTree(.pane(pane), at: target) else {
            splitRoot = original
            return false
        }
        return true
    }

    /// Merge another tab's split tree at a resolved workspace drop target
    /// (#227). Local pane drops keep the halving behavior of a normal split;
    /// divider and root-edge drops ALWAYS equalize the tree, because their
    /// meaning is positional parity — three side-by-side panes reading as
    /// thirds, a whole-edge pane taking its even share.
    @discardableResult
    fileprivate func mergeTree(_ node: SplitNode, at target: TabDropResolution.Target) -> Bool {
        switch target {
        case let .pane(paneID, zone):
            return insertTree(node, at: paneID, zone: zone)
        case let .divider(paneID, zone):
            guard insertTree(node, at: paneID, zone: zone) else { return false }
            splitRoot = splitRoot.rebalanced()
            return true
        case let .rootEdge(zone):
            let first: SplitNode = zone.splitPosition == .first ? node : splitRoot
            let second: SplitNode = zone.splitPosition == .first ? splitRoot : node
            splitRoot = .split(SplitBranch(direction: zone.splitDirection, first: first, second: second))
            zoomedPaneID = nil
            if let paneID = node.allPanes().first?.id { focusPane(paneID) }
            splitRoot = splitRoot.rebalanced()
            return true
        }
    }

    /// Merge another tab's split tree next to one of this tab's panes (#227 —
    /// dragging a sidebar tab into the workspace): the destination pane is
    /// wrapped in a new split with the adopted tree on the `zone` side.
    /// Returns false (tree unchanged) when the pane isn't in this tab.
    @discardableResult
    fileprivate func insertTree(_ node: SplitNode, at destinationPaneID: UUID, zone: PaneDropZone) -> Bool {
        let (newRoot, inserted) = splitRoot.inserting(
            node: node, at: destinationPaneID, direction: zone.splitDirection, position: zone.splitPosition
        )
        guard inserted else { return false }
        splitRoot = newRoot
        zoomedPaneID = nil
        if let paneID = node.allPanes().first?.id { focusPane(paneID) }
        if Preferences.shared.autoTilingEnabled { splitRoot = splitRoot.rebalanced() }
        return true
    }

    /// Remove a pane from the tree. Returns `.onlyPaneLeft` if the caller should
    /// close the whole tab (the pane was the last one), otherwise `.removed`;
    /// `.notFound` when the pane isn't in this tab. The pane's surface is
    /// destroyed for both `.onlyPaneLeft` and `.removed` — callers rely on that
    /// (the quick terminal drops the whole tab on `.onlyPaneLeft` without its
    /// own teardown) — but NOT for `.notFound`.
    @discardableResult
    fileprivate func removePane(_ paneID: UUID) -> PaneRemovalResult {
        guard let pane = splitRoot.findPane(id: paneID) else { return .notFound }
        // Decide the outcome BEFORE the irreversible surface teardown, so a
        // `.notFound`-shaped precondition can't destroy a surface first.
        // `removing` can only return nil when the pane isn't in the tree, which
        // `findPane` already ruled out — but check it before destroying rather
        // than after (the old order destroyed, then could still return
        // `.notFound` with a dead surface).
        let panes = splitRoot.allPanes()
        if panes.count <= 1 {
            SurfaceRegistry.shared.destroySurfaces(of: pane)
            return .onlyPaneLeft
        }
        guard let newRoot = splitRoot.removing(paneID: paneID) else { return .notFound }
        SurfaceRegistry.shared.destroySurfaces(of: pane)
        splitRoot = newRoot
        if zoomedPaneID == paneID { zoomedPaneID = nil }
        paneFocusHistory.remove(paneID)
        if focusedPaneID == paneID {
            focusedPaneID = nextFocusAfterClose()
        }
        if Preferences.shared.autoTilingEnabled { splitRoot = splitRoot.rebalanced() }
        return .removed
    }
}

enum PaneRemovalResult {
    case removed
    case onlyPaneLeft
    case notFound
}

/// The id of a workspace. A project's workspace has the project's id; the
/// other kinds have their own ids (`PinnedTabs.workspaceID`,
/// `ScratchTabs.workspaceID`). It is a UUID, as in design 010 §1, so the
/// model's ids can replace it one for one.
typealias WorkspaceID = UUID

/// What a workspace holds tabs for (design 010 §1).
enum WorkspaceKind: String, Hashable {
    /// The tabs of one project. The only kind in the project list.
    case project
    /// The pinned tabs (`PinnedTabs`).
    case pinned
    /// The tabs of no project (`ScratchTabs`).
    case scratch
    /// The quick terminal's tab.
    case quick
    /// One desktop widget's tab.
    case widget

    /// The kind of a workspace with id `id`: a sentinel's kind, else a
    /// project. The quick terminal's and the widgets' tabs are not in
    /// `AppState.workspaces` yet, so no id names them.
    init(id: WorkspaceID) {
        switch id {
        case PinnedTabs.workspaceID: self = .pinned
        case ScratchTabs.workspaceID: self = .scratch
        default: self = .project
        }
    }
}

/// All tabs of one workspace: a project, the pinned tabs or the scratch tabs.
@MainActor @Observable
final class Workspace: Identifiable {
    let id: WorkspaceID
    let kind: WorkspaceKind
    fileprivate(set) var tabs: [TerminalTab] = []
    fileprivate(set) var activeTabID: UUID? {
        didSet {
            guard activeTabID != oldValue else { return }
            // Every selection path (select/peek/adopt/close) lands here — the
            // one funnel that wakes the adaptive foreground poll on tab switch.
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
            onActiveTabChanged?()
        }
    }

    /// Fired after `activeTabID` changes, from the same funnel. `AppState`
    /// installs it to keep the key window's own tab record in step (#345):
    /// with several windows the active tab is the KEY window's selection, a
    /// mirror of `WindowState.activeTabIDs`, and every writer above — create,
    /// close, cycle, the CLI — has to reach that record without knowing about
    /// windows.
    @ObservationIgnored
    var onActiveTabChanged: (() -> Void)?

    @ObservationIgnored
    private var tabHistory = RecencyStack<UUID>(limit: 50)

    var activeTab: TerminalTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    init(id: WorkspaceID, projectPath: String) {
        self.id = id
        kind = WorkspaceKind(id: id)
        let tab = TerminalTab(projectPath: projectPath, projectID: id)
        tabs.append(tab)
        activeTabID = tab.id
    }

    init(id: WorkspaceID, tabs: [TerminalTab], activeTabID: UUID?) {
        self.id = id
        kind = WorkspaceKind(id: id)
        self.tabs = tabs
        // Validate the supplied activeTabID against the tabs list. A stale id
        // (e.g. from a corrupt persistence snapshot) falls back to the first
        // tab so we never end up with an "active tab" that doesn't exist.
        let validIDs = Set(tabs.map(\.id))
        if let activeTabID, validIDs.contains(activeTabID) {
            self.activeTabID = activeTabID
        } else {
            self.activeTabID = tabs.first?.id
        }
    }

    /// Append without visiting when `focus` is false: a select-and-restore
    /// would publish a transient selection and pollute the recent-tab history.
    /// With no active tab, adopt the new one; there is no selection to preserve.
    @discardableResult
    fileprivate func createTab(
        projectPath: String,
        sessionSlug: String? = nil,
        remoteZmxPath: String? = nil,
        command: String? = nil,
        env: [String: String]? = nil,
        focus: Bool = true
    ) -> TerminalTab {
        let tab = TerminalTab(
            projectPath: projectPath,
            projectID: id,
            sessionSlug: sessionSlug,
            command: command,
            env: env
        )
        // Selection hooks may create window mirrors synchronously. Give them
        // the host configuration too, before publishing the new tab.
        for pane in tab.splitRoot.allPanes() {
            pane.remoteZmxPath = remoteZmxPath
        }
        tabs.append(tab)
        if focus {
            if let current = activeTabID { tabHistory.push(current) }
            activeTabID = tab.id
        } else if activeTabID == nil {
            // No prior selection to preserve or record (normally the last
            // tab was just closed). Keep the workspace selectable.
            activeTabID = tab.id
        }
        return tab
    }

    /// Adopt an existing tab — moved in from another workspace — and make it
    /// active. Unlike `createTab` the `TerminalTab` (and its live panes/surfaces)
    /// is reused as-is; the caller is responsible for having removed it from its
    /// previous workspace first. `index` positions the tab in the list (a
    /// sidebar drop lands at a specific slot); nil / out-of-range appends.
    fileprivate func adoptTab(_ tab: TerminalTab, at index: Int? = nil) {
        if let index, index >= 0, index <= tabs.count {
            tabs.insert(tab, at: index)
        } else {
            tabs.append(tab)
        }
        if let current = activeTabID { tabHistory.push(current) }
        activeTabID = tab.id
    }

    fileprivate func closeTab(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: index)
        tabHistory.remove(tabID)
        guard activeTabID == tabID else { return }
        let valid = Set(tabs.map(\.id))
        if let prev = tabHistory.popValid(in: valid) {
            activeTabID = prev
        } else {
            activeTabID = tabs.last?.id
        }
    }

    @discardableResult
    fileprivate func selectTab(_ tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        if let current = activeTabID, current != tabID { tabHistory.push(current) }
        activeTabID = tabID
        // Selecting a tab is looking at it: its bell is seen (transient, so
        // it never feeds the save decision the return value drives).
        tab.acknowledgeBell()
        return tab.acknowledgeCommandCompletion()
    }

    @discardableResult
    fileprivate func selectNextTab() -> Bool {
        guard tabs.count > 1, let activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return false }
        return selectTab(tabs[(i + 1) % tabs.count].id)
    }

    @discardableResult
    fileprivate func selectPreviousTab() -> Bool {
        guard tabs.count > 1, let activeTabID,
              let i = tabs.firstIndex(where: { $0.id == activeTabID })
        else { return false }
        return selectTab(tabs[(i - 1 + tabs.count) % tabs.count].id)
    }

    /// Builds a recency-ordered list of tab IDs: current tab first, then most-recent-first from history.
    func recencyOrder() -> [UUID] {
        let valid = Set(tabs.map(\.id))
        var seen = Set<UUID>()
        var order: [UUID] = []
        if let active = activeTabID, valid.contains(active) {
            order.append(active)
            seen.insert(active)
        }
        for id in tabHistory.items where valid.contains(id) && seen.insert(id).inserted {
            order.append(id)
        }
        // Append any tabs not in history
        for tab in tabs where seen.insert(tab.id).inserted {
            order.append(tab.id)
        }
        return order
    }

    /// Switch to a tab without recording history (used during Ctrl+Tab cycling).
    fileprivate func peekTab(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    @discardableResult
    fileprivate func selectTabByIndex(_ index: Int) -> Bool {
        guard index >= 0, index < tabs.count else { return false }
        return selectTab(tabs[index].id)
    }

    fileprivate func reorderTabs(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    /// Move an existing tab to an absolute index (the shape a drag-and-drop
    /// insertion offset comes in, as opposed to `reorderTabs`' `IndexSet`/offset
    /// from `List.onMove`). `destination` is interpreted in the pre-removal
    /// coordinate space — the offset SwiftUI's `dropDestination` reports — so it
    /// is adjusted down by one when the tab is dragged toward the end. A no-op
    /// destination (same slot) leaves the array and selection untouched.
    fileprivate func moveTab(_ tabID: UUID, toIndex destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let to = Self.resolvedMoveIndex(from: from, toDropOffset: destination, count: tabs.count)
        guard to != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    /// Resolve a drag-and-drop insertion offset into the element's final
    /// index. `destination` is in the PRE-removal coordinate space — the
    /// offset SwiftUI's `dropDestination` reports — so it is adjusted down by
    /// one when the element moves toward the end. One home for the
    /// convention: the pinned records reorder speaks it too, and a duplicated
    /// copy of this arithmetic is exactly how off-by-one drift starts.
    static func resolvedMoveIndex(from: Int, toDropOffset destination: Int, count: Int) -> Int {
        let clamped = max(0, min(destination, count))
        let to = clamped > from ? clamped - 1 : clamped
        return max(0, min(to, count - 1))
    }
}

// MARK: - The writer

/// The one way to change the tab model. Every other file reads it.
///
/// Each verb is named after its request in design 010 §3 (`tab.set` is
/// `tabSet`, `split.ratio` is `splitRatio`). A verb with no request there is
/// GUI logic that the cut-over turns into one or more of them (`splitResize`
/// becomes `split.ratio`, `paneSwap` two `pane.move`s). Persistence is the
/// caller's: `AppState` saves after a change, and the quick terminal reports
/// through `QuickTerminalSplitState.onStructureChange`.
@MainActor
enum ModelWriter {
    // MARK: tab.*

    /// `tab.create`: a new tab with one pane.
    @discardableResult
    static func tabCreate(
        in workspace: Workspace,
        projectPath: String,
        sessionSlug: String? = nil,
        remoteZmxPath: String? = nil,
        command: String? = nil,
        env: [String: String]? = nil,
        focus: Bool = true
    ) -> TerminalTab {
        workspace.createTab(
            projectPath: projectPath,
            sessionSlug: sessionSlug,
            remoteZmxPath: remoteZmxPath,
            command: command,
            env: env,
            focus: focus
        )
    }

    /// The destination half of `tab.move`: put a tab that left another
    /// workspace into this one, at `index` (nil appends). With `select`, it
    /// becomes the active tab.
    static func tabInsert(_ tab: TerminalTab, into workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        if select {
            workspace.adoptTab(tab, at: index)
        } else {
            workspace.tabs.insert(tab, at: min(index ?? workspace.tabs.count, workspace.tabs.count))
        }
    }

    /// `tab.close`, and the source half of `tab.move`.
    static func tabClose(_ tabID: UUID, in workspace: Workspace) {
        workspace.closeTab(tabID)
    }

    /// `tab.set`: rename. nil goes back to the automatic title.
    static func tabSet(_ tab: TerminalTab, title: String?) {
        tab.customTitle = title
    }

    /// Give a tab a new tree (Apply Layout keeps the tab and swaps its tree).
    static func tabSetTree(_ tab: TerminalTab, root: SplitNode, focusedPaneID: UUID?) {
        tab.splitRoot = root
        tab.focusedPaneID = focusedPaneID
    }

    /// `tab.select`. Returns whether looking at the tab acknowledged a
    /// finished run (the caller saves then).
    @discardableResult
    static func tabSelect(_ tabID: UUID, in workspace: Workspace) -> Bool {
        workspace.selectTab(tabID)
    }

    @discardableResult
    static func tabSelectNext(in workspace: Workspace) -> Bool {
        workspace.selectNextTab()
    }

    @discardableResult
    static func tabSelectPrevious(in workspace: Workspace) -> Bool {
        workspace.selectPreviousTab()
    }

    @discardableResult
    static func tabSelect(index: Int, in workspace: Workspace) -> Bool {
        workspace.selectTabByIndex(index)
    }

    /// Make `tabID` the active tab with no history and no acknowledgement:
    /// the Ctrl+Tab cycle, and a workspace restored with no selection. nil
    /// clears the selection.
    static func tabPeek(_ tabID: UUID?, in workspace: Workspace) {
        if let tabID {
            workspace.peekTab(tabID)
        } else {
            workspace.activeTabID = nil
        }
    }

    /// `tab.reorder` with a drop offset (see `Workspace.moveTab`).
    static func tabReorder(_ tabID: UUID, in workspace: Workspace, toIndex destination: Int) {
        workspace.moveTab(tabID, toIndex: destination)
    }

    /// `tab.reorder` in the shape of `List.onMove`.
    static func tabReorder(in workspace: Workspace, fromOffsets source: IndexSet, toOffset destination: Int) {
        workspace.reorderTabs(fromOffsets: source, toOffset: destination)
    }

    /// Replace every tab of the workspace (Apply Layout).
    static func tabReplaceAll(in workspace: Workspace, with tabs: [TerminalTab], activeTabID: UUID?) {
        workspace.tabs = tabs
        workspace.activeTabID = activeTabID
    }

    /// `tab.merge`: put another tab's tree into this tab at `target`.
    @discardableResult
    static func tabMerge(_ tab: TerminalTab, tree node: SplitNode, at target: TabDropResolution.Target) -> Bool {
        tab.mergeTree(node, at: target)
    }

    // MARK: pane.*

    /// `pane.split`. Returns the new pane's id. See `TerminalTab.split`.
    @discardableResult
    static func paneSplit(
        _ tab: TerminalTab,
        paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition = .second,
        command: String? = nil,
        env: [String: String]? = nil,
        newPaneWorkingDirectory: String? = nil,
        focus: Bool = true
    ) -> UUID? {
        tab.split(
            paneID: paneID,
            direction: direction,
            position: position,
            command: command,
            env: env,
            newPaneWorkingDirectory: newPaneWorkingDirectory,
            focus: focus
        )
    }

    /// `pane.split` with `dir: auto`: along the pane's longer axis on screen.
    @discardableResult
    static func paneAutoSplit(
        _ tab: TerminalTab,
        paneID: UUID,
        drawnSize: CGSize = .zero,
        command: String? = nil,
        env: [String: String]? = nil,
        newPaneWorkingDirectory: String? = nil
    ) -> UUID? {
        tab.autoSplit(
            paneID: paneID,
            drawnSize: drawnSize,
            command: command,
            env: env,
            newPaneWorkingDirectory: newPaneWorkingDirectory
        )
    }

    /// A second pane on the session of `paneID` (`pane mirror`).
    static func paneMirror(_ tab: TerminalTab, paneID: UUID, direction: SplitDirection, position: SplitPosition) -> UUID? {
        tab.mirror(paneID: paneID, direction: direction, position: position)
    }

    /// `grid RxC`: split a pane into equal cells. Returns the new pane ids.
    @discardableResult
    static func paneGrid(
        _ tab: TerminalTab,
        paneID: UUID,
        rows: Int,
        columns: Int,
        command: String? = nil,
        newPaneWorkingDirectory: String? = nil
    ) -> [UUID] {
        tab.makeGrid(
            paneID: paneID,
            rows: rows,
            columns: columns,
            command: command,
            newPaneWorkingDirectory: newPaneWorkingDirectory
        )
    }

    /// `pane.close`. Destroys the pane's surface (see `TerminalTab.removePane`).
    @discardableResult
    static func paneClose(_ tab: TerminalTab, paneID: UUID) -> PaneRemovalResult {
        tab.removePane(paneID)
    }

    /// `pane.move` within a tab.
    @discardableResult
    static func paneMove(_ tab: TerminalTab, paneID: UUID, to target: TabDropResolution.Target) -> Bool {
        tab.movePane(paneID, to: target)
    }

    /// Move Pane: swap the focused pane with its neighbor in `direction`.
    @discardableResult
    static func paneSwap(_ tab: TerminalTab, direction: PaneFocusDirection) -> Bool {
        tab.moveFocusedPane(direction)
    }

    /// `pane.separate` for every pane of the tab but the first: each goes to
    /// a new tab right after it, and the tab stays selected.
    static func paneSeparateAll(_ tab: TerminalTab, in workspace: Workspace) {
        guard let index = workspace.tabs.firstIndex(where: { $0 === tab }) else { return }
        let panes = tab.splitRoot.allPanes()
        guard panes.count > 1, let firstPane = panes.first else { return }
        tab.splitRoot = .pane(firstPane)
        tab.zoomedPaneID = nil
        tab.paneFocusHistory = RecencyStack(limit: 20)
        tab.focusedPaneID = firstPane.id
        for (offset, pane) in panes.dropFirst().enumerated() {
            let newTab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
            workspace.tabs.insert(newTab, at: index + 1 + offset)
        }
        workspace.selectTab(tab.id)
    }

    /// The source half of `pane.separate`, and of a pane's move to another
    /// tab: take the pane out of the tree without ending it. The tree, zoom
    /// and focus are repaired as in `paneClose`, but the surface lives on.
    /// nil when the pane is not in the tab or is its only pane.
    @discardableResult
    static func paneDetach(_ tab: TerminalTab, paneID: UUID) -> Pane? {
        guard tab.splitRoot.allPanes().count > 1,
              let pane = tab.splitRoot.findPane(id: paneID),
              let remaining = tab.splitRoot.removing(paneID: paneID)
        else { return nil }
        tab.splitRoot = remaining
        if tab.zoomedPaneID == paneID { tab.zoomedPaneID = nil }
        tab.paneFocusHistory.remove(paneID)
        if tab.focusedPaneID == paneID {
            tab.focusedPaneID = tab.nextFocusAfterClose()
        }
        if Preferences.shared.autoTilingEnabled { tab.splitRoot = tab.splitRoot.rebalanced() }
        return pane
    }

    /// `pane.focus`.
    static func paneFocus(_ tab: TerminalTab, paneID: UUID) {
        tab.focusPane(paneID)
    }

    /// `pane.zoom` as a toggle: zoom `paneID`, or unzoom when it is zoomed.
    static func paneZoom(_ tab: TerminalTab, toggling paneID: UUID) {
        tab.toggleZoom(paneID: paneID)
    }

    /// Put each pane of `replacements` (by id) in the place of the old pane,
    /// and move focus and zoom with it (Restart Session).
    static func paneReplace(_ tab: TerminalTab, _ replacements: [UUID: Pane]) {
        tab.splitRoot = tab.splitRoot.replacing(replacements)
        if let focused = tab.focusedPaneID, let new = replacements[focused] { tab.focusedPaneID = new.id }
        if let zoomed = tab.zoomedPaneID, let new = replacements[zoomed] { tab.zoomedPaneID = new.id }
    }

    // MARK: split.*

    /// `split.ratio` for one branch: the divider drag. Not animated.
    static func splitRatio(_ branch: SplitBranch, ratio: CGFloat) {
        branch.ratio = ratio
    }

    /// `split.ratio` for the nearest branch of `axis` around a pane (control
    /// CLI `pane resize-split`). Not animated. False when no such branch.
    @discardableResult
    static func splitRatio(_ tab: TerminalTab, paneID: UUID, axis: SplitDirection, ratio: CGFloat) -> Bool {
        tab.setSplitRatio(paneID: paneID, axis: axis, ratio: ratio)
    }

    /// Resize Split Left/Right/Up/Down: a relative, animated `split.ratio`
    /// around the focused pane.
    static func splitResize(_ tab: TerminalTab, direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        tab.resize(direction, delta: delta)
    }

    /// Equal shares for every pane of the tab (the `rebalance` of a request).
    static func splitRebalance(_ tab: TerminalTab) {
        tab.splitRoot = tab.splitRoot.rebalanced()
    }
}
