import Foundation

/// Sidebar groups (design 013): the changes that the sidebar's menus and
/// the group `AppCommand`s both make. `ProjectStore` holds the tree; these add
/// what a window shows (which groups are open) and the sessions that a
/// removal ends.
extension AppState {
    /// The name that a new group gets before the user renames it.
    static var newGroupName: String {
        String(localized: "sidebar.group.defaultName", defaultValue: "New Group", comment: "Name of a new sidebar group")
    }

    /// The group that holds the active project, nil when the project is at
    /// the top level or no project is active.
    func activeProjectGroup(in store: ProjectStore) -> Project? {
        guard let activeProjectID, let parent = store.row(activeProjectID)?.parent else { return nil }
        return store.row(parent)
    }

    /// Move the row `id` into `group` and open that group in `window`, so
    /// that the row stays in view.
    func moveToGroup(_ id: UUID, group: UUID, store: ProjectStore, in window: WindowState?) {
        guard store.move(id, into: group) else { return }
        window?.expandedRows.insert(group)
    }

    /// Remove the group `id` and keep its rows (`ProjectStore.ungroup`).
    func ungroup(_ id: UUID, store: ProjectStore) {
        store.ungroup(id)
        for window in windows {
            window.expandedRows.remove(id)
        }
    }

    /// Remove a group and the projects inside it, after the question of
    /// `requestRemoveGroup`.
    func removeGroup(_ group: Project, store: ProjectStore) {
        requestRemoveGroup(group, projectCount: store.projects(inGroup: group.id).count) { [self] in
            // Read again at the confirm: a project can move while the
            // question is up.
            let inside = store.projects(inGroup: group.id)
            let groupIDs = [group.id] + store.groups
                .filter { store.ancestors(of: $0.id).contains(group.id) }
                .map(\.id)
            removeProjects(inside.map(\.id))
            store.removeGroup(group.id)
            for window in windows {
                window.expandedRows.subtract(groupIDs)
            }
        }
    }
}
