import Foundation

/// The palette's Move Into Project screen (design 013 §2): an input screen
/// (`PaletteInput`) whose field holds the path of names of the project to
/// move into, `Work/api`. The completions are the projects that the
/// project can move into (`SidebarTree.moveTargets`), each by its path.
/// The action row shows only for a path that names one of them.
@MainActor
enum MoveIntoProjectInput {
    /// The screen that moves `projectID`. Its id names the project, so a
    /// screen for another project is another screen.
    static func make(projectID: UUID, appState: AppState, store: ProjectStore) -> PaletteInput {
        PaletteInput(
            id: "move-into-project:\(projectID.uuidString)",
            pill: PalettePill(title: AppCommand.moveIntoProject.title, icon: "folder"),
            prompt: String(localized: "Type the path of a project, for example Work/api"),
            completions: { completions(of: $0, moving: projectID, store: store) },
            check: { check($0, moving: projectID, appState: appState, store: store) }
        )
    }

    /// The projects that `projectID` can move into whose path matches
    /// `text`, best first. An empty field lists all of them.
    static func completions(of text: String, moving projectID: UUID, store: ProjectStore) -> [PaletteCompletion] {
        let rows = SidebarTree.moveTargets(for: projectID, in: store).map { target in
            let path = SidebarTree.pathName(of: target, in: store)
            return PaletteCompletion(title: path, value: path)
        }
        return Search.rank(rows, by: normalized(text)) { [$0.value] }
    }

    /// The action row for a path that names one project that `projectID`
    /// can move into, else why not. A path that only starts a name gives
    /// nothing while a completion still matches it.
    static func check(_ text: String, moving projectID: UUID, appState: AppState, store: ProjectStore) -> PaletteInputCheck {
        let path = normalized(text)
        guard !path.isEmpty else { return .nothing }
        let named = store.projects.filter { SidebarTree.pathName(of: $0, in: store) == path }
        guard let target = named.first else {
            return completions(of: path, moving: projectID, store: store).isEmpty
                ? .notice(String(localized: "No project has this path."))
                : .nothing
        }
        guard named.count == 1 else {
            return .notice(String(localized: "More than one project has this path."))
        }
        if target.id == store.row(projectID)?.parent {
            return .notice(String(localized: "The project is already in this project."))
        }
        guard SidebarTree.moveTargets(for: projectID, in: store).contains(where: { $0.id == target.id }) else {
            return .notice(String(localized: "A project cannot move into itself or into a project inside it."))
        }
        return .action(PaletteInputAction(
            title: String(localized: "Move into “\(path)”", comment: "Command palette, Move Into Project: the action row"),
            run: {
                appState.moveProject(projectID, into: target.id, store: store, in: appState.keyWindow)
                    ? .done
                    : .refused(String(localized: "A project cannot move into itself or into a project inside it."))
            }
        ))
    }

    /// The typed path with no space at its ends and no slash at its ends.
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
