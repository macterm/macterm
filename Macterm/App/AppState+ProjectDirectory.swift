import Foundation

/// Change Project Directory: the one way to give a project another folder,
/// on this Mac or on the project's host. Open panes and their sessions stay where they are; a new tab
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
    /// palette builds its row.
    ///
    /// A remote project has no folder rows: nothing lists a folder on the
    /// host. A typed folder gives one action row, `Change to "<folder>"`,
    /// and the host checks the folder when the row runs, as New Remote
    /// Project does (`folderCheck`, `RemoteHosts.checkFolder` by default).
    func changeProjectDirectoryInput(
        for project: Project,
        projectStore: ProjectStore,
        paneDirectory: (@MainActor () -> String?)? = nil,
        folderCheck: (@MainActor (String, String) async -> RemoteHosts.FolderCheck)? = nil
    ) -> PaletteInput {
        let projectID = project.id
        let readPaneDirectory = paneDirectory ?? { [self] in currentPaneDirectory(of: project) }
        if case let .remote(user, host, _) = ProjectPath.parse(project.path) {
            let destination = HostCommands.destination(user: user, host: host)
            let checkFolder = folderCheck ?? { await RemoteHosts.shared.checkFolder($0, destination: $1) }
            return PaletteInput(
                id: "changeProjectDirectory:\(projectID.uuidString)",
                pill: Self.changeProjectDirectoryPill,
                prompt: String(localized: "Type a folder path on \(destination)"),
                check: { [self] text in
                    let folder = text.trimmingCharacters(in: .whitespaces)
                    if folder.isEmpty {
                        return paneDirectoryAction(readPaneDirectory(), for: project, projectStore: projectStore)
                    }
                    return .action(PaletteInputAction(
                        title: String(localized: "Change to \"\(folder)\""),
                        check: (
                            message: String(localized: "Checking the folder on \(destination)"),
                            answer: {
                                await RemoteHosts.refusal(checkFolder(folder, destination), directory: folder, destination: destination)
                            }
                        ),
                        run: { [self] in setProjectDirectory(projectID, to: folder, projectStore: projectStore) }
                    ))
                }
            )
        }
        return PaletteInput(
            id: "changeProjectDirectory:\(projectID.uuidString)",
            pill: Self.changeProjectDirectoryPill,
            prompt: String(localized: "Type a folder path"),
            choices: { [self] text, _ in
                changeProjectDirectoryChoices(for: text, projectID: projectID, projectStore: projectStore)
            },
            check: { [self] text in
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    return paneDirectoryAction(readPaneDirectory(), for: project, projectStore: projectStore)
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

    /// The action row of an empty field: "Current Pane's Directory", with
    /// the pane's folder as its subtitle, when `paneDirectoryOffer` has one.
    /// The pane is in the folder, so it needs no check.
    private func paneDirectoryAction(_ directory: String?, for project: Project, projectStore: ProjectStore) -> PaletteInputCheck {
        guard let offer = Self.paneDirectoryOffer(directory, for: project) else { return .nothing }
        return .action(PaletteInputAction(
            title: String(localized: "Current Pane's Directory"),
            subtitle: offer,
            run: { [self] in setProjectDirectory(project.id, to: offer, projectStore: projectStore) }
        ))
    }

    /// The folder of the focused pane, when the key window shows a tab of
    /// `project`. A remote pane's folder is the one that its shell reports
    /// on the host.
    func currentPaneDirectory(of project: Project) -> String? {
        guard !keyWindowShowsProjectScreen, let pane = focusedPane(for: project.id) else { return nil }
        if project.isRemote { return SurfaceRegistry.shared.view(of: pane)?.currentPwd }
        return pane.liveLocalWorkingDirectory()
    }

    /// The folder that the pane row offers: the pane's folder, unless it is
    /// unknown or the project's own. For a remote project both are folders
    /// on the host. Nil for a project with no folder (design 013): its
    /// screen has only the typed field.
    static func paneDirectoryOffer(_ directory: String?, for project: Project) -> String? {
        guard project.hasFolder, let directory, !directory.isEmpty else { return nil }
        if case let .remote(_, _, projectDirectory) = ProjectPath.parse(project.path) {
            let trimmed = { (path: String) in path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
            return trimmed(directory) == trimmed(projectDirectory) ? nil : trimmed(directory)
        }
        let normalized = ProjectPath.normalizedForStorage(directory)
        return normalized == ProjectPath.normalizedForStorage(project.path) ? nil : normalized
    }

    /// Set the folder of a project to `path`. A local project: `~` expands,
    /// and a `path` that is not a folder on this Mac is refused, with the
    /// path as the user typed it (`~` stays `~`). A remote project: `path`
    /// is a folder on the same host, which the caller checked with the host
    /// first. Refused too when the project is gone.
    func setProjectDirectory(_ projectID: UUID, to path: String, projectStore: ProjectStore) -> PaletteCommit {
        guard let project = projectStore.projects.first(where: { $0.id == projectID }) else {
            return .refused(String(localized: "The project is not available"))
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .refused(String(localized: "Type a folder path"))
        }
        if case let .remote(user, host, _) = ProjectPath.parse(project.path) {
            let destination = HostCommands.destination(user: user, host: host)
            guard let remotePath = ProjectPath.composeRemote(host: destination, directory: trimmed) else {
                return .refused(PathProblem.missing.notice(for: trimmed))
            }
            projectStore.setPath(id: projectID, to: remotePath)
            return .done
        }
        if let problem = PathProblem.local(atPath: trimmed) {
            return .refused(problem.notice(for: trimmed))
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        projectStore.setPath(id: projectID, to: expanded)
        return .done
    }
}
