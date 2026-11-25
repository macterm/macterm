import Foundation

/// The palette's Move to Project screen (design 013 §2): one screen for
/// both kinds of node of the tree, a project and a tab (Ethan, ui-review
/// 0601). It lists the projects that the node can move to
/// (`SidebarTree.moveDestinations`), each by its path of names (`Work/api`)
/// with its folder under it. Typed text filters the list by name, path of
/// names or folder. Return on a row moves the node to that project.
///
/// The rows are only existing projects (Ethan, ui-review 0592): no action
/// row for the typed text and no notice. A query that matches no project
/// gives the palette's no-matches text.
@MainActor
final class MoveToProjectPaletteScope: PaletteScope {
    /// The node that moves.
    let node: SidebarItem

    let placeholder = String(localized: "Search projects by name or path...")

    init(node: SidebarItem) {
        self.node = node
    }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        let store = context.projectStore
        let search = SearchQuery(query.trimmed)
        let items = SidebarTree.moveDestinations(for: node, in: store).compactMap { target -> PaletteItem? in
            let path = SidebarTree.pathName(of: target, in: store)
            // The name is the last part of the path of names, so that field
            // also finds a project by its name. The folder is the second
            // field, as on the root palette (`ProjectSource`).
            guard let match = Search.match(search, fields: [path, target.path]) else { return nil }
            return item(for: target, path: path, context: context).with(match)
        }
        // An empty query keeps the order of the project list.
        let rows = search.isEmpty ? items : items.rankedByScore()
        return rows.isEmpty ? [] : [PaletteSection(header: nil, items: rows)]
    }

    private func item(for target: Project, path: String, context: PaletteContext) -> PaletteItem {
        PaletteItem(
            id: "move-to-project:\(target.id.uuidString)",
            title: path,
            subtitle: target.path,
            score: 0
        ) { [node, appState = context.appState, store = context.projectStore] in
            appState.moveNode(node, to: target, store: store, in: appState.keyWindow)
        }
    }
}
