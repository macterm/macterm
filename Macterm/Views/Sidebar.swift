import SwiftUI
import UniformTypeIdentifiers

/// A sidebar row's content region extends past the selection highlight's
/// trailing edge. A short label never reaches out there, but content that
/// fills the row — split segments, the merge drop slot, a fading title —
/// does, and reads as overflowing the highlight. Every row applies this
/// trailing inset at its root so all of them stop at the same edge.
private let rowTrailingInset: CGFloat = 10

/// The hit box of a project row's hover-revealed new-tab action.
private let projectActionSize: CGFloat = 18

/// Gap between a project's title and that action.
private let projectActionGap: CGFloat = 4

/// The action's inset from the row's trailing edge — NEGATIVE, because it
/// deliberately sits past `rowTrailingInset` rather than inside it.
///
/// That inset exists to stop row *content* reading as overflowing the
/// selection highlight, and a trailing accessory is not content: the List
/// draws each row's background (the highlight) well past the line content
/// stops at, and that strip is exactly where a trailing control belongs.
/// Respecting the inset instead stranded the plus short of the row's visual
/// end with an empty gutter to its right.
///
/// The target is the row's own visual right end: the trailing edge of the
/// selection highlight the List draws behind a selected row. That is what
/// the eye reads as where the row stops, and it sits a few points past the
/// content region — hence the negative inset. The overhang is MEASURED
/// against a selected tab row's capsule, because SwiftUI exposes no metric
/// for a List row's background insets; deriving it from `rowTrailingInset`
/// instead put the action's box a full half-width past the highlight.
private let sidebarRowHighlightOverhang: CGFloat = 3

private let projectActionTrailingInset: CGFloat = -sidebarRowHighlightOverhang

/// The title's trailing inset while the action is revealed. `max` is the
/// contract, not a nicety: the title yields room ONLY if the action's box
/// would otherwise reach back over it, and can never end up WIDER on hover
/// than at rest. With the metrics above the box does reach back over the
/// content stop line, so a revealed title yields 9pt and takes it straight
/// back — and if the action ever moves far enough right to clear that line
/// on its own, this collapses to `rowTrailingInset` and the title stops
/// moving at all, without anything else needing to change.
private let projectActionRevealedInset: CGFloat = max(
    rowTrailingInset,
    projectActionTrailingInset + projectActionSize + projectActionGap
)

/// How the reveal is animated. Matches `PaneDragDrop`'s hover treatment.
private let projectActionRevealAnimation: Animation = .easeInOut(duration: 0.12)

@MainActor
enum SidebarLayoutMetrics {
    static let topContentMargin: CGFloat = 4
    static let idlePinDropHeight: CGFloat = 8
}

/// Keeps the sidebar footer above scrolling rows, using the native macOS 26
/// scroll-edge fade when available.
private extension View {
    @ViewBuilder
    func sidebarSafeAreaBar(
        isPresented: Bool,
        paintsFallbackBackground: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if isPresented {
            if #available(macOS 26.0, *) {
                safeAreaBar(edge: .bottom, spacing: 0) {
                    content()
                }
            } else {
                safeAreaInset(edge: .bottom, spacing: 0) {
                    content()
                        .background {
                            if paintsFallbackBackground { MactermTheme.bg }
                        }
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func sidebarScrollEdgeEffects(enabled: Bool) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                scrollEdgeEffectStyle(.soft, for: .bottom)
            } else {
                self
            }
        } else {
            self
        }
    }
}

/// In-app drag payload for a sidebar tab row. Carries the tab's identity plus
/// its source project so a drop can tell a same-project reorder from a
/// cross-project move. `TerminalTab` itself is a live reference type (owns
/// surfaces) and must never be encoded/serialized — only these two UUIDs
/// travel, and the drop looks the tab back up by id.
struct MovableTab: Codable, Transferable {
    let tabID: UUID
    let sourceProjectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mactermTab)
    }
}

/// In-app drag payload for a sidebar project header — the project's id.
/// Project reordering is driven by this drag rather than `List`'s `.onMove`,
/// because `.onMove` puts the whole List in reorder mode and hijacks the tab
/// rows' `.draggable` gesture (so tab drag-and-drop never fired). With both
/// projects and tabs on the Transferable path, they coexist.
struct MovableProject: Codable, Transferable {
    let projectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mactermProject)
    }
}

extension UTType {
    static let mactermTab = UTType(exportedAs: "com.thdxg.macterm.tab-move")
    static let mactermProject = UTType(exportedAs: "com.thdxg.macterm.project-move")
}

/// Import-side union of the drag payloads a project HEADER accepts, so a
/// single view can accept all of them through ONE `.dropDestination`. This
/// exists because stacking two `.dropDestination`s (one per payload type) on
/// the same view is non-deterministic: only one of the two registrations
/// wins, and which one flips with unrelated view changes — measured live, the
/// project header accepted project drops in one build and silently rejected
/// them in the next. Never stack drop destinations; widen the payload instead.
/// Import-only: drags still lift as `MovableTab`/`MovableProject` (their
/// `CodableRepresentation` is JSON, which is what the decoders here parse) or,
/// for a pane, as the raw UUID bytes an `NSDraggingSession` writes.
enum SidebarDropItem: Transferable {
    case tab(MovableTab)
    case project(MovableProject)
    case pane(MovablePane)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .mactermTab) { data in
            try .tab(JSONDecoder().decode(MovableTab.self, from: data))
        }
        DataRepresentation(importedContentType: .mactermProject) { data in
            try .project(JSONDecoder().decode(MovableProject.self, from: data))
        }
        DataRepresentation(importedContentType: .mactermPaneID) { data in
            guard let pane = MovablePane(payload: data) else {
                throw CocoaError(.coderInvalidValue)
            }
            return .pane(pane)
        }
    }
}

/// The narrower union the tab-list ForEach accepts: a tab (reorder/move) or a
/// pane (separate into a new tab), both of which want the insertion offset the
/// ForEach reports. Deliberately NOT `SidebarDropItem` — including the project
/// payload here would make a project drag target the tab rows, which is the
/// state the header comment calls out as broken at this outline level: the
/// insertion line would appear inside a section a project can't land in. The
/// two unions are separate views' payloads, not stacked destinations.
enum TabSlotDropItem: Transferable {
    case tab(MovableTab)
    case pane(MovablePane)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .mactermTab) { data in
            try .tab(JSONDecoder().decode(MovableTab.self, from: data))
        }
        DataRepresentation(importedContentType: .mactermPaneID) { data in
            guard let pane = MovablePane(payload: data) else {
                throw CocoaError(.coderInvalidValue)
            }
            return .pane(pane)
        }
    }
}

struct SidebarContent: View {
    @Environment(AppState.self)
    private var appState
    /// This window's selection (#345) — the sidebar belongs to one window, so
    /// every "which project" question it asks is about that window, not about
    /// whichever one happens to be frontmost.
    @Environment(WindowState.self)
    private var windowState
    @Environment(ProjectStore.self)
    private var projectStore
    @AppStorage(Preferences.Keys.showNewProjectButton)
    private var showNewProjectButton: Bool
    @Bindable
    private var presentation: SidebarPresentationState
    private let isInteractive: Bool
    private let paintsFallbackFooterBackground: Bool
    private let forcesScrollEdgeEffects: Bool

    init(
        presentation: SidebarPresentationState,
        isInteractive: Bool,
        paintsFallbackFooterBackground: Bool = true,
        forcesScrollEdgeEffects: Bool = false
    ) {
        self.presentation = presentation
        self.isInteractive = isInteractive
        self.paintsFallbackFooterBackground = paintsFallbackFooterBackground
        self.forcesScrollEdgeEffects = forcesScrollEdgeEffects
    }

    var body: some View {
        List(selection: $presentation.selection) {
            // Pinned tabs live above every project as flat rows (no header,
            // no disclosure), wrapped in a headerless Section so their ForEach
            // sits inside a container — mirroring the tab ForEach below, whose
            // `.dropDestination` insertion line works there while the same
            // API on a BARE top-level ForEach crashes the outline accept (see
            // the project ForEach's notes below). The drop mechanism is the
            // native insertion line, exactly like a project's tab list: the
            // ForEach reports the insertion offset, a drop pins (or reorders /
            // separates a pane) at that slot, and rows carry NO destinations
            // of their own (a row-level target would kill the line — see
            // `tabRow`). The always-available target — and the ONLY one when
            // no pinned rows exist yet — is the pin drop zone strip above the
            // list (see `PinTabDropZone`).
            Section {
                ForEach(Array(appState.pinnedRecords.enumerated()), id: \.element.id) { index, record in
                    pinnedRow(record: record, index: index)
                }
                .dropDestination(for: TabSlotDropItem.self) { items, offset in
                    for item in items {
                        switch item {
                        case let .tab(tab):
                            receivePinnedTabDrop(tab, at: offset)
                        case let .pane(pane):
                            // The offset counts RECORDS (unloaded rows
                            // included) — the pinned-aware API owns the
                            // conversion to the live-tab index.
                            appState.separatePaneIntoPinned(pane.paneID, atRecordIndex: offset)
                        }
                    }
                }
            }
            // The project tree (design 013): a group is a disclosure of
            // its rows, and a project is a disclosure of its tabs.
            ForEach(SidebarTree.nodes(in: projectStore)) { node in
                treeRow(node)
            }
            // Scratch tabs (#665) live below every project as flat rows, the
            // mirror of the pinned rows above: no header, and no separator.
            // Their icon (`ScratchTabs.iconSymbol`) is what says which rows
            // these are, as the pin does above. They follow the last project
            // at the List's own row spacing: a Section around them added its
            // gap, about 13 pt, above the first row. Drawn only while there
            // are scratch tabs, or while this window shows the workspace (the
            // user closed the last scratch tab and is still there). The
            // `.dropDestination` insertion line works on this bare ForEach:
            // its rows are flat, not the DisclosureGroups that crash the
            // project ForEach's accept (see the notes below).
            if showsScratchRows {
                ForEach(Array(scratchTabs.enumerated()), id: \.element.id) { tabIndex, tab in
                    tabRow(tab: tab, index: tabIndex, project: ScratchTabs.project)
                }
                .dropDestination(for: TabSlotDropItem.self) { items, offset in
                    for item in items {
                        switch item {
                        case let .tab(tab):
                            receiveTabDrop([tab], into: ScratchTabs.project, at: offset)
                        case let .pane(pane):
                            receivePaneDrop([pane], into: ScratchTabs.project, at: offset)
                        }
                    }
                }
            }
            // Project reordering is a `MovableProject` drag from one header
            // onto another (see `projectHeader`); the context menus' Move
            // Up/Down are the fallback for precision moves. There is NO
            // insertion-line path for projects — every native mechanism is
            // broken at this outline level, each verified live, so don't
            // re-attempt them:
            // - `.onMove` puts the List in reorder mode and hijacks the tab
            //   rows' `.draggable` (tab drag-and-drop never fired).
            // - `.dropDestination(for:)` on this OUTER ForEach (whose rows
            //   are DisclosureGroups) AND the legacy `.onInsert(of:)` both
            //   crash identically on drop inside SwiftUI's outline machinery
            //   (OutlineListCoordinator.outlineView(_:acceptDrop:…) →
            //   HeterogeneousCollection.element(at:) assertion; macOS 27).
            //   The insertion LINE renders fine during the hover — it is the
            //   accept that dies, so it can't even be risked as a cosmetic.
            //   The tab ForEach below can use the same API because its rows
            //   are one level down in the outline.
            // - A List-level catch-all never fires: the outline view claims
            //   every drag over the sidebar, so unhandled drops don't bubble
            //   to enclosing views.
        }
        // A single list-level context menu instead of one per row: the native
        // multi-select menu. Its closure receives the exact set the menu should
        // act on — right-clicking inside a multi-selection yields all selected
        // rows; right-clicking an unselected row yields just that row. This is
        // what lets "Remove N Projects" / "Close N Tabs" work.
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            contextMenu(for: items)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, SidebarLayoutMetrics.topContentMargin, for: .scrollContent)
        .sidebarScrollEdgeEffects(enabled: forcesScrollEdgeEffects)
        .scrollPosition(id: Binding(
            get: { presentation.scrollPosition },
            set: { position in
                guard isInteractive else { return }
                presentation.scrollPosition = position
            }
        ))
        // The pin drop zone: a strip above the list. It lives OUTSIDE the
        // List on purpose — a plain view's `.dropDestination` has none of the
        // outline view's drop hazards (see the notes inside the List body),
        // and it exists even with zero pinned rows, so the FIRST pin can be a
        // drag too. It only draws its "Pin Tab" band in exactly that case:
        // once a pinned row exists, the native insertion line above it says
        // the same thing, and the band on top of it is noise.
        .safeAreaInset(edge: .top, spacing: 0) {
            // Same handlers as the insertion line, fixed at the first slot
            // — the strip and the line are one operation, so a routing fix
            // in one can't strand the other.
            PinTabDropZone(
                showsBand: appState.pinnedRecords.isEmpty,
                onPinTab: { receivePinnedTabDrop($0, at: 0) },
                onPinPane: { appState.separatePaneIntoPinned($0.paneID, atRecordIndex: 0) }
            )
        }
        .sidebarSafeAreaBar(
            isPresented: showNewProjectButton,
            paintsFallbackBackground: paintsFallbackFooterBackground
        ) {
            HStack(spacing: 0) {
                // The New Project screen of the palette: a typed path, a
                // remote spec, or Select in Finder.
                Button {
                    openNewProjectScreen()
                } label: {
                    Label("New Project", systemImage: "plus")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 36)
            // Not 16: the two edges are padding the label's *layout* box, whose
            // slack differs per edge — the leading side bearing of the `plus`
            // symbol pushes its ink ~4.5pt in, while the line box ends ~0.5pt
            // below the text's descender. Measured on a build, 16/20 is what
            // puts the ink an equal ~20.5pt off both the left and bottom edges.
            .padding(.bottom, 20)
        }
        .onChange(of: orderedItems, initial: true) { _, items in
            presentation.orderedItems = items
        }
        .onChange(of: presentation.selection) { _, items in
            // Whatever collapses the sidebar to a single row becomes the row a
            // later shift-click extends from — a native click on a row's icon
            // or padding, a title click, or `syncSelection` after a tab switch.
            // Watching the selection rather than writing the anchor at each
            // click site is what keeps ours and AppKit's the same row.
            // A group row is never selected (design 013). If the List puts
            // one in the selection all the same, the selection goes back to
            // the active row.
            if items.contains(where: \.isGroup) {
                syncSelection()
                return
            }
            if items.count == 1 { presentation.selectionAnchor = items.first }
            // Navigation follows a single selection only. A multi-selection is
            // for bulk actions (delete), so it must not yank the active project
            // or tab around as rows are added to the selection.
            guard isInteractive, items.count == 1, let item = items.first else { return }
            switch item {
            case .group:
                return
            case let .project(projectID):
                guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
                appState.showProjectScreen(project, in: windowState)
            case let .tab(PinnedTabs.workspaceID, tabID):
                // Loaded → select; unloaded → restore from declaration.
                appState.selectPinnedTab(tabID)
            case let .tab(ScratchTabs.workspaceID, tabID):
                appState.selectScratchTabs(in: windowState)
                appState.selectTab(tabID, projectID: ScratchTabs.workspaceID, in: windowState)
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }) {
                    appState.selectProject(project, in: windowState)
                    appState.selectTab(tabID, projectID: projectID, in: windowState)
                }
            }
        }
        .onChange(of: windowState.activeProjectID) {
            // `WindowState` opens the section of the new project itself.
            syncSelection()
        }
        .onChange(of: activeTabID) {
            syncSelection()
        }
        .onAppear {
            syncSelection()
        }
        // A folder dropped anywhere on the sidebar opens as a project. Over
        // everything, including the rows' own drop targets, which it can't
        // disturb: it takes file drags only (see `SidebarFolderDropTarget`).
        .overlay {
            SidebarFolderDropTarget(isEnabled: isInteractive) { paths in
                openDroppedFolders(paths)
            }
        }
    }

    /// Folders dropped on the sidebar: a project each, the last selected in
    /// this window and scrolled into view — new projects go to the end of the
    /// list, which may be well below the fold.
    private func openDroppedFolders(_ paths: [String]) {
        guard let project = appState.openProjects(atPaths: paths, store: projectStore, in: windowState) else { return }
        windowState.expandedRows.insert(project.id)
        presentation.scrollPosition = .project(project.id)
    }

    // MARK: - Pinned rows

    /// One pinned row: loaded (a live tab, standard row treatment with a pin
    /// icon) or unloaded (dimmed; selecting it rebuilds the tab from its
    /// declaration). Draggable only — drops are the enclosing ForEach's
    /// native insertion line (see `body`), and a row-level destination would
    /// kill it, same as `tabRow` documents.
    private func pinnedRow(record: PinnedTabRecord, index: Int) -> some View {
        Group {
            if let tab = appState.pinnedWorkspace?.tabs.first(where: { $0.id == record.id }) {
                // The shared row with the pin as its fixed icon — pinned rows
                // have no project section around them, so the pin is what
                // says which rows these are.
                SidebarTabRow(
                    tab: tab,
                    index: index + 1,
                    iconSymbolOverride: "pin",
                    selectionItem: .tab(projectID: PinnedTabs.workspaceID, tabID: record.id),
                    presentation: presentation,
                    isInteractive: isInteractive,
                    onRename: { newName in
                        ModelWriter.tabSet(tab, title: newName.isEmpty ? nil : newName)
                        appState.saveWorkspaces()
                    }
                )
            } else {
                // Unloaded: the sessions ended (a close, or their own death).
                // The row stays; selecting it restores from the layout.
                Label {
                    FadingText(record.displayTitle)
                        .foregroundStyle(.secondary)
                } icon: {
                    // The pin stays as-is — the row is still pinned, it just
                    // isn't running; the dimming is what says so. Swapping in
                    // `pin.slash` read as "unpinned", which is the one thing
                    // closing a pinned tab never does.
                    Image(systemName: "pin")
                        .foregroundStyle(.tertiary)
                }
                .help("Not running. Select it to restore it from its saved layout.")
            }
        }
        .padding(.trailing, rowTrailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarItem.tab(projectID: PinnedTabs.workspaceID, tabID: record.id))
        .id(SidebarItem.tab(projectID: PinnedTabs.workspaceID, tabID: record.id))
        // Dragging a pinned row into a project unpins it (AppState.moveTab
        // routes the record bookkeeping). Deliberately NO drop destination on
        // the row — same rule as `tabRow`: any row-level target claims the
        // drag before the ForEach's insertion mechanism sees it and kills the
        // native insertion line.
        .draggable(MovableTab(tabID: record.id, sourceProjectID: PinnedTabs.workspaceID))
    }

    /// A tab dropped at a pinned insertion offset (the ForEach's native
    /// insertion line): from a project → pin there; from within the pinned
    /// rows → reorder (`reorderPinnedTab` speaks the same pre-removal offset).
    private func receivePinnedTabDrop(_ item: MovableTab, at offset: Int) {
        if item.sourceProjectID == PinnedTabs.workspaceID {
            appState.reorderPinnedTab(item.tabID, toIndex: offset)
        } else {
            appState.pinTab(item.tabID, fromProject: item.sourceProjectID, toRecordIndex: offset)
        }
    }

    /// One row of the project tree: a group's disclosure of its rows, or a
    /// project's section. `AnyView`, because the function calls itself for
    /// the rows inside a group.
    private func treeRow(_ node: SidebarNode) -> AnyView {
        switch node {
        case let .group(group, children):
            AnyView(
                DisclosureGroup(isExpanded: expansion(of: group.id)) {
                    ForEach(children) { child in
                        treeRow(child)
                    }
                } label: {
                    groupHeader(group: group)
                }
                .id(SidebarItem.group(group.id))
            )
        case let .project(project):
            AnyView(projectSection(project: project))
        }
    }

    /// Open or closed in this window: a project or a group.
    private func expansion(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { windowState.expandedRows.contains(id) },
            set: {
                if $0 {
                    windowState.expandedRows.insert(id)
                } else {
                    windowState.expandedRows.remove(id)
                }
            }
        )
    }

    /// A group's header. A click opens or closes the group and selects
    /// nothing. The tag gives the row its context menu only. A project
    /// dropped here moves into the group, and a group dropped here moves
    /// into it too. It takes only the project payload: a tab or a pane has
    /// no place in a group.
    private func groupHeader(group: Project) -> some View {
        SidebarGroupRow(
            group: group,
            presentation: presentation,
            isInteractive: isInteractive,
            onToggle: { toggleGroup(group.id) },
            onRename: { appState.renameProject(group.id, to: $0, store: projectStore) }
        )
        .padding(.trailing, rowTrailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The glyph and the space around the title: the title has its own
        // gesture (rename on a double click).
        .onTapGesture {
            if isInteractive { toggleGroup(group.id) }
        }
        .draggable(MovableProject(projectID: group.id))
        .tag(SidebarItem.group(group.id))
        .selectionDisabled()
        .dropDestination(for: MovableProject.self) { items, _ in
            for item in items {
                SidebarTree.drop(item.projectID, onto: group, in: projectStore)
            }
            return true
        } isTargeted: { targeted in
            // Spring-open, as a project header does for a tab.
            if targeted { windowState.expandedRows.insert(group.id) }
        }
    }

    private func toggleGroup(_ id: UUID) {
        if windowState.expandedRows.contains(id) {
            windowState.expandedRows.remove(id)
        } else {
            windowState.expandedRows.insert(id)
        }
    }

    /// One project's disclosure section: its tab rows (draggable + a drop
    /// target that reorders/moves at the insertion offset) under a header that
    /// itself accepts drops (the append path for a collapsed/empty project).
    /// Extracted from `body` so each drag/drop closure type-checks in its own
    /// scope — inlined, the whole `List` blew the solver's time budget.
    @ViewBuilder
    private func projectSection(project: Project) -> some View {
        let ws = appState.workspaces[project.id]
        let tabs = ws?.tabs ?? []
        DisclosureGroup(isExpanded: expansion(of: project.id)) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                tabRow(tab: tab, index: tabIndex, project: project)
            }
            // Single drop mechanism for every case: SwiftUI reports the
            // insertion `offset` within THIS project's tab list. A tab drop
            // from the same project reorders to that slot; one from another
            // project moves the tab in at that slot; a PANE drop (the grab
            // handle drag from the workspace) separates that pane into a new
            // tab landing at the same slot. Replaces the old `.onMove` (which
            // is per-section and can't express a cross-project move).
            .dropDestination(for: TabSlotDropItem.self) { items, offset in
                for item in items {
                    switch item {
                    case let .tab(tab):
                        receiveTabDrop([tab], into: project, at: offset)
                    case let .pane(pane):
                        receivePaneDrop([pane], into: project, at: offset)
                    }
                }
            }
        } label: {
            projectHeader(project: project)
        }
        .id(SidebarItem.project(project.id))
    }

    private func tabRow(tab: TerminalTab, index tabIndex: Int, project: Project) -> some View {
        SidebarTabRow(
            tab: tab,
            index: tabIndex + 1,
            // A scratch row has no project section around it, so its icon
            // says which rows these are, as the pin does for pinned rows.
            iconSymbolOverride: project.id == ScratchTabs.workspaceID ? ScratchTabs.iconSymbol : nil,
            selectionItem: .tab(projectID: project.id, tabID: tab.id),
            presentation: presentation,
            isInteractive: isInteractive,
            projectColor: project.color,
            onRename: { newName in
                ModelWriter.tabSet(tab, title: newName.isEmpty ? nil : newName)
                appState.saveWorkspaces()
            }
        )
        .padding(.trailing, rowTrailingInset)
        // Stretch to the full row and make every point hit-testable: without
        // this, the drag grab area hugs the label's intrinsic width instead
        // of covering the whole row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
        .id(SidebarItem.tab(projectID: project.id, tabID: tab.id))
        // Drag a tab out to another project (or reorder within this one). The
        // payload is just IDs — the live tab is looked up on drop, never
        // serialized.
        .draggable(MovableTab(tabID: tab.id, sourceProjectID: project.id))
        // Deliberately NO drop destination on tab rows. Any destination here
        // — even one registered for the project payload alone — claims every
        // drag over the row before the tab ForEach's insertion mechanism sees
        // it (SwiftUI routes a drag to the topmost target by geometry with no
        // type fall-through), which kills the native insertion line and broke
        // tab reordering outright when tried. The cost is that a PROJECT drag
        // over an expanded section's tab rows has nothing to land on — drop
        // it on a project header instead. The insertion line won.
    }

    private func projectHeader(project: Project) -> some View {
        SidebarProjectHeader(
            project: project,
            presentation: presentation,
            isInteractive: isInteractive,
            onRename: { appState.renameProject(project.id, to: $0, store: projectStore) },
            onNewTab: { createTab(in: project) }
        )
        .tag(SidebarItem.project(project.id))
        // ONE drop destination for every payload (see `SidebarDropItem` for
        // why stacking two is a landmine). A TAB dropped here appends to this
        // project — the only drop path for a collapsed or empty project,
        // whose tab ForEach renders no rows to target — and a PANE dropped
        // here appends its new tab the same way. A PROJECT dropped
        // squarely on the header reorders it to this project's slot; the
        // seams BETWEEN rows deliberately stay uncovered (label-height
        // target, no taller band) so the ForEach-level insertion line can
        // appear there for both drag kinds.
        .dropDestination(for: SidebarDropItem.self) { items, _ in
            for item in items {
                switch item {
                case let .tab(tab):
                    receiveTabDrop([tab], into: project, at: nil)
                case let .project(dragged):
                    SidebarTree.drop(dragged.projectID, onto: project, in: projectStore)
                case let .pane(pane):
                    receivePaneDrop([pane], into: project, at: nil)
                }
            }
            return true
        } isTargeted: { targeted in
            // Spring-open a collapsed project while hovering a drag over it,
            // so the user can see where a tab will land. This also fires for
            // project drags (the union payload can't be inspected here); the
            // hovered header itself doesn't move when it expands, so the
            // drop stays on target.
            if targeted { windowState.expandedRows.insert(project.id) }
        }
    }

    /// Every visible row that can be selected, in visual order, mirroring
    /// the `List` body: the pinned records, then the project tree
    /// (`SidebarTree.selectableItems`), then the scratch rows. Published to
    /// `presentation` so a shift-click on a row title can resolve the range
    /// between two rows — the List keeps its own copy of this order for the
    /// clicks it still handles itself.
    private var orderedItems: [SidebarItem] {
        var items: [SidebarItem] = appState.pinnedRecords.map {
            .tab(projectID: PinnedTabs.workspaceID, tabID: $0.id)
        }
        items += SidebarTree.selectableItems(
            SidebarTree.nodes(in: projectStore),
            expanded: windowState.expandedRows,
            tabs: { appState.workspaces[$0]?.tabs.map(\.id) ?? [] }
        )
        items.append(contentsOf: scratchTabs.map { .tab(projectID: ScratchTabs.workspaceID, tabID: $0.id) })
        return items
    }

    /// The scratch rows, in order (#665).
    private var scratchTabs: [TerminalTab] { appState.scratchWorkspace?.tabs ?? [] }

    /// Whether the scratch rows are drawn: see `body`.
    private var showsScratchRows: Bool {
        !scratchTabs.isEmpty || windowState.activeProjectID == ScratchTabs.workspaceID
    }

    private var activeTabID: UUID? {
        guard let pid = windowState.activeProjectID else { return nil }
        // This window's tab, not the workspace's: that is the key window's.
        return appState.selectedTab(for: pid, in: windowState)?.id
    }

    /// Apply a tab drag-and-drop. `index` is the insertion slot within the
    /// destination project's tab list (nil = append, used by header drops). A
    /// drop from the same project reorders; a drop from another project moves
    /// the live tab (surfaces and shells intact) into this one. SwiftUI can
    /// deliver more than one payload, so each is applied in order.
    private func receiveTabDrop(_ items: [MovableTab], into project: Project, at index: Int?) {
        for item in items {
            if item.sourceProjectID == project.id {
                if let index {
                    appState.reorderTab(item.tabID, inProject: project.id, toIndex: index)
                }
            } else {
                appState.moveTab(
                    item.tabID,
                    from: item.sourceProjectID,
                    to: project.id,
                    destPath: project.path,
                    toIndex: index
                )
            }
        }
        windowState.expandedRows.insert(project.id)
    }

    /// Apply a pane drag-and-drop: the pane leaves its split tree and becomes
    /// its own tab in this project, at `index` (nil = append, used by header
    /// drops). The `Pane` object — and its live surface and shell — is reused,
    /// the same as the Separate Current Pane command, which calls the same
    /// `AppState.separatePane`. Dragging a tab's ONLY pane here is a no-op:
    /// it already is its own tab, and moving it to another project is what
    /// dragging its sidebar row does.
    private func receivePaneDrop(_ items: [MovablePane], into project: Project, at index: Int?) {
        for item in items {
            appState.separatePane(
                item.paneID,
                toProject: project.id,
                destPath: project.path,
                at: index
            )
        }
        windowState.expandedRows.insert(project.id)
    }

    private func syncSelection() {
        openGroupsOfActiveProject()
        guard let pid = windowState.activeProjectID,
              let tabID = activeTabID
        else {
            presentation.selection = windowState.activeProjectID.map { [.project($0)] } ?? []
            return
        }
        let desired: Set<SidebarItem> = [.tab(projectID: pid, tabID: tabID)]
        if presentation.selection != desired { presentation.selection = desired }
    }

    /// A selected project inside a closed group stays selected, and its
    /// groups open, so that its row shows.
    private func openGroupsOfActiveProject() {
        guard let pid = windowState.activeProjectID else { return }
        for id in SidebarTree.groupsToOpen(for: pid, in: projectStore) where !windowState.expandedRows.contains(id) {
            windowState.expandedRows.insert(id)
        }
    }

    // MARK: - Context menu

    /// The native multi-select context menu. `items` is the set the menu acts
    /// on, supplied by SwiftUI: the whole selection when the click lands inside
    /// it, or just the clicked row otherwise.
    @ViewBuilder
    private func contextMenu(for items: Set<SidebarItem>) -> some View {
        if items.count > 1 {
            bulkMenu(for: items)
        } else if let item = items.first {
            switch item {
            case let .group(id):
                if let group = projectStore.row(id) {
                    groupMenu(group)
                }
            case let .project(id):
                if let project = projectStore.projects.first(where: { $0.id == id }) {
                    projectMenu(project)
                }
            case let .tab(PinnedTabs.workspaceID, tabID):
                if let record = appState.pinnedRecord(tabID) {
                    pinnedTabMenu(record: record)
                }
            case let .tab(projectID, tabID):
                // A scratch row gets the project tab's menu through the
                // synthetic project: its Move to Project lists every project,
                // and Pin Tab works as it does from a project.
                if let project = Project.synthetic(for: projectID) ?? projectStore.projects.first(where: { $0.id == projectID }),
                   let tab = appState.workspaces[projectID]?.tabs.first(where: { $0.id == tabID })
                {
                    tabMenu(project: project, tab: tab)
                }
            }
        } else {
            // Right-click on empty space.
            Menu("New Project") {
                Button("Local Folder…") { openNewProjectScreen() }
                Button("Remote Machine…") { windowState.isNewRemoteProjectSheetPresented = true }
            }
            Button("New Scratch Tab") { appState.createScratchTab() }
            Button("New Group") { createGroup(beside: nil) }
        }
    }

    /// Single-project menu. Destructive actions route through the same
    /// `request*` confirmations the maintainers added for busy panes, so a
    /// single right-click behaves exactly as before this feature.
    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("New Tab") { createTab(in: project) }
        worktreesMenu(for: project)
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Rename Project") { requestProjectRename(project.id) }
        ProjectColorMenu(selection: project.color) { color in
            projectStore.setColor(id: project.id, to: color)
        }
        Divider()
        treeMoveItems(project)
        Divider()
        Button("Remove Project", role: .destructive) {
            appState.requestRemoveProject(project.id) { removeProject(project) }
        }
    }

    /// A group's menu (design 013). Remove asks first when the group holds
    /// projects. Ungroup keeps them.
    @ViewBuilder
    private func groupMenu(_ group: Project) -> some View {
        Button("Rename Group") { requestProjectRename(group.id) }
        ProjectColorMenu(selection: group.color) { color in
            projectStore.setColor(id: group.id, to: color)
        }
        Divider()
        treeMoveItems(group)
        Divider()
        Button("Ungroup") {
            appState.removeProjects([group.id])
            projectStore.removeKeepingChildren(group.id)
            for window in appState.windows {
                window.expandedRows.remove(group.id)
            }
        }
        Button("Remove Group", role: .destructive) { removeGroup(group) }
    }

    /// The items that move a project or a group in the tree: New Group
    /// beside it, Move to Group, Move Out, and Move Up and Down among the
    /// rows of its parent.
    @ViewBuilder
    private func treeMoveItems(_ row: Project) -> some View {
        Button("New Group") { createGroup(beside: row.id) }
        let targets = SidebarTree.moveTargets(for: row.id, in: projectStore)
        if targets.isEmpty {
            // A disabled item, not a disabled `Menu`: see `worktreesMenu`.
            Button("Move to Group") {}
                .disabled(true)
        } else {
            Menu("Move to Group") {
                ForEach(targets) { group in
                    Button(SidebarTree.pathName(of: group, in: projectStore)) {
                        projectStore.move(row.id, into: group.id)
                        windowState.expandedRows.insert(group.id)
                    }
                }
            }
        }
        Button("Move Out") { projectStore.moveOut(row.id) }
            .disabled(row.parent == nil)
        let position = projectStore.siblingPosition(of: row.id)
        Button("Move Up") { projectStore.moveAmongSiblings(row.id, by: -1) }
            .disabled((position?.index ?? 0) <= 0)
        Button("Move Down") { projectStore.moveAmongSiblings(row.id, by: 1) }
            .disabled(position.map { $0.index >= $0.count - 1 } ?? true)
    }

    /// Add a group (beside `row`, or at the end of the top level) and open
    /// its name for editing.
    private func createGroup(beside row: UUID?) {
        let group = projectStore.add(
            Project(
                name: String(localized: "sidebar.group.defaultName", defaultValue: "New Group", comment: "Name of a new sidebar group"),
                path: ""
            ),
            beside: row
        )
        requestProjectRename(group.id)
    }

    /// Remove a group and the projects inside it, after the question of
    /// `AppState.requestRemoveGroup`.
    private func removeGroup(_ group: Project) {
        appState.requestRemoveGroup(group, projectCount: projectStore.descendants(of: group.id).count) {
            // Read again at the confirm: a project can move while the
            // question is up.
            let inside = projectStore.descendants(of: group.id).map(\.id)
            appState.removeProjects([group.id] + inside)
            projectStore.removeWithDescendants(group.id)
            for window in appState.windows {
                window.expandedRows.subtract([group.id] + inside)
            }
        }
    }

    /// The project's other git worktrees, each opening a tab of this project
    /// in its directory. The listing is read from git's files as the menu is
    /// built — the list's context-menu closure runs when the menu opens, not
    /// when a row redraws — so it is never older than the right-click. It is
    /// empty, and the item disabled, for a directory that isn't a repository's
    /// top or has no other worktree, and for a remote project: that one's
    /// files are reachable only over ssh, which a menu never starts.
    @ViewBuilder
    private func worktreesMenu(for project: Project) -> some View {
        let worktrees = GitWorktrees.list(projectPath: project.path)
        if worktrees.isEmpty {
            // A disabled item, not a disabled `Menu`: a context menu drops
            // `.disabled` on a submenu item — measured on macOS 27, it renders
            // enabled, over an empty submenu that never opens.
            Button("Worktrees") {}
                .disabled(true)
        } else {
            Menu("Worktrees") {
                ForEach(worktrees) { worktree in
                    Button(worktree.title) { createTab(in: project, worktree: worktree) }
                }
            }
        }
    }

    /// Shared by the context menu and its optional hover shortcut.
    private func createTab(in project: Project) {
        appState.selectProject(project, in: windowState)
        appState.createTab(projectID: project.id, projects: projectStore.projects)
        windowState.expandedRows.insert(project.id)
    }

    /// `createTab(in:)` with the worktree's directory as the working directory
    /// in place of the one `tab-inherit-working-directory` would pick.
    private func createTab(in project: Project, worktree: GitWorktree) {
        appState.selectProject(project, in: windowState)
        appState.createTab(projectID: project.id, projects: projectStore.projects, workingDirectory: worktree.path)
        windowState.expandedRows.insert(project.id)
    }

    /// A pinned row's menu — two exits with distinct semantics: Unpin (a
    /// move back to a project for a loaded tab, nothing killed; forgetting
    /// the declaration for an unloaded record — the removal path) and Close
    /// (an unload: processes end, the row and layout stay), matching the
    /// normal tab menu's Close Tab.
    @ViewBuilder
    private func pinnedTabMenu(record: PinnedTabRecord) -> some View {
        let isLoaded = appState.isPinnedTabLoaded(record.id)
        if isLoaded {
            Button("Rename Tab") { requestTabRename(record.id) }
            if let tab = appState.pinnedWorkspace?.tabs.first(where: { $0.id == record.id }),
               tab.splitRoot.allPanes().count > 1
            {
                Button("Separate Panes") {
                    appState.separateTabPanes(record.id, projectID: PinnedTabs.workspaceID)
                }
            }
            Divider()
        }
        let index = appState.pinnedRecords.firstIndex(where: { $0.id == record.id }) ?? 0
        Button("Move Up") {
            appState.reorderPinnedTab(record.id, toIndex: index - 1)
        }
        .disabled(index <= 0)
        Button("Move Down") {
            appState.reorderPinnedTab(record.id, toIndex: index + 2)
        }
        .disabled(index >= appState.pinnedRecords.count - 1)
        // A project with no folder is a group row, with no tabs.
        let unpinTargets = projectStore.projects.filter(\.hasFolder)
        if isLoaded, !unpinTargets.isEmpty {
            Menu("Unpin to Project") {
                ForEach(unpinTargets) { destination in
                    Button(destination.name) {
                        appState.moveTab(
                            record.id,
                            from: PinnedTabs.workspaceID,
                            to: destination.id,
                            destPath: destination.path
                        )
                        windowState.expandedRows.insert(destination.id)
                    }
                }
            }
        }
        Divider()
        // Unpin = a MOVE back to the origin project for a loaded tab (nothing
        // killed); an unloaded record has no live tab, so unpinning forgets
        // the declaration — how a dead row is removed.
        Button("Unpin Tab") {
            appState.unpinTab(record.id, projects: projectStore.projects)
        }
        if isLoaded {
            // Close = UNLOAD: processes end, the dimmed row and its saved
            // layout stay, and the next launch starts it again. Same entry
            // point as the normal tab menu's Close Tab and the closeTab
            // command — `requestCloseTab` routes pinned tabs to the unload.
            Button("Close Tab", role: .destructive) {
                appState.requestCloseTab(record.id, projectID: PinnedTabs.workspaceID)
            }
        }
    }

    @ViewBuilder
    private func tabMenu(project: Project, tab: TerminalTab) -> some View {
        Button("Rename Tab") { requestTabRename(tab.id) }
        if tab.splitRoot.allPanes().count > 1 {
            // #227: explode a split tab — every pane after the first opens in
            // its own tab, shells intact.
            Button("Separate Panes") { appState.separateTabPanes(tab.id, projectID: project.id) }
        }
        Divider()
        // `reorderTab` takes `move(fromOffsets:toOffset:)`-convention offsets
        // (it's the drag-and-drop path's entry point), hence `+ 2` for down.
        let tabs = appState.workspaces[project.id]?.tabs ?? []
        let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        Button("Move Up") {
            appState.reorderTab(tab.id, inProject: project.id, toIndex: tabIndex - 1)
        }
        .disabled(tabIndex <= 0)
        Button("Move Down") {
            appState.reorderTab(tab.id, inProject: project.id, toIndex: tabIndex + 2)
        }
        .disabled(tabIndex >= tabs.count - 1)
        // A project with no folder is a group row, with no tabs.
        let moveTargets = projectStore.projects.filter { $0.id != project.id && $0.hasFolder }
        if !moveTargets.isEmpty {
            Menu("Move to Project") {
                ForEach(moveTargets) { destination in
                    Button(destination.name) {
                        appState.moveTab(tab.id, from: project.id, to: destination.id, destPath: destination.path)
                        windowState.expandedRows.insert(destination.id)
                    }
                }
            }
        }
        if project.id != ScratchTabs.workspaceID {
            // Out of the project, shells intact (#665). The tab keeps its own
            // working directory; only its row moves below the projects.
            Button("Move to Scratch Tabs") {
                appState.moveTabToScratchTabs(tab.id, from: project.id)
            }
        }
        Button("Pin Tab") {
            appState.pinTab(tab.id, fromProject: project.id)
        }
        Divider()
        Button("Close Tab", role: .destructive) {
            appState.requestCloseTab(tab.id, projectID: project.id)
        }
    }

    @ViewBuilder
    private func bulkMenu(for items: Set<SidebarItem>) -> some View {
        let rows = items.filter { !$0.isGroup }
        let projectCount = rows.count(where: { if case .project = $0 { true } else { false } })
        let tabCount = rows.count - projectCount
        if projectCount == 0 {
            Button("Close \(tabCount) Tabs", role: .destructive) { removeSelection(items) }
        } else if tabCount == 0 {
            Button("Remove \(projectCount) Projects", role: .destructive) { removeSelection(items) }
        } else {
            Button("Remove \(rows.count) Items", role: .destructive) { removeSelection(items) }
        }
    }

    /// Remove a single project: drop its workspace (which also drops it from
    /// every window's open sections) and its `ProjectStore` entry. Shared by
    /// the single-item menu and the bulk path so both prune identically.
    private func removeProject(_ project: Project) {
        appState.removeProject(project.id)
        projectStore.remove(id: project.id)
    }

    /// Delete every item in a multi-selection, confirming once if any affected
    /// pane is busy. Tabs whose project is also being removed are skipped —
    /// `removeProject` already tears their surfaces down.
    private func removeSelection(_ items: Set<SidebarItem>) {
        var projectIDs: [UUID] = []
        var tabRefs: [(tabID: UUID, projectID: UUID)] = []
        for item in items {
            switch item {
            case .project(PinnedTabs.workspaceID),
                 .project(ScratchTabs.workspaceID),
                 .group:
                // The pinned and the scratch sections can't be removed. A
                // group is removed from its own menu only.
                break
            case let .project(id):
                projectIDs.append(id)
            case let .tab(projectID, tabID):
                // Pinned tabs are included: `closeTabs` routes them to the
                // unload path (record kept), matching a single-row close.
                tabRefs.append((tabID: tabID, projectID: projectID))
            }
        }

        let removedProjects = Set(projectIDs)
        let tabsToClose = tabRefs.filter { !removedProjects.contains($0.projectID) }
        let projects = projectStore.projects.filter { removedProjects.contains($0.id) }

        appState.requestRemoveSelection(projectIDs: projectIDs, tabs: tabsToClose) {
            appState.closeTabs(tabsToClose)
            for project in projects {
                removeProject(project)
            }
            presentation.selection = []
        }
    }

    /// The New Project screen in this window's palette. The project it adds
    /// becomes the window's active project, whose row expands
    /// (`WindowState`).
    private func openNewProjectScreen() {
        appState.openCommandPalette(scope: .input(.newProject))
    }

    private func requestProjectRename(_ projectID: UUID) {
        windowState.sidebarVisible = true
        DispatchQueue.main.async { appState.renamingProjectID = projectID }
    }

    private func requestTabRename(_ tabID: UUID) {
        windowState.sidebarVisible = true
        DispatchQueue.main.async { appState.renamingTabID = tabID }
    }
}

/// Makes a sidebar row's title open its inline rename on a double-click.
///
/// A title-level gesture owns the whole tap sequence, so the List row never
/// sees a click that lands on the text — which is why selection has to be
/// re-applied here rather than left to the List. Rename rides alongside as a
/// simultaneous gesture so the first click still selects immediately.
///
/// The modifiers come off the event being handled, not the keyboard's live
/// state whenever the gesture resolves: a Command released together with the
/// mouse button would otherwise read as a plain click and collapse an
/// in-progress multi-selection down to the clicked row.
private struct InlineRenameClickTarget: ViewModifier {
    let onSelect: (NSEvent.ModifierFlags) -> Void
    let onBeginRename: () -> Void

    private var modifiers: NSEvent.ModifierFlags {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }

    func body(content: Content) -> some View {
        content
            .onTapGesture { onSelect(modifiers) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { onBeginRename() })
    }
}

extension View {
    func inlineRenameClickTarget(
        onSelect: @escaping (NSEvent.ModifierFlags) -> Void,
        onBeginRename: @escaping () -> Void
    ) -> some View {
        modifier(InlineRenameClickTarget(onSelect: onSelect, onBeginRename: onBeginRename))
    }
}

/// A project's `DisclosureGroup` label: the ordinary project row, plus an
/// optional new-tab button revealed while the pointer rests on the row.
///
/// Three things here are load-bearing, all of them learned from this
/// feature's first cut (PR #331), which left the sidebar visibly corrupt.
///
/// **The reveal is a value change, never a branch.** Nothing is reserved at
/// rest — an idle row is laid out exactly as it was before this feature, and
/// on hover the title yields 22pt and takes it straight back. What matters is
/// HOW: the whole difference between revealed and idle is a padding number,
/// an opacity and a hit-test flag, all read off one `isRevealed` Bool. There
/// is not a single `if` in the view tree.
///
/// That distinction is the entire bug this feature shipped with the first
/// time. Expressing the reveal as a `@ViewBuilder` if/else makes a
/// `_ConditionalContent` whose two branches are different types, and this
/// view is a `List` row carrying `.tag` and a `.dropDestination`. Swapping
/// branches does not re-layout the row — it tears the subtree down and builds
/// a new one, and the `NSTableView` under the outline reuses row views across
/// the churn: duplicated project rows, a tab row's icon drawn over a project
/// title, tab rows under a collapsed project. It also reset `FadingText`'s
/// `@State` width measurements every pointer crossing, so the title
/// re-measured from zero and re-decided its own fade under the pointer, and
/// restarted `SidebarProjectRow`'s `@FocusState` and rename `.task`. A
/// changing WIDTH costs none of that: same view, same identity, one more
/// layout pass, and `FadingText` simply re-reads a container that genuinely
/// did get narrower.
///
/// **Hover comes from an `NSTrackingArea`, never `.onHover`.** This codebase
/// has retired `.onHover` twice: it lags on fast pointer motion
/// (`CommandPalette`) and leaks its exit when the view leaves the hierarchy
/// mid-hover (`SplitTreeView`, which replaced it with a tracking area). A
/// dropped exit is what stuck the button on a row the pointer had left and
/// kept it off the row the pointer was on.
///
/// **The hover state lives here, not on `SidebarContent`.** Held one level up
/// it was read inside the `List` builder, so a single pointer crossing
/// invalidated the pinned section, every project, and every tab row.
private struct SidebarProjectHeader: View {
    let project: Project
    @Bindable
    var presentation: SidebarPresentationState
    let isInteractive: Bool
    let onRename: (String) -> Void
    let onNewTab: () -> Void
    @AppStorage(Preferences.Keys.showProjectNewTabButton)
    private var showProjectNewTabButton: Bool
    @State
    private var isHovered = false

    /// Whether the action occupies the row at all. A user who turns the
    /// preference off pays none of its width — which is why this branch is
    /// allowed to restructure the row and the hover state is not.
    /// The action is showing: the preference is on, the row is live, and the
    /// pointer is on it. Every difference between a revealed row and an idle
    /// one is driven off this ONE Bool as a numeric value — a padding, an
    /// opacity, a hit-test flag — never as a branch in the view tree.
    private var isRevealed: Bool {
        isInteractive && showProjectNewTabButton && isHovered
    }

    var body: some View {
        SidebarProjectRow(
            project: project,
            presentation: presentation,
            isInteractive: isInteractive,
            onRename: onRename
        )
        // Stretch to the full row so the drag grab area (and the drop band in
        // the background of the enclosing header) covers the whole row, not
        // just the label's intrinsic width — same treatment as the tab rows.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Drag the header to reorder projects (replaces the removed
        // `.onMove`). Applied to the TITLE, INSIDE the reveal inset below, so
        // the revealed action is never part of the drag source: a press that
        // drifts a couple of points on the button would otherwise start a
        // project drag, and dragging a project by its new-tab button is
        // nonsense. While idle the inset is zero, so the grab area is the
        // whole row exactly as it was.
        .draggable(MovableProject(projectID: project.id))
        // The action's room opens ONLY while revealed; at rest the title keeps
        // the ordinary row inset and is laid out precisely as it was before
        // this feature. The title yields 14pt to the pointer and takes it
        // straight back.
        .padding(.trailing, isRevealed ? projectActionRevealedInset : rowTrailingInset)
        // Overlaid at the trailing edge rather than placed in an `HStack`, so
        // the button's own position is fixed and only the TITLE's inset
        // moves — and applied OUTSIDE the title's inset, which is what puts
        // it at the row's right end instead of a rowTrailingInset gutter's
        // width short of it. Under an idle row it sits, invisible and inert,
        // over the title's last few points, which costs that title nothing:
        // a zero-opacity overlay takes no space and answers no clicks.
        .overlay(alignment: .trailing) { newTabButton }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RowHoverTracker(isHovered: $isHovered))
        .animation(projectActionRevealAnimation, value: isRevealed)
    }

    private var newTabButton: some View {
        Button(action: onNewTab) {
            Image(systemName: "plus")
                .font(.callout.weight(.medium))
                .frame(width: projectActionSize, height: projectActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isRevealed ? 1 : 0)
        // Opacity alone still hit-tests in SwiftUI, and this button sits ON
        // the title: without this an idle row would hand its last 18pt of
        // title — a click meant to select or rename the project — to a button
        // nobody can see.
        .allowsHitTesting(isRevealed)
        .padding(.trailing, projectActionTrailingInset)
        .help("New Tab")
        // Left reachable by VoiceOver at all times: a pointer-only
        // affordance is no affordance for a keyboard or VoiceOver user, and
        // hit testing and accessibility are separate gates.
        .accessibilityLabel("New Tab in \(project.name)")
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    @Bindable
    var presentation: SidebarPresentationState
    let isInteractive: Bool
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @FocusState
    private var focused: Bool
    /// `.increased` on a selected row of a focused list (`remoteMark`).
    @Environment(\.backgroundProminence)
    private var backgroundProminence

    private var renameTarget: SidebarRenameTarget { .project(project.id) }

    /// The host of a remote project whose panes are plain ssh shells: the
    /// user declined the server, or the host has no build. The row shows it,
    /// so the pane prints no line about it (`RemoteHosts.plainDestinations`).
    private var plainHost: String? {
        guard let remote = remoteHost, RemoteHosts.shared.plainDestinations.contains(remote.destination) else { return nil }
        return remote.host
    }

    /// The host of a remote project (#104): its panes run there over ssh.
    private var remoteHost: (host: String, destination: String)? {
        guard case let .remote(user, host, _) = ProjectPath.remote(from: project.path) else { return nil }
        return (host, HostCommands.destination(user: user, host: host))
    }

    /// `network`, or `network.slash` while the host cannot be reached: a
    /// pane of the project lost its connection (`Workspace.hasLostRemoteLink`),
    /// or the host's roaming link hears nothing (`RemoteHosts.quietDestinations`).
    /// The slashed symbol has the failure color. On a selected row of a
    /// focused list the selection has the accent color, and red is hard to
    /// see on it. There, the slashed symbol has the primary style of the row,
    /// as the project name has. The mark is bold on that row, so the glyph
    /// and the weight show the lost state. Both symbols stay in the layout
    /// with the same weight and only one is visible. So the mark after it
    /// does not move.
    private func remoteMark(host: String, destination: String) -> some View {
        let lost = appState.workspaces[project.id]?.hasLostRemoteLink == true
            || RemoteHosts.shared.quietDestinations.contains(destination)
        let help = lost
            ? String(
                localized: "Connection to \(host) lost",
                comment: "Help of the sidebar mark on a remote project whose connection to its host stopped."
            )
            : String(
                localized: "Remote project on \(host)",
                comment: "Help of the sidebar mark on a remote project."
            )
        let onProminentSelection = backgroundProminence == .increased
        return ZStack {
            Image(systemName: "network")
                .foregroundStyle(.secondary)
                .opacity(lost ? 0 : 1)
            Image(systemName: "network.slash")
                .foregroundStyle(onProminentSelection ? AnyShapeStyle(.primary) : AnyShapeStyle(MactermTheme.failure))
                .opacity(lost ? 1 : 0)
        }
        .font(.caption2)
        .fontWeight(onProminentSelection ? .bold : nil)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var titleContent: some View {
        if isInteractive, presentation.isRenaming(renameTarget) {
            TextField(String(), text: $presentation.renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            HStack(spacing: 4) {
                FadingText(project.name)
                if let remote = remoteHost {
                    remoteMark(host: remote.host, destination: remote.destination)
                }
                if let host = plainHost {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(String(
                            localized: "Macterm has no server on \(host). Shells of this project stop when the connection stops.",
                            comment: "Help of the sidebar mark on a remote project whose host has no Macterm server."
                        ))
                }
            }
            .inlineRenameClickTarget(onSelect: select, onBeginRename: beginRename)
        }
    }

    var body: some View {
        Label {
            titleContent
        } icon: {
            // Only when tagged: forcing a color on an untagged row
            // would flatten the styling AppKit gives a selected row.
            if let color = project.color {
                TabRowIcon(symbol: "folder", index: 1)
                    .foregroundStyle(MactermTheme.color(for: color))
            } else {
                TabRowIcon(symbol: "folder", index: 1)
            }
        }
        .task(id: appState.renamingProjectID) {
            if appState.renamingProjectID == project.id { beginRename() }
        }
    }

    /// The row this header stands for — the same value the enclosing
    /// `DisclosureGroup` tags itself with, so a title click highlights the
    /// row the List would have highlighted.
    private var selectionItem: SidebarItem { .project(project.id) }

    private func beginRename() {
        guard isInteractive else { return }
        presentation.beginRename(
            renameTarget,
            text: project.name
        )
        appState.renamingProjectID = nil
    }

    private func select(_ modifiers: NSEvent.ModifierFlags) {
        guard isInteractive else { return }
        presentation.selectRow(selectionItem, modifiers: modifiers)
    }

    private func commit() {
        guard let draft = presentation.completeRename(renameTarget) else { return }
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        guard presentation.cancelRename(renameTarget) else { return }
        appState.restoreFocusToActivePane()
    }
}

/// A group's row (design 013): a folder glyph, the name and the inline
/// rename. A click opens or closes the group and selects nothing. The glyph
/// goes through `TabRowIcon`, as the project and tab glyphs do, so the three
/// levels draw one size and follow Settings' icon size.
private struct SidebarGroupRow: View {
    let group: Project
    @Bindable
    var presentation: SidebarPresentationState
    let isInteractive: Bool
    let onToggle: () -> Void
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @FocusState
    private var focused: Bool

    /// A group's id is a row id of `ProjectStore`, as a project's is, so the
    /// rename target and `AppState.renamingProjectID` serve both.
    private var renameTarget: SidebarRenameTarget { .project(group.id) }

    @ViewBuilder
    private var titleContent: some View {
        if isInteractive, presentation.isRenaming(renameTarget) {
            TextField(String(), text: $presentation.renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            // The double tap first, so that a double click renames and does
            // not also open and close the group.
            FadingText(group.name)
                .onTapGesture(count: 2) { beginRename() }
                .onTapGesture { toggle() }
        }
    }

    var body: some View {
        Label {
            titleContent
        } icon: {
            if let color = group.color {
                TabRowIcon(symbol: "folder", index: 1)
                    .foregroundStyle(MactermTheme.color(for: color))
            } else {
                TabRowIcon(symbol: "folder", index: 1)
            }
        }
        .task(id: appState.renamingProjectID) {
            if appState.renamingProjectID == group.id { beginRename() }
        }
    }

    private func toggle() {
        guard isInteractive else { return }
        onToggle()
    }

    private func beginRename() {
        guard isInteractive else { return }
        presentation.beginRename(renameTarget, text: group.name)
        appState.renamingProjectID = nil
    }

    private func commit() {
        guard let draft = presentation.completeRename(renameTarget) else { return }
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        guard presentation.cancelRename(renameTarget) else { return }
        appState.restoreFocusToActivePane()
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let index: Int
    /// Fixed icon overriding the user's `tabIconSymbol` preference — the
    /// pinned rows pass "pin" so the icon itself marks the row's kind.
    var iconSymbolOverride: String?
    let selectionItem: SidebarItem
    @Bindable
    var presentation: SidebarPresentationState
    let isInteractive: Bool
    /// The owning project's color tag, drawn on whatever glyph this row's
    /// icon slot holds — and on nothing at all when it holds none, since a
    /// tab row never carries a stripe. Nil for an untagged project and for
    /// the pinned rows, which belong to none.
    var projectColor: ProjectColor?
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol: String
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons: Bool
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator: Bool
    @AppStorage(Preferences.Keys.showSpinnerOverAgentIcons)
    private var showSpinnerOverAgentIcons: Bool
    @FocusState
    private var focused: Bool

    private var renameTarget: SidebarRenameTarget { .tab(tab.id) }

    @ViewBuilder
    private var titleContent: some View {
        if isInteractive, presentation.isRenaming(renameTarget) {
            TextField(tab.autoTitle, text: $presentation.renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            TabRowTitle(tab: tab)
                .inlineRenameClickTarget(onSelect: select, onBeginRename: beginRename)
        }
    }

    /// The tab's live agent logo, unless disabled in Settings.
    private var agentIcon: AgentIcon? {
        showAgentIcons ? tab.agentIcon : nil
    }

    /// The effective icon symbol: the override wins over the preference.
    private var iconSymbol: String {
        iconSymbolOverride ?? tabIconSymbol
    }

    /// The project tag's color, or nil when the project is untagged — which
    /// is what leaves an untagged row exactly as it was, agent logos in their
    /// brand colors included.
    @MainActor
    private var tagColor: Color? {
        projectColor.map { MactermTheme.color(for: $0) }
    }

    /// The icon's style: the tag when tagged, else the hierarchical
    /// `.secondary` the row has always used. `AnyShapeStyle` because the two
    /// arms are different style types — a `??` would bind the whole
    /// expression to `Color` and silently swap `HierarchicalShapeStyle`
    /// (which resolves against a selected row's own foreground) for the fixed
    /// `Color.secondary`, changing every UNTAGGED row.
    @MainActor
    private var iconStyle: AnyShapeStyle {
        tagColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }

    var body: some View {
        Group {
            if iconSymbol == Preferences.noIcon {
                Label {
                    titleContent
                } icon: {
                    // `TabGlyph` draws nothing when "None" leaves no live
                    // signal to show, which is what this branch needs: an
                    // invisible Image would still reserve the Label's icon
                    // column, nudging the title right of every other
                    // icon-less row.
                    TabGlyph(tab: tab, index: index, symbolOverride: iconSymbol, tint: tagColor)
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label {
                    titleContent
                } icon: {
                    TabGlyph(tab: tab, index: index, symbolOverride: iconSymbol, tint: tagColor)
                }
            }
        }
        .onChange(of: appState.renamingTabID) { _, id in
            if id == tab.id { beginRename() }
        }
    }

    private func beginRename() {
        guard isInteractive else { return }
        presentation.beginRename(
            renameTarget,
            text: tab.customTitle ?? "",
            originalCustomTitle: tab.customTitle
        )
        appState.renamingTabID = nil
    }

    private func select(_ modifiers: NSEvent.ModifierFlags) {
        guard isInteractive else { return }
        presentation.selectRow(selectionItem, modifiers: modifiers)
    }

    private func commit() {
        guard let draft = presentation.completeRename(renameTarget) else { return }
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        let newCustomTitle: String? = text.isEmpty ? nil : text
        if newCustomTitle != draft.originalCustomTitle {
            onRename(text)
        }
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        guard presentation.cancelRename(renameTarget) else { return }
        appState.restoreFocusToActivePane()
    }
}

/// The pin drop zone at the top of the sidebar: a strip that pins a dropped
/// tab or pane at the first slot. It draws chrome only when there are no
/// pinned rows yet (`showsBand`) — with rows present the List's own insertion
/// line already marks the same slot, so the band would just double it. Either
/// way the strip must keep a nonzero idle height: `isTargeted` only fires once
/// the pointer is over the target, so a zero-height strip could never be
/// discovered by a drag.
private struct PinTabDropZone: View {
    let showsBand: Bool
    let onPinTab: (MovableTab) -> Void
    let onPinPane: (MovablePane) -> Void
    @State
    private var isTargeted = false

    private var isBandVisible: Bool { showsBand && isTargeted }

    var body: some View {
        ZStack {
            if isBandVisible {
                // System glass or material, with no tint or stroke. The List
                // draws no target here, because an empty ForEach has no row.
                Label("Pin Tab", systemImage: "pin.fill")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .glassPanelBackground(cornerRadius: 6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isBandVisible ? 38 : SidebarLayoutMetrics.idlePinDropHeight)
        .contentShape(Rectangle())
        .dropDestination(for: TabSlotDropItem.self) { items, _ in
            for item in items {
                switch item {
                case let .tab(tab):
                    onPinTab(tab)
                case let .pane(pane):
                    onPinPane(pane)
                }
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isTargeted = targeted
            }
        }
    }
}

/// A tab row's display title, shared by project and pinned rows so the two
/// render identically. #227: an unnamed split of 2-3 panes reads as multiple
/// tabs sharing one row — one chromeless title segment per pane, divided by
/// hairlines so adjacent titles don't read as one run-on name. A custom
/// title still wins (the user named the whole tab), and four or more panes
/// won't fit legibly, so that row collapses back to a single title with the
/// pane count (see `sidebarRowTitle`). The segments are a TITLE variant, not
/// their own labels: the row carries one tab icon regardless.
private struct TabRowTitle: View {
    let tab: TerminalTab

    var body: some View {
        if tab.customTitle == nil, (2 ... 3).contains(tab.splitRoot.allPanes().count) {
            HStack(spacing: 10) {
                ForEach(Array(tab.splitRoot.allPanes().enumerated()), id: \.element.id) { i, pane in
                    if i > 0 { Divider() }
                    FadingText(pane.sidebarSegmentTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            FadingText(tab.sidebarRowTitle)
        }
    }
}
