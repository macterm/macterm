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
}
