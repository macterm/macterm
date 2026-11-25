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

    /// The node that Move to Project moves from the palette and the menu
    /// bar: the node that the key window shows. That is the tab that the
    /// window selects (`selectedTab(for:in:)`), else the active project: on
    /// its project screen (a click on its sidebar row) or with no tab. A
    /// single sidebar selection shows its node, so this is the selected row.
    /// The palette takes the focus from the sidebar, so the focus cannot
    /// choose. A multi-selection of the sidebar does not change the node;
    /// design issue 0608 decides a move of more than one node.
    func moveToProjectNode(store: ProjectStore) -> SidebarItem? {
        guard let projectID = activeProjectID else { return nil }
        let tab = keyWindow.map { selectedTab(for: projectID, in: $0) } ?? model.activeTab(of: projectID)
        if let tab { return .tab(projectID: projectID, tabID: tab.id) }
        return store.row(projectID) != nil ? .project(projectID) : nil
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
