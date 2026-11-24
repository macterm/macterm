import Foundation

/// Moves in the project tree (design 013) that the sidebar menu and the
/// project commands both make. `ProjectStore` holds the tree; this adds
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
