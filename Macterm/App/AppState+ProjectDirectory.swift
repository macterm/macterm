import Foundation

/// Change Project Directory: the one way to give a local project another
/// folder. Open panes and their sessions stay where they are; a new tab
/// that starts in the project's folder starts in the new one.
extension AppState {
    /// The pill of the screen. An input screen's pill has no glyph, so its
    /// palette row has none either.
    static var changeProjectDirectoryPill: PalettePill {
        PalettePill(title: AppCommand.changeProjectDirectory.title)
    }

    /// The palette screen of Change Project Directory for `project`. A
    /// typed path lists folder rows, as the root palette does
    /// (`changeProjectDirectoryChoices`): the typed folder, then the folders
    /// whose names start with the text. Return on a row sets the project's
    /// folder, and Tab goes into it. The notice of `PathProblem` shows when
    /// no row is there, and always for a file. At an empty
    /// field the action row is "Current Pane's Directory", with the
    /// pane's folder as its subtitle (`paneDirectoryOffer`). The screen
    /// reads the pane's folder through `paneDirectory`
    /// (`currentPaneDirectory` by default) when it shows, not when the
    /// palette builds its row. Nil for a remote project: its folder is on
    /// the host, and nothing completes or checks a path there.
    func changeProjectDirectoryInput(
        for project: Project,
        projectStore: ProjectStore,
        paneDirectory: (@MainActor () -> String?)? = nil
    ) -> PaletteInput? {
        guard !project.isRemote else { return nil }
        let projectID = project.id
        let readPaneDirectory = paneDirectory ?? { [self] in currentPaneDirectory(of: project) }
        return PaletteInput(
            id: "changeProjectDirectory:\(projectID.uuidString)",
            pill: Self.changeProjectDirectoryPill,
            prompt: String(localized: "Type a folder path"),
            choices: { [self] text, _ in
                changeProjectDirectoryChoices(for: text, projectID: projectID, projectStore: projectStore)
            },
            check: { [self] text in
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let paneDirectory = Self.paneDirectoryOffer(readPaneDirectory(), for: project) else {
                        return .nothing
                    }
                    return .action(PaletteInputAction(
                        title: String(localized: "Current Pane's Directory"),
                        subtitle: paneDirectory,
                        run: { [self] in setProjectDirectory(projectID, to: paneDirectory, projectStore: projectStore) }
                    ))
                }
                let path = text.trimmingCharacters(in: .whitespaces)
                let problem = PathProblem.local(atPath: path)
                if let problem, problem == .notDirectory { return .notice(problem.notice(for: path)) }
                if !changeProjectDirectoryChoices(for: path, projectID: projectID, projectStore: projectStore).isEmpty {
                    return .nothing
                }
                return problem.map { .notice($0.notice(for: path)) } ?? .nothing
            }
        )
    }

    /// The folder rows of a typed path (`PathCompleter`): the folder that
    /// it names, then the folders that it completes to. Each row is the
    /// action: it sets the folder of the project. Tab puts its path in the
    /// field (`PathCompleter.fieldText`).
    func changeProjectDirectoryChoices(
        for text: String,
        projectID: UUID,
        projectStore: ProjectStore
    ) -> [PaletteInputChoice] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let completion = PathCompleter.complete(typed) else { return [] }
        let folders = (completion.exactMatch.map { [$0] } ?? []) + completion.children
        return folders.map { folder in
            PaletteInputChoice(
                item: PaletteItem(
                    id: "changeTo:\(folder)",
                    title: PathRow.title(for: folder),
                    subtitle: PathRow.Action.changeTo.subtitle(for: folder),
                    subtitleIsPath: true,
                    action: { [self] in _ = setProjectDirectory(projectID, to: folder, projectStore: projectStore) }
                ),
                value: PathCompleter.fieldText(for: folder, typed: typed)
            )
        }
    }

    /// The folder of the focused pane, when the key window shows a tab of
    /// `project`.
    func currentPaneDirectory(of project: Project) -> String? {
        guard !keyWindowShowsProjectScreen else { return nil }
        return focusedPane(for: project.id)?.liveLocalWorkingDirectory()
    }

    /// The folder that the pane row offers: the pane's folder, unless it is
    /// unknown or the project's own. Nil for a remote project, and for a
    /// project with no folder (design 013): its screen has only the typed
    /// field.
    static func paneDirectoryOffer(_ directory: String?, for project: Project) -> String? {
        guard project.hasFolder, !project.isRemote, let directory, !directory.isEmpty else { return nil }
        let normalized = ProjectPath.normalizedForStorage(directory)
        return normalized == ProjectPath.normalizedForStorage(project.path) ? nil : normalized
    }

    /// Set the folder of a local project to `path` (`~` expands). Refused,
    /// with the reason for the user, when the project is remote or gone, or
    /// when `path` is not a folder on this Mac. The reason names the path as
    /// the user typed it (`~` stays `~`).
    func setProjectDirectory(_ projectID: UUID, to path: String, projectStore: ProjectStore) -> PaletteCommit {
        guard let project = projectStore.projects.first(where: { $0.id == projectID }) else {
            return .refused(String(localized: "The project is not available"))
        }
        guard !project.isRemote else {
            return .refused(AppCommand.changeProjectDirectoryUnavailableReason)
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .refused(String(localized: "Type a folder path"))
        }
        if let problem = PathProblem.local(atPath: trimmed) {
            return .refused(problem.notice(for: trimmed))
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        projectStore.setPath(id: projectID, to: expanded)
        return .done
    }
}
