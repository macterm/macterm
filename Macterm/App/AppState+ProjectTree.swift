import Foundation

/// Moves in the tree of projects and tabs (design 013) that the sidebar
/// menu and the commands both make. `ProjectStore` holds the tree; this adds
/// what a window shows: the rows that open so that the moved project shows.
extension AppState {
    /// Move the project `id` into `target`, and open `target` and the
    /// projects above it in `window`. Returns false when the store refuses
    /// the move (a project into itself or into a project inside it).
    @discardableResult
    func moveProject(_ id: UUID, into target: UUID, store: ProjectStore, in window: WindowState?) -> Bool {
        guard store.move(id, into: target) else { return false }
        window?.expandedRows.formUnion([target] + SidebarTree.parentsToOpen(for: target, in: store))
        return true
    }

    /// Move to Project: move `node`, a project or a tab, to `target`, and
    /// open `target` and the projects above it in `window`. Returns false
    /// when the move cannot happen (a project into itself or into a project
    /// inside it, a tab into its own project).
    @discardableResult
    func moveNode(_ node: SidebarItem, to target: Project, store: ProjectStore, in window: WindowState?) -> Bool {
        switch node {
        case let .project(id):
            return moveProject(id, into: target.id, store: store, in: window)
        case let .tab(projectID, tabID):
            guard projectID != target.id else { return false }
            moveTab(tabID, from: projectID, to: target.id, destPath: target.path)
            window?.expandedRows.formUnion([target.id] + SidebarTree.parentsToOpen(for: target.id, in: store))
            return true
        }
    }

    /// The nodes that a command acts on (design 013 §2.1): Remove, and Move
    /// to Project for one node. While the palette is up, the nodes that it
    /// recorded when it opened (`WindowState.paletteTarget`): the palette
    /// takes the focus from the sidebar, so the focus at that moment cannot
    /// choose. Otherwise the nodes that the key window gives now
    /// (`liveCommandTarget(in:)`). Only nodes that still exist, in the
    /// order of the sidebar rows. The rows of Pinned and Scratch Tabs are
    /// not nodes.
    func commandTarget(store: ProjectStore) -> [SidebarItem] {
        let nodes = if let window = keyWindow {
            window.isCommandPaletteVisible
                ? window.paletteTarget ?? liveCommandTarget(in: window)
                : liveCommandTarget(in: window)
        } else {
            shownNode(in: nil).map { [$0] } ?? []
        }
        return nodes.filter { nodeExists($0, store: store) }
    }

    /// The nodes of `window` now: its sidebar selection while the sidebar
    /// has the focus, else the node that it shows. A click in a terminal
    /// pane does not clear a selection of more rows
    /// (`SidebarContent.syncSelection` follows a change of tab or project
    /// only), so the selection counts only while the user is in the sidebar
    /// (`WindowState.sidebarHasFocus`), and only while it shows.
    func liveCommandTarget(in window: WindowState) -> [SidebarItem] {
        let selection = window.sidebar.selection
        if !selection.isEmpty, window.sidebarHasFocus, window.sidebarVisible {
            let order = window.sidebar.orderedItems
            return selection.sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
        }
        return shownNode(in: window).map { [$0] } ?? []
    }

    /// The node that `window` shows: the tab that it selects
    /// (`selectedTab(for:in:)`), else the active project, on its project
    /// screen (a click on its sidebar row) or with no tab.
    private func shownNode(in window: WindowState?) -> SidebarItem? {
        guard let projectID = activeProjectID else { return nil }
        let tab = window.map { selectedTab(for: projectID, in: $0) } ?? workspaces[projectID]?.activeTab
        if let tab { return .tab(projectID: projectID, tabID: tab.id) }
        return .project(projectID)
    }

    /// A tab that is open in its workspace (an unloaded pinned row has
    /// nothing to close), or a project row of the store.
    private func nodeExists(_ node: SidebarItem, store: ProjectStore) -> Bool {
        switch node {
        case let .project(id): store.row(id) != nil
        case let .tab(projectID, tabID): workspaces[projectID]?.tabs.contains { $0.id == tabID } == true
        }
    }

    /// The name of `node` as its sidebar row says it: the tab's title, or
    /// the project's path of names (`SidebarTree.pathName`).
    func displayName(of node: SidebarItem, store: ProjectStore) -> String? {
        switch node {
        case let .project(id):
            store.row(id).map { SidebarTree.pathName(of: $0, in: store) }
        case let .tab(projectID, tabID):
            workspaces[projectID]?.tabs.first { $0.id == tabID }?.sidebarTitle
        }
    }

    /// The node that Move to Project moves from the palette and the menu
    /// bar: the target (`commandTarget(store:)`) when it is one node. A move
    /// of more than one node is issue B of design 013.
    func moveToProjectNode(store: ProjectStore) -> SidebarItem? {
        let nodes = commandTarget(store: store)
        return nodes.count == 1 ? nodes.first : nil
    }

    /// New Project Inside: the folder panel, starting in the folder of
    /// `parent`. The new project is a child of `parent`. The new row,
    /// `parent` and the projects above it open in `window`, so that the new
    /// row shows.
    @discardableResult
    func newProject(inside parent: Project, store: ProjectStore, in window: WindowState?) -> Project? {
        guard let project = newProjectFromFolderPanel(store: store, inside: parent) else { return nil }
        window?.expandedRows.formUnion([project.id, parent.id] + SidebarTree.parentsToOpen(for: parent.id, in: store))
        return project
    }
}
