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
/// commits the typed text in the same way (`NewProjectInput.commit`).
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
                    title: String(localized: "Select in Finder"),
                    icon: "folder"
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
    /// Tab puts in the field for it.
    @MainActor
    static func results(_ text: String, context: PaletteContext) -> [PaletteInputResult] {
        DirectorySource().items(query: text, context: context).map { item in
            PaletteInputResult(
                item: item,
                completion: DirectorySource.path(of: item).map { PathCompleter.fieldText(for: $0, typed: text) }
            )
        }
    }

    /// Add or select the project of the folder at `text`, or refuse a path
    /// that names no folder: Return when no row is selected.
    @MainActor
    static func commit(_ text: String, context: PaletteContext) -> PaletteCommit {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            return .refused(String(localized: "Type the path of a folder."))
        }
        if PaletteQuery.isRemoteSpecQuery(typed) {
            if let existing = context.projectStore.projects.first(where: { ProjectPath.matches($0.path, typed) }) {
                context.appState.showLastTab(of: existing)
            } else {
                DirectorySource.addRemote(typed, appState: context.appState)
            }
            return .done
        }
        let path = ProjectPath.normalizedForStorage((typed as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .refused(String(localized: "There is no folder at \(typed)."))
        }
        if let existing = context.projectStore.project(matchingPath: path) {
            context.appState.showLastTab(of: existing)
        } else {
            context.appState.selectProject(context.projectStore.create(name: (path as NSString).lastPathComponent, path: path))
        }
        return .done
    }
}
