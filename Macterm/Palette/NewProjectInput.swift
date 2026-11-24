import Foundation

/// The New Project screen (`AppCommand.newProject`): an input screen whose
/// field holds the path of the project's folder, with one row on top,
/// Select in Finder, that shows the folder panel in place of a typed path.
///
/// Return on a typed folder does what the root's path mode does with the
/// same text (`DirectorySource`): a folder that a project already has
/// selects that project, any other folder becomes a new project, and a
/// remote spec (`devbox:~/api`) opens the New Remote Project dialog,
/// filled in. Select in Finder always makes a new project, as the folder
/// panel always did (`AppState.newProjectFromFolderPanel`).
extension PaletteInput {
    static var newProject: PaletteInput {
        PaletteInput(
            id: "new-project",
            pill: PalettePill(title: AppCommand.newProject.title, icon: "folder.badge.plus"),
            prompt: String(localized: "Type a folder path, or select one in Finder"),
            summary: String(localized: "Add a project from a folder"),
            actions: [
                PaletteInputAction(
                    id: "select-in-finder",
                    title: String(localized: "Select in Finder"),
                    icon: "folder"
                ) { context in
                    guard let project = context.appState.newProjectFromFolderPanel(store: context.projectStore) else { return }
                    NewProjectInput.expandRow(of: project, appState: context.appState)
                },
            ],
            completions: PaletteInput.pathCompletions,
            commit: NewProjectInput.commit
        )
    }
}

enum NewProjectInput {
    /// Add or select the project of the folder at `text`, or refuse a path
    /// that names no folder.
    @MainActor
    static func commit(_ text: String, context: PaletteContext) -> PaletteCommit {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            return .refused(String(localized: "Type the path of a folder."))
        }
        if PaletteQuery.isRemoteSpecQuery(typed) {
            if let existing = context.projectStore.projects.first(where: { ProjectPath.matches($0.path, typed) }) {
                select(existing, appState: context.appState)
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
            return .refused(String(localized: "No folder at \(typed)."))
        }
        let project = context.projectStore.findOrCreate(name: (path as NSString).lastPathComponent, path: path)
        select(project, appState: context.appState)
        return .done
    }

    @MainActor
    private static func select(_ project: Project, appState: AppState) {
        appState.selectProject(project)
        expandRow(of: project, appState: appState)
    }

    /// Open the project's row in the sidebar, as the sidebar's own New
    /// Project did.
    @MainActor
    static func expandRow(of project: Project, appState: AppState) {
        appState.expandProjectRow(project.id)
    }
}
