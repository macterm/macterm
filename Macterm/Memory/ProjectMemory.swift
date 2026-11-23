import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectMemory")

/// Project memory: what happened in each project, and what the panel says
/// about it (`ProjectMemoryPanel`).
///
/// - Records each command that finishes in a project's pane
///   (`commandEnded`, from a `CommandEnd`), as a `MemoryEntry` in the project's file
///   (`ProjectMemoryStore`). Never the scrollback.
/// - Reads the project's git state (`ProjectGit`), cached for each project.
///
/// macOS 26 and later only (`isSupported`), needs Apple Intelligence
/// (`modelAvailability`), and is off until the user turns it on
/// (`isEnabled`). The pinned and scratch workspaces, the
/// quick terminal and desktop widgets are not projects, and are never
/// recorded.
@MainActor @Observable
final class ProjectMemory {
    static let shared = ProjectMemory()

    let store: ProjectMemoryStore
    /// The last git state of each local project that the panel showed.
    private(set) var git: [UUID: GitStatus] = [:]
    /// The projects whose git state is being read.
    private(set) var readingGit: Set<UUID> = []
    /// The projects for which a read answered, with a state or with "no
    /// repository". A remote read that got no answer says nothing about
    /// the folder.
    private(set) var gitAnswered: Set<UUID> = []

    /// How long after a failed command's end the screen is read for its
    /// output. The shell sends OSC 133;D before it prints its next prompt,
    /// and the extractor needs that prompt.
    @ObservationIgnored var screenReadDelay = Duration.milliseconds(400)
    @ObservationIgnored var gitReader: (String) async -> GitStatus? = { await ProjectGit.status(at: $0) }
    /// The git state of a remote project, from the host's server over the
    /// host's connection (`ProjectGit.remoteStatus`).
    @ObservationIgnored var remoteGitReader: (ProjectPath) async -> ProjectGit.RemoteResult = { await ProjectGit.remoteStatus($0) }
    @ObservationIgnored private var pendingGitReads: [UUID: Task<Void, Never>] = [:]

    /// How long a project is quiet after its last command before its
    /// summary is written in the background (`scheduleBackgroundSummary`),
    /// so that a panel opened after a break shows it at once.
    @ObservationIgnored var summaryQuietPeriod: Duration = .seconds(600)
    /// How long after a command finishes the panel reads git: long enough
    /// for the shell to settle, short enough that a switch typed in a pane
    /// moves the highlight at once (a local project's git dir watch is
    /// usually first).
    static let gitReadAfterCommand: Duration = .milliseconds(300)
    /// How long the panel waits after a change in the git dir: a burst of
    /// writes (a rebase, a checkout of many files) is one read.
    static let gitReadAfterDirectoryChange: Duration = .milliseconds(250)
    @ObservationIgnored var summarizer: ProjectMemorySummarizer = .shared
    @ObservationIgnored var summaryAllowed: () -> Bool = { ProjectMemorySummarizer.isEnabled }
    @ObservationIgnored private var quietTimers: [UUID: Task<Void, Never>] = [:]

    /// Whether Apple's on-device model can run. Project Insights needs it.
    /// The user turns Apple Intelligence on and off in System Settings, so
    /// it is read again each time Macterm becomes active
    /// (`refreshModelAvailability`). Observable, so that the toolbar button,
    /// the menu and Settings follow it.
    private(set) var modelAvailability: OnDeviceModel.Availability
    /// The seam of `modelAvailability`. The DEBUG `project memory` verb
    /// replaces it, because no CI runner has Apple Intelligence.
    @ObservationIgnored var modelReader: () -> OnDeviceModel.Availability = { OnDeviceModel.availability }
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init(store: ProjectMemoryStore = ProjectMemoryStore()) {
        self.store = store
        modelAvailability = OnDeviceModel.availability
    }

    func refreshModelAvailability() {
        let availability = modelReader()
        if availability != modelAvailability { modelAvailability = availability }
    }

    /// Whether this Mac has the feature at all.
    nonisolated static var isSupported: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// Whether Project Insights is on: the one switch, Settings →
    /// Intelligence (`Preferences.projectMemory`), and Apple Intelligence
    /// on. While it is off, nothing is recorded, Toggle Project Insights has
    /// no action, and the toolbar button and the panel are not there. The
    /// switch keeps its value while Apple Intelligence is off, so the
    /// feature comes back when the user turns it on again.
    static var isEnabled: Bool {
        isSupported && Preferences.shared.projectMemory && shared.modelAvailability == .available
    }

    /// Whether a window shows the panel: the feature is on and that
    /// window's panel is open (`WindowState.projectMemoryPanelVisible`).
    static func showsPanel(in window: WindowState) -> Bool {
        isEnabled && window.projectMemoryPanelVisible
    }

    /// Whether a workspace is a project that memory covers.
    static func covers(_ projectID: UUID) -> Bool {
        !Project.isSynthetic(projectID)
            && projectID != QuickTerminalService.projectID
            && projectID != DesktopWidget.projectID
    }

    // MARK: - Recording

    /// Whether a window shows the memory panel for a project. Set by
    /// `attach`; the git state is read after a command only where someone
    /// looks at it.
    @ObservationIgnored var panelShows: (UUID) -> Bool = { _ in false }

    /// A command finished in a pane (`CommandEnd`, the one input of the
    /// recorder). `screen` reads the pane's screen: it is called only for a
    /// failure, after `screenReadDelay`, to keep the tail of the output.
    func commandEnded(_ end: CommandEnd, screen: @escaping @MainActor () -> String? = { nil }) {
        // Any command can move the branch (`git switch`, a commit), recorded
        // or not: a command with no text changes the Git state just as well.
        if panelShows(end.projectID) { refreshGit(end.projectID, after: Self.gitReadAfterCommand) }
        guard Self.isEnabled, Self.covers(end.projectID) else { return }
        guard let entry = Self.makeEntry(end, screen: nil) else { return }
        guard entry.outcome == .failure else { return record(entry, in: end.projectID) }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: screenReadDelay)
            record(Self.makeEntry(end, screen: screen()) ?? entry, in: end.projectID)
        }
    }

    private func record(_ entry: MemoryEntry, in projectID: UUID) {
        store.append(entry, to: projectID)
        logger.debug("recorded a command in \(projectID, privacy: .public)")
        scheduleBackgroundSummary(projectID)
    }

    /// The command of a command end: the text with its outer spaces
    /// dropped. A command with a leading space is recorded like any other
    /// (Ethan, 2026-11-23). nil for text with no command.
    nonisolated static func reportedCommand(_ text: String) -> String? {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// The entry for a command end, or nil when there is nothing to
    /// remember: the end has no command. A record with no command is noise
    /// in every list that shows it.
    ///
    /// The command comes from the end only. `screen` gives a failure's
    /// output tail, and only when its last command is this command, with or
    /// without a right prompt. Pure, for the tests.
    nonisolated static func makeEntry(_ end: CommandEnd, screen: String?) -> MemoryEntry? {
        guard let command = end.command.flatMap(reportedCommand) else { return nil }
        var entry = MemoryEntry(
            command: MemoryRedaction.redactCommand(command),
            directory: end.directory,
            exitCode: end.exitCode,
            finishedAt: end.finishedAt,
            duration: end.duration
        )
        let output = screen.flatMap(ScreenCommandExtractor.extract(screen:)).flatMap { shown in
            ScreenCommandExtractor.screenCommand(shown.command, shows: command) ? shown.output : nil
        }
        if entry.outcome == .failure, let output, let tail = MemoryEntry.tail(of: output) {
            entry.failureTail = MemoryRedaction.redact(tail)
        }
        return entry
    }

    // MARK: - Git

    /// Read a project's git state again, after `delay`. A read that is
    /// already waiting is replaced. A remote project is read by the host's
    /// server.
    func refreshGit(_ projectID: UUID, after delay: Duration = .zero) {
        guard let project = projectLookup(projectID) else { return }
        pendingGitReads[projectID]?.cancel()
        pendingGitReads[projectID] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            readingGit.insert(projectID)
            let result = await readGit(project)
            // A read that a newer one replaced leaves the mark to that one.
            guard !Task.isCancelled else { return }
            readingGit.remove(projectID)
            let previous = git[projectID]
            apply(result, to: project)
            pendingGitReads[projectID] = nil
            // A Git state the summary has not seen is news as a command is:
            // a commit from another terminal, or a project with no command
            // yet, whose summary is its Git state alone. Only a state that
            // CHANGED: the panel reads git every 15 s and on every change
            // in the git dir, and while no summary is on record every read
            // is "not seen", so a read that found the same state restarted
            // the 10-minute wait, and with the panel up the background
            // summary never came. A project with no summary yet gets its
            // first one at once: the Git state says most of it, and a new
            // project must not wait for commands.
            if case let .read(status?) = result, status != previous, gitStateIsNews(for: project) {
                scheduleBackgroundSummary(projectID, after: summarizer.hasSummary(projectID: projectID) ? nil : .zero)
            }
        }
    }

    /// Whether the summary on record was written for another Git state (or
    /// for none), with the records as they are now.
    private func gitStateIsNews(for project: Project) -> Bool {
        let key = ProjectMemoryDigest.key(projectName: project.name, entries: store.entries(for: project.id), git: git[project.id])
        return summarizer.state(for: project.id).key != key
    }

    /// One read of a project's git state, local or remote. A project with
    /// no folder has no git state, and nothing reads git for it.
    private func readGit(_ project: Project) async -> ProjectGit.RemoteResult {
        guard project.hasFolder else { return .read(nil) }
        if let remote = ProjectPath.parse(project.path), case .remote = remote {
            return await remoteGitReader(remote)
        }
        return await .read(gitReader(project.path))
    }

    /// What a read leaves behind. An answer replaces the state. No answer
    /// keeps the last one: a flaky link must not blank the panel.
    private func apply(_ result: ProjectGit.RemoteResult, to project: Project) {
        guard case let .read(status) = result else { return }
        git[project.id] = status
        gitAnswered.insert(project.id)
    }

    /// The rows of the panel's Suggested section: the model's suggestions
    /// (`ProjectMemorySuggestions`), or none. With no model, no summary yet,
    /// or nothing the model suggested that survives the checks, the section
    /// is hidden, as the summary is: a command is never suggested only
    /// because it ran recently or often.
    func suggestedActions(projectID: UUID, entries: [MemoryEntry]) -> [QuickAction] {
        ProjectMemorySuggestions.actions(
            from: summarizer.state(for: projectID).suggestions, entries: entries, git: git[projectID]
        )
    }

    // MARK: - Background summary

    /// Write a project's summary once it has been quiet for `delay`
    /// (`summaryQuietPeriod` when nil), panel or no panel. A new command, or
    /// a Git state the summary has not seen (`refreshGit`), restarts the
    /// wait. This and the panel's button are the only ways a summary is
    /// written: a panel that opens shows the stored one, and a command that
    /// finishes only restarts the wait, so the model never runs in the
    /// middle of work. The one exception is a project's first summary,
    /// which a Git read schedules with no wait (`refreshGit`).
    func scheduleBackgroundSummary(_ projectID: UUID, after delay: Duration? = nil) {
        quietTimers[projectID]?.cancel()
        let wait = delay ?? summaryQuietPeriod
        quietTimers[projectID] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            quietTimers[projectID] = nil
            await writeSummary(projectID)
        }
    }

    /// Write a project's summary now. The git state is read fresh: the
    /// panel's cached one may be old, or absent when no panel was up.
    /// `force` writes it again for records that have one (the panel's
    /// button); otherwise the same records cost nothing.
    func writeSummary(_ projectID: UUID, force: Bool = false) async {
        guard summaryAllowed(), let project = projectLookup(projectID) else { return }
        await apply(readGit(project), to: project)
        guard !Task.isCancelled else { return }
        summarizer.refresh(
            projectID: projectID,
            digest: ProjectMemoryDigest(
                projectName: project.name,
                entries: store.entries(for: projectID),
                git: git[projectID],
                replyLanguage: OnDeviceModel.replyLanguage
            ),
            force: force
        )
    }

    /// Delete a project's memory, its cached git state and its summary.
    func forget(_ projectID: UUID) {
        quietTimers.removeValue(forKey: projectID)?.cancel()
        store.forget(projectID)
        git[projectID] = nil
        summarizer.forget(projectID: projectID)
    }

    /// Project lookup for the git read. Set by `attach`.
    @ObservationIgnored var projectLookup: (UUID) -> Project? = { _ in nil }

    /// Hand the feature the project list, and delete the memory of projects
    /// that were removed while Macterm was not running. A project list that
    /// did not load is not the user's: nothing is pruned against it, as the
    /// reapers skip a workspace file that did not load.
    func attach(projectStore: ProjectStore, panelShows: @escaping (UUID) -> Bool) {
        projectLookup = { [weak projectStore] id in projectStore?.projects.first { $0.id == id } }
        self.panelShows = panelShows
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ProjectMemory.shared.refreshModelAvailability() }
            }
        }
        guard Self.isSupported, !projectStore.loadFailed else { return }
        store.prune(keeping: Set(projectStore.projects.map(\.id)))
    }
}
