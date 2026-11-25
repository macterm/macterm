import Foundation

/// The one look of a folder row in a path-completion list: the root
/// palette's path mode (`DirectorySource`) and the folder rows of an
/// input screen (`AppState.changeProjectDirectoryChoices`). The title is
/// the folder name. The subtitle is what the row does and the full path
/// (`Open as new project: /Users/me/api`), drawn on one line and cut in the
/// middle when it is too long (`PaletteItem.subtitleIsPath`), so the end of
/// the path stays.
enum PathRow {
    /// What a row does with its folder: the words before the path. Each
    /// case is one whole string with the path in it, so a translation puts
    /// the path where its language needs it.
    enum Action: Equatable {
        /// The root palette and New Project: a project for the folder.
        case openAsNewProject
        /// The root palette: the project that the folder already backs.
        case switchToProject
        /// The root palette: one more project for a folder that backs one.
        case addAnotherProject
        /// Change Project Directory: the project's new folder.
        case changeTo

        /// The subtitle of a row for the folder at `path`.
        func subtitle(for path: String) -> String {
            switch self {
            case .openAsNewProject: String(localized: "Open as new project: \(path)")
            case .switchToProject: String(localized: "Switch to project: \(path)")
            case .addAnotherProject: String(localized: "Add another project: \(path)")
            case .changeTo: String(localized: "Change to: \(path)")
            }
        }
    }

    /// The title of a row for the folder at `path`: its name.
    static func title(for path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
