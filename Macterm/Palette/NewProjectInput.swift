import Foundation

/// The New Project screen (`AppCommand.newProject`): an input screen whose
/// field holds the path of the project's folder.
///
/// It has one action row, as every input screen has (Ethan, 0578):
/// - With an empty field, Select in Finder. It shows the folder panel and
///   always makes a new project (`AppState.newProjectFromFolderPanel`). Any
///   typed character takes it away (Ethan, 0586).
/// - For a typed folder, `New Project "<path>"`, or `Switch to "<name>"`
///   when a project already has that folder. A remote spec
///   (`devbox:~/api`) gets the same rows; its new project goes through the
///   New Remote Project dialog, filled in.
/// - A path that is not a folder gets the notice of `PathProblem`, and no
///   action row.
///
/// The completions are the folders under the typed path, each with its
/// full path, as path mode of the root shows them
/// (`PaletteInput.pathCompletions`).
extension PaletteInput {
    static var newProject: PaletteInput {
        PaletteInput(
            id: "new-project",
            title: AppCommand.newProject.title,
            prompt: String(localized: "Type a folder path, or select one in Finder"),
            summary: String(localized: "Add a project from a folder"),
            completions: { PaletteInput.pathCompletions($0.trimmingCharacters(in: .whitespaces)) },
            check: NewProjectInput.check
        )
    }
}

enum NewProjectInput {
    @MainActor
    static func check(_ text: String, context: PaletteContext) -> PaletteInputCheck {
        let typed = text.trimmingCharacters(in: .whitespaces)
        let appState = context.appState
        let store = context.projectStore
        if text.isEmpty {
            return .action(PaletteInputAction(title: String(localized: "Select in Finder")) {
                appState.postPaletteAction = { appState.newProjectFromFolderPanel(store: store) }
                return .done
            })
        }
        // Spaces alone are typed text: no Select in Finder, and no path.
        if typed.isEmpty { return .nothing }
        if PaletteQuery.isRemoteSpecQuery(typed) {
            if let existing = store.projects.first(where: { ProjectPath.matches($0.path, typed) }) {
                return switchAction(to: existing, appState: appState)
            }
            return .action(PaletteInputAction(title: newProjectTitle(typed)) {
                DirectorySource.addRemote(typed, appState: appState)
                return .done
            })
        }
        if let problem = PathProblem.local(atPath: typed) {
            return .notice(problem.notice(for: typed))
        }
        let path = ProjectPath.normalizedForStorage((typed as NSString).expandingTildeInPath)
        if let existing = store.project(matchingPath: path) {
            return switchAction(to: existing, appState: appState)
        }
        return .action(PaletteInputAction(title: newProjectTitle(typed)) {
            appState.selectProject(store.create(name: (path as NSString).lastPathComponent, path: path))
            return .done
        })
    }

    private static func newProjectTitle(_ typed: String) -> String {
        String(localized: "New Project \"\(typed)\"", comment: "Palette: the action row of the New Project screen for a typed folder")
    }

    @MainActor
    private static func switchAction(to project: Project, appState: AppState) -> PaletteInputCheck {
        .action(PaletteInputAction(title: String(
            localized: "Switch to \"\(project.name)\"",
            comment: "Palette: the action row of the New Project screen for a folder that a project has"
        )) {
            appState.showLastTab(of: project)
            return .done
        })
    }
}
