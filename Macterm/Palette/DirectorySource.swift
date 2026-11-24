import AppKit
import Foundation

/// Palette source for directory completions (`PathCompleter`). Consulted
/// only when the query looks like a path. If the exact path matches a
/// directory, it's surfaced as the top result — and if that directory is
/// already an opened project, the top item switches to it, with an "add
/// another project" item below (a directory is not an identity; it can
/// back several projects).
@MainActor
struct DirectorySource: PaletteSource {
    private static var category: String {
        String(localized: "Directories", comment: "Command palette: the section of folder rows in path mode")
    }

    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        // A typed remote spec offers add/switch, mirroring local directories
        // (#104). No filesystem browsing — the host isn't consulted; the
        // exact spec is the offer.
        if PaletteQuery.isRemoteSpecQuery(query) {
            return remoteItems(spec: query, context: context)
        }
        guard let completion = PathCompleter.complete(query) else { return [] }

        var items: [PaletteItem] = []

        // Every project-backed directory row pairs switch-first with an
        // "add another project" row directly below — the exact typed path
        // AND child completions alike. A directory is not an identity, so
        // adding a second project must not require typing the full path
        // (a prefix that narrows to one child would otherwise offer only
        // the switch). `score` is a running counter so pairs stay adjacent
        // and ordering stays deterministic.
        var score = 0
        func appendRows(name: String, fullPath: String) {
            let existing = context.projectStore.project(matchingPath: fullPath)
            items.append(directoryItem(
                name: name,
                fullPath: fullPath,
                existing: existing,
                context: context,
                score: score
            ))
            score += 1
            if existing != nil {
                items.append(newProjectItem(name: name, fullPath: fullPath, context: context, score: score))
                score += 1
            }
        }

        // Exact match at the top (when the typed path is itself a directory).
        if let exact = completion.exactMatch {
            appendRows(name: (exact as NSString).lastPathComponent, fullPath: exact)
        }

        // Children rank below every exact-match row. The completer's cap
        // counts directories, not rows — a backed child's add-another row
        // rides along.
        for child in completion.children {
            appendRows(name: (child as NSString).lastPathComponent, fullPath: child)
        }

        return items
    }

    func emptyItems(context _: PaletteContext) -> [PaletteItem]? {
        nil
    }

    /// Items for a typed remote spec, shaped like the local exact match: an
    /// existing project matching the spec (structurally, via
    /// `ProjectPath.matches`) switches, with an add-another item below;
    /// otherwise a single item creates the remote project. The display name
    /// is `ProjectPath.remoteDisplayName`.
    private func remoteItems(spec: String, context: PaletteContext) -> [PaletteItem] {
        let name: String = if case let .remote(_, host, directory)? = ProjectPath.remote(from: spec) {
            ProjectPath.remoteDisplayName(host: host, directory: directory)
        } else {
            spec
        }
        if let existing = context.projectStore.projects.first(where: { ProjectPath.matches($0.path, spec) }) {
            let switchItem = PaletteItem(
                id: "remote-switch:\(spec)",
                title: existing.name,
                subtitle: String(localized: "Switch to remote project: \(spec)"),
                category: Self.category,
                score: 0
            ) { [appState = context.appState] in
                appState.showLastTab(of: existing)
            }
            return [switchItem, newProjectItem(name: name, fullPath: spec, context: context, score: 1)]
        }
        let addItem = PaletteItem(
            id: "remote-open:\(spec)",
            title: name,
            subtitle: String(localized: "Add remote project: \(spec)"),
            category: Self.category,
            score: 0,
            opensScope: Self.remoteFolderScope(spec, context: context)
        ) {}
        return [addItem]
    }

    /// A new remote project goes through step 2 of New Remote Project, the
    /// folder on the host, filled in (`RemoteHostsPaletteScope.folderInput`):
    /// Return checks the folder on the host (0358), and the user can
    /// correct it there.
    private static func remoteFolderScope(_ spec: String, context: PaletteContext) -> PaletteScopeID? {
        guard case let .remote(user, host, directory) = ProjectPath.parse(spec) else { return nil }
        return .input(RemoteHostsPaletteScope.folderInput(
            destination: HostCommands.destination(user: user, host: host),
            directory: directory,
            context: context
        ))
    }

    private func directoryItem(
        name: String,
        fullPath: String,
        existing: Project?,
        context: PaletteContext,
        score: Int
    ) -> PaletteItem {
        if let existing {
            return PaletteItem(
                id: "dir-switch:\(fullPath)",
                title: existing.name,
                subtitle: String(localized: "Switch to project: \(fullPath)"),
                category: Self.category,
                score: score
            ) { [appState = context.appState] in
                appState.showLastTab(of: existing)
            }
        }
        return PaletteItem(
            id: "dir-open:\(fullPath)",
            title: name,
            subtitle: String(localized: "Open as new project: \(fullPath)"),
            category: Self.category,
            score: score
        ) { [appState = context.appState, projectStore = context.projectStore] in
            let project = projectStore.findOrCreate(
                name: name,
                path: fullPath
            )
            appState.selectProject(project)
        }
    }

    /// Offered directly below any switch item whose directory (local or
    /// remote) already backs a project: a directory is not an identity, so a
    /// second, independent project there is a legitimate ask. Always creates
    /// (`ProjectStore.create`), mirroring the folder picker.
    private func newProjectItem(
        name: String,
        fullPath: String,
        context: PaletteContext,
        score: Int
    ) -> PaletteItem {
        PaletteItem(
            id: "dir-new:\(fullPath)",
            title: name,
            subtitle: String(localized: "Add another project: \(fullPath)"),
            category: Self.category,
            score: score,
            opensScope: Self.remoteFolderScope(fullPath, context: context)
        ) { [appState = context.appState, projectStore = context.projectStore] in
            appState.selectProject(projectStore.create(name: name, path: fullPath))
        }
    }
}
