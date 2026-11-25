import Foundation

/// The scratch tabs (#665): a hidden project of the model (design/010 §11)
/// for tabs that belong to no project and that are not pinned, with
/// `sidebar: bottom` (its tabs are rows below the tree), `removable: false`
/// and the alias `scratch`. The app makes it when the first scratch tab
/// opens. Code finds it by its alias, never by an id.
///
/// A scratch tab is an ordinary tab. The difference from a project tab is
/// only what is around it: no project directory (a new tab starts in home),
/// no layout file, no rename, no color, no worktrees, and no unload. The
/// difference from a pinned tab is the lifecycle: closing a scratch tab
/// closes it for good, and nothing declares it in a YAML file.
enum ScratchTabs {
    /// The sidebar header and the window title. Not localized, like
    /// `PinnedTabs.displayName`: it is also the name the CLI resolves.
    static let displayName = "Scratch Tabs"

    /// The alias of the scratch project, and the short selector the CLI
    /// also accepts: `--project scratch`.
    static let shortName = "scratch"
    static var alias: String { shortName }

    /// The icon of every scratch row, in place of the user's tab icon, as
    /// the pin is for a pinned row. The rows have no header and no separator
    /// around them, so the icon is what says that these tabs belong to no
    /// project. A scribble reads as "scratch" at row size.
    static let iconSymbol = "scribble.variable"

    /// Whether `name` is this workspace's, which no project may carry.
    /// `ControlHandler.resolveProject` reads both spellings as the scratch
    /// workspace before it looks at any project. Case-insensitive and blind
    /// to padding, as `PinnedTabs.reservesName`.
    static func reservesName(_ name: String) -> Bool {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded == displayName.lowercased() || folded == shortName
    }

    /// Why a typed name was refused, as the app says it.
    static let reservedNameMessage = String(
        localized: "“\(displayName)” is a reserved name for the tabs without a project. Select another name."
    )

    /// Where a new scratch tab starts: the user's home, as a pinned tab does.
    /// `tab-inherit-working-directory` still applies, so a tab opened from a
    /// scratch pane can follow that pane's directory.
    static var fallbackRoot: String { ProjectPath.currentHome }

    /// The request of the scratch project (design/010 §11, §2).
    static func newProject(id: String) -> MactermProtocol.Project {
        .init(id: id, name: displayName, path: "", sidebar: .bottom, removable: false, alias: alias)
    }

    /// The scratch project as the app makes it: a new id.
    static func newProject() -> Project {
        var project = Project(id: UUID(), name: displayName, path: "")
        project.sidebar = .bottom
        project.removable = false
        project.alias = alias
        return project
    }
}
