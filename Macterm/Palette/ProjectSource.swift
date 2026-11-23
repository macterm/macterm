import AppKit

/// Palette source for projects. Active search matches the name, then the
/// name of the project's group, then the path (`Search`), and gives projects
/// a small score boost over commands; empty state shows up to 5
/// recently-visited projects (falling back to the store if recency is empty).
/// A group is never a row (design 013): a project in a group shows the
/// group's name as its subtitle, and a project at the top level its path.
@MainActor
struct ProjectSource: PaletteSource {
    /// Wins a tie with a command: a project matched as well as a command is
    /// the one listed first. A stronger command match still beats it.
    private let projectBoost = 1

    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        let query = SearchQuery(query)
        return context.projectStore.projects.compactMap { project in
            let group = context.projectStore.group(of: project.id)?.name
            let fields = [project.name] + (group.map { [$0] } ?? []) + [project.path]
            guard let match = Search.match(query, fields: fields) else { return nil }
            return makeItem(
                project: project,
                category: String(localized: "Project"),
                score: 0,
                context: context
            ).with(match, boost: projectBoost)
        }
    }

    func emptyItems(context: PaletteContext) -> [PaletteItem]? {
        let recent = context.appState.recentProjects(
            from: context.projectStore.projects,
            limit: 10
        ).filter { $0.id != context.appState.activeProjectID }

        let pool = recent.isEmpty
            ? context.projectStore.projects.filter { $0.id != context.appState.activeProjectID }
            : recent

        let category = String(localized: "Recent", comment: "Command palette: the section of recently visited projects")
        let items = pool.prefix(5).map { makeItem(project: $0, category: category, score: 0, context: context) }
        return items.isEmpty ? nil : Array(items)
    }

    private func makeItem(project: Project, category: String, score: Int, context: PaletteContext) -> PaletteItem {
        PaletteItem(
            id: "project:\(project.id.uuidString)",
            title: project.name,
            subtitle: context.projectStore.group(of: project.id)?.name ?? project.path,
            category: category,
            score: score
        ) { [appState = context.appState] in
            appState.selectProject(project)
        }
    }
}
