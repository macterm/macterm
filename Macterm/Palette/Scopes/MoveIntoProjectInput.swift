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
    /// can move into, else why not. The match ignores letter case. A path
    /// that only starts a name gives nothing while a completion still
    /// matches it.
    static func check(_ text: String, moving projectID: UUID, appState: AppState, store: ProjectStore) -> PaletteInputCheck {
        let path = normalized(text)
        guard !path.isEmpty else { return .nothing }
        let targets = named(path, in: SidebarTree.moveTargets(for: projectID, in: store), store: store)
        if targets.count > 1 {
            return .notice(String(localized: "More than one project has this path. Rename one of them."))
        }
        guard let target = targets.first else {
            // No target has the path: say why when a project that is not a
            // target has it.
            if let other = named(path, in: store.projects, store: store).first {
                return other.id == store.row(projectID)?.parent
                    ? .notice(String(localized: "The project is already inside “\(path)”."))
                    : .notice(cannotMoveInside)
            }
            return completions(of: path, moving: projectID, store: store).isEmpty
                ? .notice(String(localized: "No project has this path."))
                : .nothing
        }
        let shown = SidebarTree.pathName(of: target, in: store)
        return .action(PaletteInputAction(
            title: String(localized: "Move into “\(shown)”", comment: "Command palette, Move Into Project: the action row"),
            run: {
                appState.moveProject(projectID, into: target.id, store: store, in: appState.keyWindow)
                    ? .done
                    : .refused(cannotMoveInside)
            }
        ))
    }

    /// Why a project cannot go into a project: itself or one inside it.
    private static var cannotMoveInside: String {
        String(localized: "A project cannot move into itself or into a project inside it.")
    }

    /// The projects of `candidates` whose path is `path`, in any letter case.
    private static func named(_ path: String, in candidates: [Project], store: ProjectStore) -> [Project] {
        candidates.filter { SidebarTree.pathName(of: $0, in: store).caseInsensitiveCompare(path) == .orderedSame }
    }

    /// The typed path with no space at its ends and no slash at its ends.
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
