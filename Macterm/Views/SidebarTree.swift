import Foundation

/// One row of the sidebar's project tree (design 013): a group, which holds
/// other rows, or a project, which holds its tabs. A group is a project with
/// no folder (`Project.hasFolder`), the row of a dev build that was a group.
enum SidebarNode: Identifiable, Equatable {
    case group(Project, children: [SidebarNode])
    case project(Project)

    var id: UUID { row.id }

    var row: Project {
        switch self {
        case let .group(group, _): group
        case let .project(project): project
        }
    }
}

/// The rules of the sidebar's project tree that do not need a view. The
/// tree is derived from `ProjectStore` at each read; nothing stores it.
@MainActor
enum SidebarTree {
    /// The rows under `parent` (nil: the top level), with the rows inside
    /// each group. The children of a project that has a folder follow it
    /// at its own level, so that no project is hidden.
    static func nodes(in store: ProjectStore, under parent: UUID? = nil) -> [SidebarNode] {
        store.children(of: parent).flatMap { row -> [SidebarNode] in
            row.hasFolder
                ? [.project(row)] + nodes(in: store, under: row.id)
                : [.group(row, children: nodes(in: store, under: row.id))]
        }
    }

    /// Every row that a shift-click can select, in visual order: each
    /// project whose groups are all open, and then its tabs while it is
    /// open. A group row is not in the list, because it is never selected.
    static func selectableItems(
        _ nodes: [SidebarNode],
        expanded: Set<UUID>,
        tabs: (UUID) -> [UUID]
    ) -> [SidebarItem] {
        nodes.flatMap { node -> [SidebarItem] in
            switch node {
            case let .group(group, children):
                return expanded.contains(group.id) ? selectableItems(children, expanded: expanded, tabs: tabs) : []
            case let .project(project):
                let tabRows: [SidebarItem] = expanded.contains(project.id)
                    ? tabs(project.id).map { .tab(projectID: project.id, tabID: $0) }
                    : []
                return [.project(project.id)] + tabRows
            }
        }
    }

    /// The groups to open so that the row of `projectID` shows: every group
    /// above it. A selected project inside a closed group stays selected, and
    /// its groups open.
    static func groupsToOpen(for projectID: UUID, in store: ProjectStore) -> [UUID] {
        store.ancestors(of: projectID)
    }

    /// What a project dragged onto the header of `target` does: a group
    /// takes it in, and a project gets it beside itself. Returns false when
    /// the store refuses the move (a group into itself).
    @discardableResult
    static func drop(_ id: UUID, onto target: Project, in store: ProjectStore) -> Bool {
        guard id != target.id else { return false }
        return target.hasFolder ? store.place(id, beside: target.id) : store.move(id, into: target.id)
    }

    /// The groups that `id` can move into with Move to Group: every group
    /// except its own parent, itself, and the groups inside it.
    static func moveTargets(for id: UUID, in store: ProjectStore) -> [Project] {
        let parent = store.row(id)?.parent
        return store.projects.filter { group in
            !group.hasFolder && group.id != parent && group.id != id && !store.ancestors(of: group.id).contains(id)
        }
    }

    /// The name of a group in a menu: the names of the groups above it and
    /// its own, joined with " / ", so two groups of one name differ.
    static func pathName(of group: Project, in store: ProjectStore) -> String {
        let names = store.ancestors(of: group.id).reversed().compactMap { store.row($0)?.name }
        return (names + [group.name]).joined(separator: " / ")
    }
}
