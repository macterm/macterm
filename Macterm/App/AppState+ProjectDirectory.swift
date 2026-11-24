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

    /// The palette screen of Change Project Directory for `project`: a typed
    /// path with completion, and above it the focused pane's folder while
    /// the field is empty (`paneDirectoryOffer`). The screen reads the
    /// pane's folder when it shows, not when the palette builds its row:
    /// `paneDirectory` (`currentPaneDirectory` by default). Nil for a remote
    /// project: its folder is on the host, and nothing completes or checks
    /// a path there.
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
            completions: { text in
                if text.isEmpty, let paneDirectory = Self.paneDirectoryOffer(readPaneDirectory(), for: project) {
                    return [PaletteCompletion(
                        title: String(localized: "Current Pane's Directory"),
                        value: paneDirectory,
                        subtitle: paneDirectory
                    )]
                }
                return PaletteInput.pathCompletions(text)
            },
            commit: { [self] text in
                setProjectDirectory(projectID, to: text, projectStore: projectStore)
            }
        )
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
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"),
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        else {
            return .refused(String(localized: "Path \(trimmed) doesn't exist"))
        }
        guard isDirectory.boolValue else {
            return .refused(String(localized: "\(trimmed) is not a directory"))
        }
        projectStore.setPath(id: projectID, to: expanded)
        return .done
    }
}
