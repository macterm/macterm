import Foundation

/// The New Project screen (`AppCommand.newProject`): an input screen whose
/// field holds the path of the project's folder.
///
/// - With an empty field, its one action row is Select in Finder. It shows
///   the folder panel and always makes a new project
///   (`AppState.newProjectFromFolderPanel`). Any typed character takes it
///   away (Ethan, 0586).
/// - For a typed path, the rows are the folder rows of the root palette's
///   path mode (`DirectorySource`). The typed folder comes first. The
///   folders under it, or the folders that complete it, come next.
/// - Each row is the action (Ethan, 0594). Return or a click on the
///   selected row adds the folder as a project. For a folder that a
///   project has, the row switches to that project, and the row under it
///   adds another project. Tab puts the folder in the field.
/// - A remote spec (`devbox:~/api`) gets the remote rows of the root
///   palette. Tab does not fill them.
/// - A path with no row gets the notice of `PathProblem`, and no rows.
extension PaletteInput {
    static var newProject: PaletteInput {
        PaletteInput(
            id: "new-project",
            title: AppCommand.newProject.title,
            prompt: String(localized: "Type a folder path, or select one in Finder"),
            summary: String(localized: "Add a project from a folder"),
            choices: NewProjectInput.choices,
            check: NewProjectInput.check
        )
    }
}

enum NewProjectInput {
    /// The folder rows of the root palette's path mode for the typed path.
    @MainActor
    static func choices(_ text: String, context: PaletteContext) -> [PaletteInputChoice] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return DirectorySource().items(query: typed, context: context).map { item in
            PaletteInputChoice(
                item: item,
                value: DirectorySource.path(of: item)
                    .flatMap { ProjectPath.isRemote($0) ? nil : PathCompleter.fieldText(for: $0, typed: typed) }
            )
        }
    }

    @MainActor
    static func check(_ text: String, context: PaletteContext) -> PaletteInputCheck {
        if text.isEmpty {
            let appState = context.appState
            let store = context.projectStore
            return .action(PaletteInputAction(title: String(localized: "Select in Finder")) {
                appState.postPaletteAction = { appState.newProjectFromFolderPanel(store: store) }
                return .done
            })
        }
        // Spaces alone are typed text: no Select in Finder, and no path.
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || !choices(text, context: context).isEmpty { return .nothing }
        // A folder always has its own row, so a path with no row has a
        // problem.
        return .notice((PathProblem.local(atPath: typed) ?? .missing).notice(for: typed))
    }
}
