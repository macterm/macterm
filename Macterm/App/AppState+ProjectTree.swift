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
    /// bar: the node that the key window shows. That is the active project
    /// while the window shows its project screen (a click on its sidebar
    /// row) or while it has no tab, else the active tab. A single sidebar
    /// selection shows its node, so this is the selected row. The palette
    /// takes the focus from the sidebar, so the focus cannot choose.
    func moveToProjectNode(store: ProjectStore) -> SidebarItem? {
        guard let projectID = activeProjectID else { return nil }
        let tab = workspaces[projectID]?.activeTab
        if store.row(projectID) != nil, keyWindowShowsProjectScreen || tab == nil {
            return .project(projectID)
        }
        return tab.map { .tab(projectID: projectID, tabID: $0.id) }
    }

    /// New Project Inside: Open Folder, starting in the folder of `parent`.
    /// The new project is a child of `parent`. The new row, `parent` and the
    /// projects above it open in `window`, so that the new row shows.
    @discardableResult
    func openProject(inside parent: Project, store: ProjectStore, in window: WindowState?) -> Project? {
        guard let project = openProject(store: store, inside: parent) else { return nil }
        window?.expandedRows.formUnion([project.id, parent.id] + SidebarTree.parentsToOpen(for: parent.id, in: store))
        return project
    }
}
