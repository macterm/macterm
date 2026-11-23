import Foundation

/// The palette's Move to Group: the groups that the active project can move
/// into (`SidebarTree.moveTargets`), each named by its path. A pick moves
/// the project, as the sidebar's Move to Group menu does.
@MainActor
final class MoveToGroupPaletteScope: PaletteScope {
    let placeholder = String(localized: "Search groups...")

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        let store = context.projectStore
        guard let projectID = context.appState.activeProjectID, store.row(projectID) != nil else { return [] }
        let rows = SidebarTree.moveTargets(for: projectID, in: store).map { group in
            PaletteItem(id: "group:\(group.id)", title: SidebarTree.pathName(of: group, in: store)) {
                context.appState.moveToGroup(projectID, group: group.id, store: store)
            }
        }
        guard !query.isEmpty else {
            return rows.isEmpty ? [] : [PaletteSection(header: nil, items: rows)]
        }
        let search = SearchQuery(query.trimmed)
        let matches = rows.compactMap { item in
            Search.match(search, fields: [item.title]).map { item.with($0) }
        }
        .rankedByScore()
        return matches.isEmpty ? [] : [PaletteSection(header: nil, items: matches)]
    }
}
