import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectMemoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ command: String?, exit: Int?, minutesAgo: Double = 0, directory: String? = "/repo") -> MemoryEntry {
        MemoryEntry(
            command: command,
            directory: directory,
            exitCode: exit,
            finishedAt: now.addingTimeInterval(-minutesAgo * 60),
            duration: 1
        )
    }

    // MARK: - The switch

    /// One switch (Settings → Intelligence): off, Toggle Project Insights
    /// has no action and no panel shows, whatever the panel's toggle says.
    /// Synchronous on purpose: no other test on the main actor can run
    /// between the writes and the restore.
    @Test
    func the_switch_gates_the_command_and_the_panel() {
        let state = TestModel.appState()
        let ctx = AppCommandContext(appState: state, projectStore: TestModel.projectStore(state))
        let preferences = Preferences.shared
        let memory = ProjectMemory.shared
        let (wasOn, wasReader) = (preferences.projectMemory, memory.modelReader)
        defer {
            (preferences.projectMemory, memory.modelReader) = (wasOn, wasReader)
            memory.refreshModelAvailability()
        }
        memory.modelReader = { .available }
        memory.refreshModelAvailability()

        let window = WindowState()
        window.projectMemoryPanelVisible = true
        preferences.projectMemory = false
        #expect(AppCommand.toggleProjectMemory.action(in: ctx) == nil)
        #expect(!ProjectMemory.isEnabled)
        #expect(!ProjectMemory.showsPanel(in: window))

        preferences.projectMemory = true
        #expect(AppCommand.toggleProjectMemory.action(in: ctx) != nil)
        #expect(ProjectMemory.showsPanel(in: window))
        window.projectMemoryPanelVisible = false
        #expect(!ProjectMemory.showsPanel(in: window))

        // The Git read after a command: only for a project that a window
        // with its panel open shows.
        let (p, q) = (UUID(), UUID())
        let open = WindowState(activeProjectID: p)
        let closed = WindowState(activeProjectID: q)
        open.projectMemoryPanelVisible = true
        state.registerWindow(open)
        state.registerWindow(closed)
        #expect(state.insightsPanelShows(p))
        #expect(!state.insightsPanelShows(q))
        preferences.projectMemory = false
        #expect(!state.insightsPanelShows(p))
    }

    /// Project Insights needs Apple Intelligence: without the model, the
    /// switch keeps its value, and the feature is off until the model is
    /// back.
    @Test
    func the_feature_is_off_while_apple_intelligence_is_off() {
        let preferences = Preferences.shared
        let memory = ProjectMemory.shared
        let (wasOn, wasReader) = (preferences.projectMemory, memory.modelReader)
        defer {
            (preferences.projectMemory, memory.modelReader) = (wasOn, wasReader)
            memory.refreshModelAvailability()
        }
        preferences.projectMemory = true
        let window = WindowState()
        window.projectMemoryPanelVisible = true

        for availability in [OnDeviceModel.Availability.notReady, .unsupported] {
            memory.modelReader = { availability }
            memory.refreshModelAvailability()
            #expect(!ProjectMemory.isEnabled)
            #expect(!ProjectMemory.showsPanel(in: window))
            #expect(!ProjectMemorySummarizer.isEnabled)
            #expect(preferences.projectMemory)
        }

        memory.modelReader = { .available }
        memory.refreshModelAvailability()
        #expect(ProjectMemory.isEnabled == ProjectMemory.isSupported)
    }

    // MARK: - Recording

    private func end(
        _ command: String?,
        exit: Int?,
        startedAt: Date? = nil,
        directory: String? = "/app",
        outputTail: String? = nil
    ) -> CommandEnd {
        CommandEnd(
            paneID: UUID(),
            projectID: UUID(),
            command: command,
            exitCode: exit,
            directory: directory,
            startedAt: startedAt,
            finishedAt: now,
            outputTail: outputTail
        )
    }

    @Test
    func the_command_and_the_tail_come_from_the_end() throws {
        let reported = try #require(ProjectMemory.reportedCommand("make test  "))
        #expect(reported == "make test")

        let entry = try #require(ProjectMemory.makeEntry(
            end("make test  ", exit: 1, startedAt: now.addingTimeInterval(-3), outputTail: "FAIL checkout")
        ))
        #expect(entry.command == "make test")
        #expect(entry.directory == "/app")
        #expect(entry.failureTail == "FAIL checkout")
        #expect(entry.startedAt == now.addingTimeInterval(-3))

        // A failure whose session sent no output has no tail.
        let other = try #require(ProjectMemory.makeEntry(end("make lint", exit: 1)))
        #expect(other.command == "make lint")
        #expect(other.failureTail == nil)

        // Text with no command is nothing.
        #expect(ProjectMemory.reportedCommand("   ") == nil)
    }

    @Test
    func a_failure_keeps_a_redacted_capped_tail_of_its_output() throws {
        let output = "connecting with API_TOKEN=abc\nerror: rejected"
        let entry = try #require(ProjectMemory.makeEntry(end("API_TOKEN=abc ./deploy", exit: 1, outputTail: output)))
        #expect(entry.command == "API_TOKEN=••• ./deploy")
        #expect(entry.failureTail == "connecting with API_TOKEN=•••\nerror: rejected")
        #expect(entry.outcome == .failure)

        // The session sends more rows than the entry keeps.
        let long = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        let capped = try #require(ProjectMemory.makeEntry(end("make", exit: 2, outputTail: long)))
        #expect(capped.failureTail == MemoryEntry.tail(of: long))
        #expect(capped.failureTail?.hasSuffix("line 30") == true)
        #expect(capped.failureTail?.contains("line 1\n") == false)
    }

    @Test
    func a_success_keeps_no_output() throws {
        let entry = try #require(ProjectMemory.makeEntry(end("make", exit: 0, outputTail: "built")))
        #expect(entry.command == "make")
        #expect(entry.failureTail == nil)
    }

    @Test
    func an_end_with_no_command_is_not_recorded() {
        #expect(ProjectMemory.makeEntry(end(nil, exit: 1, outputTail: "error")) == nil)
        #expect(ProjectMemory.makeEntry(end("  ", exit: 1)) == nil)
    }

    @Test
    func a_command_with_a_leading_space_is_recorded_and_redacted() throws {
        let entry = try #require(ProjectMemory.makeEntry(end(" export TOKEN=abc", exit: 0)))
        #expect(entry.command == "export TOKEN=\(MemoryRedaction.mask)")
        let failure = try #require(ProjectMemory.makeEntry(end(" make", exit: 1, outputTail: "error")))
        #expect(failure.command == "make")
        #expect(failure.failureTail == "error")
    }

    @Test
    func an_end_with_no_start_has_no_duration() throws {
        let entry = try #require(ProjectMemory.makeEntry(end("make", exit: 0)))
        #expect(entry.duration == 0)
        #expect(end("make", exit: 0, startedAt: now.addingTimeInterval(-2.5)).duration == 2.5)
        // A clock that went back gives no negative duration.
        #expect(end("make", exit: 0, startedAt: now.addingTimeInterval(5)).duration == 0)
    }

    /// The recorder takes a command end into its project, and nothing
    /// while the switch is off. Synchronous on purpose, as the switch test:
    /// `isEnabled` reads shared state.
    @Test
    func a_command_end_is_recorded_in_its_project_only_while_the_switch_is_on() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-end-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = Preferences.shared
        let shared = ProjectMemory.shared
        let (wasOn, wasReader) = (preferences.projectMemory, shared.modelReader)
        defer {
            (preferences.projectMemory, shared.modelReader) = (wasOn, wasReader)
            shared.refreshModelAvailability()
        }
        shared.modelReader = { .available }
        shared.refreshModelAvailability()
        let memory = ProjectMemory(store: ProjectMemoryStore(directory: directory))
        let tree = Project(name: "p", path: "/tmp")
        let pinnedProject = PinnedTabs.newProject()
        memory.projectLookup = { id in [tree, pinnedProject].first { $0.id == id } }
        let project = tree.id
        let make = CommandEnd(paneID: UUID(), projectID: project, command: "make", exitCode: 0, startedAt: nil, finishedAt: now)

        preferences.projectMemory = false
        memory.commandEnded(make)
        #expect(memory.store.entries(for: project).isEmpty)

        preferences.projectMemory = true
        memory.commandEnded(make)
        #expect(memory.store.entries(for: project).map(\.command) == (ProjectMemory.isSupported ? ["make"] : []))
        memory.commandEnded(CommandEnd(paneID: UUID(), projectID: pinnedProject.id, command: "make", finishedAt: now))
        #expect(memory.store.entries(for: pinnedProject.id).isEmpty)
        // A project that the lookup does not know is not recorded.
        let unknown = UUID()
        memory.commandEnded(CommandEnd(paneID: UUID(), projectID: unknown, command: "make", finishedAt: now))
        #expect(memory.store.entries(for: unknown).isEmpty)
    }

    @Test
    func nothing_is_suggested_without_the_model_however_much_ran() {
        // The Suggested section used to fall back to the failed command, git
        // actions and the commands run most often. A command is never
        // suggested only because it ran recently: without the model's
        // suggestions the section is empty, as the summary is.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-suggested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = ProjectMemory(store: ProjectMemoryStore(directory: directory))
        let projectID = UUID()
        let entries = [
            entry("npm run dev", exit: 0, minutesAgo: 900),
            entry("npm run dev", exit: 0, minutesAgo: 600),
            entry("cargo build", exit: 0, minutesAgo: 20),
            entry("make test", exit: 1, minutesAgo: 1),
        ]
        #expect(memory.suggestedActions(projectID: projectID, entries: entries).isEmpty)
        // A Git state that calls for a pull and a status adds nothing either.
        var git = GitStatus(branch: "main", upstream: "origin/main")
        git.behind = 3
        git.unstaged = 2
        #expect(ProjectMemorySuggestions.actions(from: [], entries: entries, git: git).isEmpty)
        // The failure is still the summary's to show.
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure?.command == "make test")
    }

    private func makeBackgroundMemory(runs: @escaping @MainActor () -> Void) -> (ProjectMemory, ProjectMemorySummarizer, Project) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-bg-\(UUID().uuidString)", isDirectory: true)
        let memory = ProjectMemory(store: ProjectMemoryStore(directory: directory))
        let summarizer = ProjectMemorySummarizer()
        summarizer.debounce = .milliseconds(10)
        summarizer.loadStored = { _ in nil }
        summarizer.storeSummary = { _, _ in }
        summarizer.suggester = { _, _ in [] }
        summarizer.streamer = { _, _, _ in
            runs()
            return AsyncThrowingStream { continuation in
                continuation.yield("You built the project.")
                continuation.finish()
            }
        }
        memory.summarizer = summarizer
        memory.summaryAllowed = { true }
        memory.gitReader = { _ in nil }
        memory.summaryQuietPeriod = .milliseconds(40)
        let project = Project(name: "acme", path: "/tmp", sortOrder: 0)
        memory.projectLookup = { $0 == project.id ? project : nil }
        return (memory, summarizer, project)
    }

    @Test
    func a_project_with_no_folder_reads_no_git() async throws {
        let (memory, _, _) = makeBackgroundMemory {}
        var reads = 0
        memory.gitReader = { _ in
            reads += 1
            return GitStatus(branch: "main")
        }
        let parent = Project(name: "parent", path: "", sortOrder: 0)
        memory.projectLookup = { $0 == parent.id ? parent : nil }
        memory.refreshGit(parent.id)
        let deadline = Date().addingTimeInterval(2)
        while !memory.gitAnswered.contains(parent.id), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(memory.gitAnswered.contains(parent.id))
        #expect(reads == 0)
        #expect(memory.git[parent.id] == nil)
    }

    private func waitForSummary(_ summarizer: ProjectMemorySummarizer, _ project: UUID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while summarizer.state(for: project).phase != .done, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(summarizer.state(for: project).phase == .done)
    }

    @Test
    func a_quiet_project_gets_its_summary_in_the_background_once() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        memory.store.append(entry("make build", exit: 0), to: project.id)

        // Two commands close together: the second restarts the wait.
        memory.scheduleBackgroundSummary(project.id)
        try await Task.sleep(for: .milliseconds(20))
        memory.scheduleBackgroundSummary(project.id)
        try await Task.sleep(for: .milliseconds(30))
        #expect(summarizer.state(for: project.id).phase == .idle)

        try await waitForSummary(summarizer, project.id)
        #expect(summarizer.state(for: project.id).text == "You built the project.")
        #expect(runs == 1)
    }

    @Test
    func reads_of_an_unchanged_git_state_do_not_hold_off_the_summary() async throws {
        // The panel reads git every 15 s and on every change in the git dir.
        // With no summary on record each read used to count as news and
        // restart the quiet wait, so with the panel up the summary never
        // came. A read that finds the same state restarts nothing.
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        // A summary for another state, so that the reads take the quiet
        // wait: a project with no summary gets its first one with no wait.
        summarizer.loadStored = { _ in StoredSummary(key: "older", text: "Earlier work.", writtenAt: Date(), suggestions: nil) }
        var git = GitStatus(branch: "main")
        git.recentCommits = [GitStatus.Commit(hash: "abc1234", subject: "Start", date: now)]
        memory.gitReader = { _ in git }
        let deadline = Date().addingTimeInterval(1)
        memory.refreshGit(project.id)
        while runs == 0 || summarizer.state(for: project.id).phase != .done, Date() < deadline {
            try await Task.sleep(for: .milliseconds(15))
            memory.refreshGit(project.id)
        }
        #expect(summarizer.state(for: project.id).phase == .done)
        #expect(summarizer.state(for: project.id).text == "You built the project.")
        #expect(runs == 1)
    }

    @Test
    func a_git_state_the_summary_has_not_seen_schedules_the_background_summary() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        var git = GitStatus(branch: "main")
        git.recentCommits = [GitStatus.Commit(hash: "abc1234", subject: "Start", date: now)]
        memory.gitReader = { _ in git }
        // No command is recorded: the Git state alone earns the summary.
        #expect(memory.store.entries(for: project.id).isEmpty)

        // No command at all: the Git state alone is the digest.
        memory.refreshGit(project.id)
        try await waitForSummary(summarizer, project.id)
        #expect(runs == 1)

        // The same state again: nothing new to say.
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(80))
        #expect(runs == 1)

        // A commit on another branch: not in the summary, so not news.
        git.branches = [GitStatus.Branch(name: "feature", hash: "abc1234", subject: "Fix", lastCommit: now, worktree: nil)]
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(80))
        #expect(runs == 1)

        // A commit on the current branch: news.
        git.recentCommits = [GitStatus.Commit(hash: "def5678", subject: "Fix", date: now)]
        memory.refreshGit(project.id)
        let deadline = Date().addingTimeInterval(5)
        while runs < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(runs == 2)
    }

    @Test
    func a_project_with_no_summary_gets_its_first_one_at_its_first_git_read() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        // A quiet period that no test waits for: only a summary with no wait
        // can arrive.
        memory.summaryQuietPeriod = .seconds(600)
        var git = GitStatus(branch: "main")
        git.recentCommits = [GitStatus.Commit(hash: "abc1234", subject: "Start", date: now)]
        memory.gitReader = { _ in git }

        memory.refreshGit(project.id)
        try await waitForSummary(summarizer, project.id)
        #expect(runs == 1)

        // With a summary on record, a new Git state waits the quiet period.
        git.recentCommits = [GitStatus.Commit(hash: "def5678", subject: "Fix", date: now)]
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(runs == 1)
        #expect(summarizer.state(for: project.id).phase == .done)
    }

    @Test
    func a_git_read_with_no_state_writes_no_summary() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        memory.summaryQuietPeriod = .seconds(600)

        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(runs == 0)
        #expect(summarizer.state(for: project.id).phase == .idle)
    }

    @Test
    func the_button_writes_a_summary_now_and_again_for_the_same_records() async throws {
        var runs = 0
        let (memory, summarizer, project) = makeBackgroundMemory { runs += 1 }
        memory.store.append(entry("make build", exit: 0), to: project.id)

        await memory.writeSummary(project.id, force: true)
        try await waitForSummary(summarizer, project.id)
        await memory.writeSummary(project.id, force: true)
        try await waitForSummary(summarizer, project.id)
        #expect(runs == 2)
        // The quiet period, for records that have a summary, costs nothing.
        await memory.writeSummary(project.id)
        try await Task.sleep(for: .milliseconds(60))
        #expect(runs == 2)
    }

    @Test
    func a_project_list_that_did_not_load_prunes_nothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-prune-\(UUID().uuidString)", isDirectory: true)
        let store = ProjectMemoryStore(directory: directory)
        let project = UUID()
        store.append(entry("make", exit: 0), to: project)
        store.flush()
        // A connection that never read the model: the list is not the user's.
        let projectStore = ProjectStore(writer: ModelWriter(connection: ModelConnection(server: nil)))
        #expect(projectStore.loadFailed)

        ProjectMemory(store: store).attach(projectStore: projectStore) { _ in false }

        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: project).path))
    }

    @Test
    func memory_covers_projects_only() {
        #expect(ProjectMemory.covers(Project(name: "p", path: "/tmp")))
        #expect(!ProjectMemory.covers(nil))
        // A group: a project of the tree with no folder.
        #expect(!ProjectMemory.covers(Project(name: "g", path: "")))
        #expect(!ProjectMemory.covers(PinnedTabs.newProject()))
        #expect(!ProjectMemory.covers(ScratchTabs.newProject()))
        #expect(!ProjectMemory.covers(QuickTerminalService.newProject()))
        #expect(!ProjectMemory.covers(DesktopWidget(span: DesktopWidgetSpan(columns: 1, rows: 1), topLeft: .zero).newProject))
    }

    @Test
    func the_failure_tail_is_capped() throws {
        let output = (1 ... 50).map { "line \($0)" }.joined(separator: "\n")
        let tail = try #require(MemoryEntry.tail(of: output))
        let lines = tail.split(separator: "\n")
        #expect(lines.count == MemoryEntry.failureTailLines)
        #expect(lines.last == "line 50")
        #expect(MemoryEntry.tail(of: String(repeating: "x", count: 5000))?.utf8.count == MemoryEntry.failureTailBytes)
    }

    // MARK: - Summary

    @Test
    func a_failure_fixed_by_a_later_success_is_resolved() {
        let entries = [
            entry("make test", exit: 1, minutesAgo: 30),
            entry("make test", exit: 0, minutesAgo: 10),
        ]
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure == nil)
    }

    @Test
    func the_latest_failure_with_no_later_success_is_unresolved() {
        let entries = [
            entry("make test", exit: 0, minutesAgo: 60),
            entry("npm run lint", exit: 1, minutesAgo: 30),
            entry("make test", exit: 2, minutesAgo: 10),
            entry("ls", exit: 0, minutesAgo: 5),
        ]
        let summary = ProjectMemorySummary(entries: entries)
        #expect(summary.unresolvedFailure?.command == "make test")
        #expect(summary.lastCommand?.command == "ls")
        #expect(summary.lastActivity == now.addingTimeInterval(-300))
        #expect(summary.commandCount == 4)
    }

    @Test
    func a_retry_with_options_added_resolves_the_failure() {
        // The log of Ethan's screenshot: the card showed `git clean`.
        let entries = [
            entry("git clean", exit: 128, minutesAgo: 790),
            entry("git clean -f", exit: 0, minutesAgo: 789),
            entry("git pull", exit: 0, minutesAgo: 30),
            entry("git status", exit: 0, minutesAgo: 29),
        ]
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure == nil)
        #expect(MemoryCommand.retryKey("git  clean -f -d") == "git clean")
        #expect(MemoryCommand.retryKey("npm run build --watch") == "npm run build")
    }

    @Test
    func an_option_before_the_subcommand_keys_the_whole_command() {
        // The words before the first option would be the program alone.
        #expect(MemoryCommand.retryKey("python -m pytest") == "python -m pytest")
        #expect(MemoryCommand.retryKey("git -C repo push") == "git -C repo push")
        let entries = [
            entry("python -m pytest", exit: 1, minutesAgo: 10),
            entry("python -m http.server", exit: 0, minutesAgo: 5),
        ]
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure?.command == "python -m pytest")
    }

    @Test
    func a_success_of_another_subcommand_does_not_resolve_the_failure() {
        let entries = [
            entry("make test", exit: 2, minutesAgo: 10),
            entry("make lint", exit: 0, minutesAgo: 5),
        ]
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure?.command == "make test")
    }

    @Test
    func a_failure_before_the_latest_pause_is_not_shown() {
        let failed = entry("make test", exit: 2, minutesAgo: 180)
        // An hour with no command ends the stretch the failure was in.
        #expect(ProjectMemorySummary(entries: [failed, entry("git status", exit: 0, minutesAgo: 110)]).unresolvedFailure == nil)
        // A shorter gap is time in an editor: the failure is still the
        // thing to fix.
        #expect(ProjectMemorySummary(entries: [failed, entry("git status", exit: 0, minutesAgo: 130)]).unresolvedFailure?.id == failed.id)
    }

    @Test
    func a_failure_that_is_the_latest_command_always_shows() {
        let entries = [
            entry("make test", exit: 0, minutesAgo: 3000),
            entry("make test", exit: 2, minutesAgo: 0),
        ]
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure?.command == "make test")
    }

    @Test
    func the_model_reads_no_failure_that_the_panel_does_not_show() {
        let entries = [
            entry("git clean", exit: 128, minutesAgo: 30),
            entry("git clean -f", exit: 0, minutesAgo: 29),
            entry("make test", exit: 2, minutesAgo: 1),
        ]
        #expect(ProjectMemorySummary.withoutSettledFailures(entries).map(\.command) == ["git clean -f", "make test"])
        #expect(ProjectMemorySuggestions.candidates(entries: entries) == ["make test", "git clean -f"])
        let digest = ProjectMemoryDigest(projectName: "x", entries: entries, git: nil, now: now)
        #expect(digest?.text.contains("`git clean` failed") == false)
        #expect(digest?.text.contains("`make test` failed") == true)
    }

    @Test
    func every_open_failure_stays_for_the_model() {
        let entries = [
            entry("make test", exit: 2, minutesAgo: 10),
            entry("make lint", exit: 1, minutesAgo: 5),
        ]
        // The card shows the latest; the older one is still open.
        #expect(ProjectMemorySummary(entries: entries).unresolvedFailure?.command == "make lint")
        #expect(ProjectMemorySummary.withoutSettledFailures(entries).count == 2)
        #expect(ProjectMemorySuggestions.candidates(entries: entries) == ["make lint", "make test"])
    }

    @Test
    func a_failure_before_the_latest_pause_is_not_told_to_the_model() {
        let entries = [
            entry("make test", exit: 2, minutesAgo: 180),
            entry("git status", exit: 0, minutesAgo: 60),
        ]
        let digest = ProjectMemoryDigest(projectName: "x", entries: entries, git: nil, now: now)
        #expect(digest?.text.contains("make test") == false)
        #expect(ProjectMemorySuggestions.candidates(entries: entries) == ["git status"])
    }

    // MARK: - Quick actions

    // MARK: - Remote git

    private func makeRemoteMemory() -> (ProjectMemory, Project) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-memory-remote-\(UUID().uuidString)", isDirectory: true)
        let memory = ProjectMemory(store: ProjectMemoryStore(directory: directory))
        let project = Project(name: "api", path: "me@devbox:~/dev/api", sortOrder: 0)
        memory.projectLookup = { $0 == project.id ? project : nil }
        memory.gitReader = { _ in Issue.record("a remote project never reads git locally")
            return nil
        }
        return (memory, project)
    }

    private func waitForGitRead(_ memory: ProjectMemory, _ project: UUID) async throws {
        let deadline = Date().addingTimeInterval(5)
        while memory.readingGit.contains(project) || memory.git[project] == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func a_remote_project_reads_git_on_the_host_and_keeps_the_last_state_when_unreachable() async throws {
        let (memory, project) = makeRemoteMemory()
        var reads: [ProjectPath] = []
        var answer: ProjectGit.RemoteResult = .read(GitStatus(branch: "main"))
        memory.remoteGitReader = { remote in reads.append(remote)
            return answer
        }

        memory.refreshGit(project.id)
        try await waitForGitRead(memory, project.id)
        #expect(reads == [.remote(user: "me", host: "devbox", directory: "~/dev/api")])
        #expect(memory.git[project.id]?.branch == "main")

        answer = .unreachable
        memory.refreshGit(project.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(reads.count == 2)
        #expect(memory.git[project.id]?.branch == "main")
    }
}
