import Foundation

/// One project of the sidebar's project tree (design 013): its row, and
/// the projects inside it. The row's disclosure shows its tabs first, then
/// these children, each again a disclosure.
struct SidebarNode: Identifiable, Equatable {
    let project: Project
    let children: [SidebarNode]

    var id: UUID { project.id }
}

/// The rules of the sidebar's project tree that do not need a view. The
/// tree is derived from `ProjectStore` at each read; nothing stores it.
@MainActor
enum SidebarTree {
    /// The projects under `parent` (nil: the top level), each with the
    /// projects inside it.
    static func nodes(in store: ProjectStore, under parent: UUID? = nil) -> [SidebarNode] {
        store.children(of: parent).map { SidebarNode(project: $0, children: nodes(in: store, under: $0.id)) }
    }

    /// Every row that a shift-click can select, in visual order: each
    /// project whose parents are all open, and then, while it is open, its
    /// tabs and the projects inside it.
    static func selectableItems(
        _ nodes: [SidebarNode],
        expanded: Set<UUID>,
        tabs: (UUID) -> [UUID]
    ) -> [SidebarItem] {
        nodes.flatMap { node -> [SidebarItem] in
            let id = node.project.id
            guard expanded.contains(id) else { return [.project(id)] }
            return [.project(id)]
                + tabs(id).map { .tab(projectID: id, tabID: $0) }
                + selectableItems(node.children, expanded: expanded, tabs: tabs)
        }
    }

    /// The projects to open so that the row of `projectID` shows: every
    /// project above it. A selected project inside a closed parent stays
    /// selected, and its parents open.
    static func parentsToOpen(for projectID: UUID, in store: ProjectStore) -> [UUID] {
        store.ancestors(of: projectID)
    }

    /// A project dragged onto the header of `target` goes inside `target`,
    /// at the end (Ethan, design 013: "A"). Move Up and Move Down change the
    /// order. Returns false when the store refuses the move (a project into
    /// itself or into a project inside it).
    @discardableResult
    static func drop(_ id: UUID, onto target: Project, in store: ProjectStore) -> Bool {
        guard id != target.id else { return false }
        return store.move(id, into: target.id)
    }

    /// The projects that `id` can move into with Move Into Project: every
    /// project except its own parent, itself, and the projects inside it.
    static func moveTargets(for id: UUID, in store: ProjectStore) -> [Project] {
        let parent = store.row(id)?.parent
        return store.projects.filter { target in
            target.id != parent && target.id != id && !store.ancestors(of: target.id).contains(id)
        }
    }

    /// The path of names of a project (`Work/api`): the names of the
    /// projects above it and its own, joined with "/" (Ethan, 2026-11-23).
    /// A project name has no slash (`Project.nameRefusal`), so the path
    /// reads one way.
    static func pathName(of project: Project, in store: ProjectStore) -> String {
        let names = store.ancestors(of: project.id).reversed().compactMap { store.row($0)?.name }
        return (names + [project.name]).joined(separator: "/")
    }
}
