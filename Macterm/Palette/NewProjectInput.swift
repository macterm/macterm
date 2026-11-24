import Foundation

/// The New Project screen (`AppCommand.newProject`): an input screen whose
/// field holds the path of the project's folder, with one row on top,
/// Select in Finder, that shows the folder panel in place of a typed path.
///
/// Its rows are the rows of path mode of the root (`DirectorySource`), so a
/// typed path completes and runs as it does there: a folder that a project
/// has switches to that project, with an Add Another Project row below; any
/// other folder becomes a new project; a remote spec (`devbox:~/api`) opens
/// the New Remote Project dialog, filled in. Return with no row selected
/// runs the top row (`NewProjectInput.commit`).
/// Select in Finder always makes a new project, as the folder panel always
/// did (`AppState.newProjectFromFolderPanel`).
extension PaletteInput {
    static var newProject: PaletteInput {
        PaletteInput(
            id: "new-project",
            title: AppCommand.newProject.title,
            prompt: String(localized: "Type a folder path, or select one in Finder"),
            summary: String(localized: "Add a project from a folder"),
            actions: [
                PaletteInputAction(
                    id: "select-in-finder",
                    title: String(localized: "Select in Finder")
                ) { context in
                    context.appState.newProjectFromFolderPanel(store: context.projectStore)
                },
            ],
            results: NewProjectInput.results,
            commit: NewProjectInput.commit
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

    /// Return with no row selected: run the top row, as the root would, or
    /// refuse a text that names no folder.
    @MainActor
    static func commit(_ text: String, context: PaletteContext) -> PaletteCommit {
        if let top = results(text, context: context).first {
            top.item.action()
            return .done
        }
        let typed = PaletteQuery(raw: text).trimmed
        if typed.isEmpty {
            return .refused(String(localized: "Type the path of a folder."))
        }
        return .refused(String(localized: "There is no folder at \(typed)."))
    }
}
