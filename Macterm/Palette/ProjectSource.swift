import AppKit

/// Palette source for projects. Active search matches the name, then the
/// path, then the names of the projects above it (`Search`), and gives
/// projects a small score boost over commands; empty state shows up to 5
/// recently-visited projects (falling back to the store if recency is empty).
/// The subtitle of a project in another project is the path of those names
/// ("Work/api"). The subtitle of a project at the top level is its folder
/// (design 013).
@MainActor
struct ProjectSource: PaletteSource {
    /// Wins a tie with a command: a project matched as well as a command is
    /// the one listed first. A stronger command match still beats it.
    private let projectBoost = 1

    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        let query = SearchQuery(query)
        return context.projectStore.projects.compactMap { project in
            let parents = parentNames(of: project, in: context.projectStore)
            guard let match = Search.match(query, fields: [project.name, project.path] + parents) else { return nil }
            return makeItem(
                project: project,
                parents: parents,
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
        let items = pool.prefix(5).map {
            makeItem(
                project: $0,
                parents: parentNames(of: $0, in: context.projectStore),
                category: category,
                score: 0,
                context: context
            )
        }
        return items.isEmpty ? nil : Array(items)
    }

    /// The names of the projects above `project`, top first.
    private func parentNames(of project: Project, in store: ProjectStore) -> [String] {
        store.ancestors(of: project.id).reversed().compactMap { store.row($0)?.name }
    }

    private func makeItem(
        project: Project,
        parents: [String],
        category: String,
        score: Int,
        context: PaletteContext
    ) -> PaletteItem {
        PaletteItem(
            id: "project:\(project.id.uuidString)",
            title: project.name,
            subtitle: parents.isEmpty ? project.path : parents.joined(separator: "/"),
            category: category,
            score: score
        ) { [appState = context.appState] in
            appState.showLastTab(of: project)
        }
    }
}
