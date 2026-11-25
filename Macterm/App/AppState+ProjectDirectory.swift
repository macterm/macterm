import Foundation

/// Change Project Directory: the one way to give a project another
/// folder, on this Mac or on the project's host. Open panes and their
/// sessions stay where they are; a new tab that starts in the project's
/// folder starts in the new one.
extension AppState {
    /// The palette screen of Change Project Directory for `project`. A
    /// typed path lists folder rows, as the root palette does
    /// (`changeProjectDirectoryChoices`): the typed folder, then the folders
    /// whose names start with the text. Return on a row sets the project's
    /// folder, and Tab goes into it. The notice of `PathProblem` shows when
    /// no row is there, and always for a local file. At an empty
    /// field the action row is "Current Pane's Directory", with the
    /// pane's folder as its subtitle (`paneDirectoryOffer`). The screen
    /// reads the pane's folder through `paneDirectory`
    /// (`currentPaneDirectory` by default) when it shows, not when the
    /// palette builds its row.
    ///
    /// A remote project gets the same folder rows from the host's folder
    /// list (Ethan, 0610; `HostFolderLister`, `listFolders`,
    /// `RemoteHosts.listFolders` by default). With no row, the host says
    /// what the path is (`probeFolder`, `RemoteHosts.probeFolder`), so a
    /// missing path and a file get their notice, as for a local path. When
    /// the host gives no answer (no connection up, no answer in time), a
    /// typed folder gives one action row,
    /// `Change to "<folder>"`, and the host checks the folder when the row
    /// runs, as New Remote Project does (`folderCheck`,
    /// `RemoteHosts.checkFolder` by default).
    func changeProjectDirectoryInput(
        for project: Project,
        projectStore: ProjectStore,
        paneDirectory: (@MainActor () -> String?)? = nil,
        listFolders: (@MainActor (String, String) async -> FolderListing?)? = nil,
        probeFolder: (@MainActor (String, String) async -> RemoteHosts.FolderCheck?)? = nil,
        hostPaneFolder: (@MainActor () async -> String?)? = nil,
        folderCheck: (@MainActor (String, String) async -> RemoteHosts.FolderCheck)? = nil
    ) -> PaletteInput {
        let projectID = project.id
        let readPaneDirectory = paneDirectory ?? { [self] in currentPaneDirectory(of: project) }
        if case let .remote(user, host, _) = ProjectPath.parse(project.path) {
            let destination = HostCommands.destination(user: user, host: host)
            let checkFolder = folderCheck ?? { await RemoteHosts.shared.checkFolder($0, destination: $1) }
            let list = listFolders ?? { await RemoteHosts.shared.listFolders($0, destination: $1) }
            let probe = probeFolder ?? { await RemoteHosts.shared.probeFolder($0, destination: $1) }
            let lister = HostFolderLister(
                list: { folder in await list(folder, destination) },
                probe: { path in await probe(path, destination) }
            )
            let readHostPaneFolder = hostPaneFolder ?? { [self] in
                await hostProcessFolder(of: project, destination: destination)
            }
            return PaletteInput(
                id: "changeProjectDirectory:\(projectID.uuidString)",
                title: AppCommand.changeProjectDirectory.title,
                prompt: String(localized: "Type a folder path on \(destination)"),
                choices: { [self] text, _ in
                    hostFolderChoices(for: text, lister: lister, projectID: projectID, projectStore: projectStore) ?? []
                },
                hostFolders: lister,
                check: { [self] text, _ in
                    let folder = Self.hostFolder(text)
                    if folder.isEmpty {
                        // The shell's report first, as for a local pane,
                        // else the folder of its process on the host.
                        let paneFolder = readPaneDirectory() ?? lister.paneFolder(read: readHostPaneFolder)
                        return paneDirectoryAction(paneFolder, for: project, projectStore: projectStore)
                    }
                    // A session starts only in a folder from `/` or `~`.
                    guard HostCommands.isSafeHostFolder(folder) else {
                        return .notice(PathProblem.missing.notice(for: folder))
                    }
                    // `~name` with no slash names another user's home, not
                    // a folder that the field lists: only the notice, as for
                    // a local path.
                    if folder.hasPrefix("~"), !folder.contains("/"), folder != "~" {
                        return .notice(PathProblem.missing.notice(for: folder))
                    }
                    switch hostFolderChoices(for: text, lister: lister, projectID: projectID, projectStore: projectStore) {
                    case let rows? where !rows.isEmpty:
                        // The folder rows are the action.
                        return .nothing
                    case nil where lister.isListing:
                        return .nothing
                    default:
                        // No folder row: the host listed no match, or could
                        // not list the parent. Ask what the path is, as New
                        // Remote Project does, so a file and a missing path
                        // get their own notice.
                        switch lister.check(folder) {
                        case .missing: return .notice(PathProblem.missing.notice(for: folder))
                        case .notDirectory: return .notice(PathProblem.notDirectory.notice(for: folder))
                        case nil where lister.isListing: return .nothing
                        default: break
                        }
                    }
                    // No answer from the host: the typed folder is the
                    // action, and the host checks it when it runs.
                    let message = lister.hasAnswered
                        ? String(localized: "Checking the folder on \(destination)")
                        : String(localized: "Connecting to \(destination)…")
                    return .action(PaletteInputAction(
                        title: String(localized: "Change to \"\(folder)\""),
                        check: PaletteInputCheckStep(message: message) {
                            let answer = await checkFolder(folder, destination)
                            guard let reason = RemoteHosts.refusal(answer, directory: folder, destination: destination) else { return nil }
                            // Only no connection can change on a retry.
                            return PaletteFailure(title: reason, retryable: answer == .unreachable)
                        },
                        run: { [self] in setProjectDirectory(projectID, to: folder, projectStore: projectStore) }
                    ))
                }
            )
        }
        return PaletteInput(
            id: "changeProjectDirectory:\(projectID.uuidString)",
            title: AppCommand.changeProjectDirectory.title,
            prompt: String(localized: "Type a folder path"),
            choices: { [self] text, _ in
                changeProjectDirectoryChoices(for: text, projectID: projectID, projectStore: projectStore)
            },
            check: { [self] text, _ in
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

    /// The folder rows of a path typed on a remote project: the rows of a
    /// local path (`FolderCompletion`), from the host's folder list. Each
    /// row sets the folder as the user typed it, with no slash at the end
    /// (`hostFolder`). The host listed it, so it needs no check. nil while
    /// the host lists, or when it gave no list.
    func hostFolderChoices(
        for text: String,
        lister: HostFolderLister,
        projectID: UUID,
        projectStore: ProjectStore
    ) -> [PaletteInputChoice]? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard HostCommands.isSafeHostFolder(Self.hostFolder(typed)),
              let rows = FolderCompletion.rows(for: typed, listing: lister.listing)
        else { return nil }
        return rows.map { row in
            let folder = Self.hostFolder(row.fieldText)
            return PaletteInputChoice(
                item: PaletteItem(
                    id: "changeTo:\(row.path)",
                    title: PathRow.title(for: row.path),
                    subtitle: PathRow.Action.changeTo.subtitle(for: row.path),
                    subtitleIsPath: true,
                    action: { [self] in _ = setProjectDirectory(projectID, to: folder, projectStore: projectStore) }
                ),
                value: row.fieldText
            )
        }
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
    /// `project`. A local pane's folder comes from its shell's report, else
    /// from its process. A remote pane's report (OSC 7) comes through the
    /// session (`Pane.sessionDirectory`) on a host with the server, else
    /// through the surface. With no report, the screen asks the host for
    /// the folder of the shell's process (`hostProcessFolder`).
    func currentPaneDirectory(of project: Project) -> String? {
        guard !keyWindowShowsProjectScreen, let pane = focusedPane(for: project.id) else { return nil }
        if project.isRemote { return pane.sessionDirectory ?? SurfaceRegistry.shared.view(of: pane)?.currentPwd }
        return pane.liveLocalWorkingDirectory()
    }

    /// The folder of the focused pane's shell process on the host, from
    /// the host's server (`RemoteHosts.processFolder`). nil for a pane with
    /// no session on a server (a plain ssh shell), and when the host gives
    /// no answer.
    func hostProcessFolder(of project: Project, destination: String) async -> String? {
        guard !keyWindowShowsProjectScreen, let pid = focusedPane(for: project.id)?.hostShellPID else { return nil }
        return await RemoteHosts.shared.processFolder(pid: pid, destination: destination)
    }

    /// The folder that the pane row offers: the pane's folder, unless it is
    /// unknown or the project's own. For a remote project both are folders
    /// on the host. Nil for a project with no folder (design 013): its
    /// screen has only the typed field.
    static func paneDirectoryOffer(_ directory: String?, for project: Project) -> String? {
        guard project.hasFolder, let directory, !directory.isEmpty else { return nil }
        if case let .remote(_, _, projectDirectory) = ProjectPath.parse(project.path) {
            // The shell reports a path on the host. Anything else (a URL, a
            // relative path) is not a folder that a session can start in.
            let folder = hostFolder(directory)
            guard HostCommands.isSafeHostFolder(folder) else { return nil }
            return folder == hostFolder(projectDirectory) ? nil : folder
        }
        let normalized = ProjectPath.normalizedForStorage(directory)
        return normalized == ProjectPath.normalizedForStorage(project.path) ? nil : normalized
    }

    /// A folder on a host as Macterm stores it: no space at the ends, and
    /// no slash at the end (except `/`), so that `~/api/` and `~/api` are
    /// one folder.
    static func hostFolder(_ text: String) -> String {
        var folder = text.trimmingCharacters(in: .whitespaces)
        while folder.count > 1, folder.hasSuffix("/") {
            folder.removeLast()
        }
        return folder
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
            let folder = Self.hostFolder(trimmed)
            guard HostCommands.isSafeHostFolder(folder),
                  let remotePath = ProjectPath.composeRemote(host: destination, directory: folder)
            else {
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
