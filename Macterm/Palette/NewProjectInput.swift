import Foundation

/// The New Project screen (`AppCommand.newProject`): an input screen whose
/// field holds the path of the project's folder.
///
/// Its action row, the first row, is Select in Finder: it shows the folder
/// panel and always makes a new project, as the folder panel always did
/// (`AppState.newProjectFromFolderPanel`). Its results are the rows of path
/// mode of the root (`DirectorySource`), so a typed path completes and runs
/// as it does there: a folder that a project has switches to that project,
/// with an Add Another Project row below; any other folder becomes a new
/// project; a remote spec (`devbox:~/api`) opens the New Remote Project
/// dialog, filled in. A path with no row gets the notice of `PathProblem`,
/// and no action row.
extension PaletteInput {
    static var newProject: PaletteInput {
        PaletteInput(
            id: "new-project",
            title: AppCommand.newProject.title,
            prompt: String(localized: "Type a folder path, or select one in Finder"),
            summary: String(localized: "Add a project from a folder"),
            results: NewProjectInput.results,
            check: NewProjectInput.check
        )
    }
}

enum NewProjectInput {
    /// The rows of path mode of the root for `text`, each with the text that
    /// Tab puts in the field for it: a local folder only, as in the root.
    @MainActor
    static func results(_ text: String, context: PaletteContext) -> [PaletteInputResult] {
        let query = PaletteQuery(raw: text).trimmed
        return DirectorySource().items(query: query, context: context).map { item in
            let path = DirectorySource.path(of: item).flatMap { ProjectPath.isRemote($0) ? nil : $0 }
            return PaletteInputResult(item: item, completion: path.map { PathCompleter.fieldText(for: $0, typed: query) })
        }
    }

    /// Select in Finder, unless the text is a path that has no row: then the
    /// notice of the path, as a local folder field gives it.
    @MainActor
    static func check(_ text: String, context: PaletteContext) -> PaletteInputCheck {
        let typed = PaletteQuery(raw: text).trimmed
        if !typed.isEmpty, !PaletteQuery.isRemoteSpecQuery(typed), !hasRows(typed),
           let problem = PathProblem.local(atPath: typed)
        {
            return .notice(problem.notice(for: typed))
        }
        return .action(PaletteInputAction(title: String(localized: "Select in Finder")) {
            context.appState.postPaletteAction = {
                context.appState.newProjectFromFolderPanel(store: context.projectStore)
            }
            return .done
        })
    }

    /// Whether path mode lists a row for the local path `typed`: the folder
    /// itself, or a folder that completes it.
    private static func hasRows(_ typed: String) -> Bool {
        guard let completion = PathCompleter.complete(typed) else { return false }
        return completion.exactMatch != nil || !completion.children.isEmpty
    }
}
