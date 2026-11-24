import Foundation
@testable import Macterm
import Testing

@MainActor
struct PaneTests {
    /// A foreground report of the pane's session, with the pty's line mode
    /// first, as the session sends them.
    private func report(_ pane: Pane, _ name: String, shell: Bool = false, raw: Bool = false) {
        pane.lineMode = raw ? .raw : .echoing
        pane.applyForeground(SessionForeground(comm: name, isIdle: shell, isShell: shell, command: name))
    }

    private func shellName() -> String {
        // Mirror Pane.defaultShellName: the login shell from the password
        // database, not $SHELL (which is the app-launcher's shell).
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }

    @Test
    func a_lost_remote_pane_shows_reconnecting_while_a_try_runs_and_connection_lost_otherwise() {
        let p = Pane(projectPath: "box:/srv", projectID: UUID())
        #expect(p.remoteLinkBadge == nil)
        p.setRemoteLink(lost: true)
        #expect(p.remoteLinkBadge == .lost)
        p.setRemoteLink(reconnecting: true)
        #expect(p.remoteLinkBadge == .reconnecting)
        p.setRemoteLink(lost: false)
        // A slow first connect of a pane that came back after a restart.
        #expect(p.remoteLinkBadge == .reconnecting)
        p.setRemoteLink(reconnecting: false)
        #expect(p.remoteLinkBadge == nil)
    }

    @Test
    func processTitle_uses_foreground_process_when_running() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "btop"
        #expect(p.processTitle == "btop")
    }

    @Test
    func processTitle_defaults_to_shell_name_when_idle() {
        // No foreground process (idle at a prompt) → the shell name. The OSC
        // title is never consulted.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = nil
        #expect(p.processTitle == shellName())
    }

    @Test
    func processTitle_treats_empty_foreground_name_as_idle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = ""
        #expect(p.processTitle == shellName())
    }

    @Test
    func sidebarSegmentTitle_matches_processTitle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "nvim"
        #expect(p.sidebarSegmentTitle == p.processTitle)
    }

    /// After an app restart, a restored pane attaches to a session whose
    /// `sleep 300` still runs. The session sends its run status at `hello`,
    /// before the foreground that the attach asks for. The pane has had no
    /// input in this app, but the run is real: the name and the state agree.
    @Test
    func a_restored_pane_whose_session_runs_a_program_is_running() {
        let p = Pane(projectPath: "/", projectID: UUID(), sessionName: "macterm-proj-aaaaaaaabbbb")
        p.receiveSessionStatus(MactermProtocol.Status(state: .running))
        report(p, "sleep")
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .running)
        report(p, "zsh", shell: true)
        #expect(p.executionState == .done)
    }

    /// The same, when the foreground report comes first.
    @Test
    func a_running_status_after_the_report_starts_the_run() {
        let p = Pane(projectPath: "/", projectID: UUID(), sessionName: "macterm-proj-aaaaaaaabbbb")
        report(p, "sleep")
        #expect(p.executionState == .idle)
        p.receiveSessionStatus(MactermProtocol.Status(state: .running))
        #expect(p.executionState == .running)
    }

    /// A session at its prompt trusts nothing: start-up foregrounds stay idle.
    @Test
    func an_idle_status_keeps_startup_foregrounds_idle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.receiveSessionStatus(MactermProtocol.Status(state: .idle))
        report(p, "login")
        #expect(p.executionState == .idle)
    }

    /// `pane run '/bin/sh -c "…"'`: the session reports `sh`, a shell by
    /// `/etc/shells`, with the `-c` command line. That is a run, and the
    /// login shell's return ends it (End-to-End, issue 0484).
    @Test
    func a_shell_that_runs_minus_c_is_a_run() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.lineMode = .echoing
        p.applyForeground(SessionForeground(comm: "bash", isIdle: false, isShell: true, command: "-bash"))
        p.recordUserInteraction()
        p.recordCommandSubmission(hasContent: true)
        p.applyForeground(SessionForeground(
            comm: "/bin/sh", isIdle: false, isShell: true, command: "/bin/sh -c sleep 1; printf started; sleep 6"
        ))
        #expect(p.executionState == .running)
        p.applyForeground(SessionForeground(comm: "bash", isIdle: false, isShell: true, command: "-bash"))
        #expect(p.executionState == .done)
    }

    /// A login shell and nushell under ghostty's wrapper own their prompt:
    /// a Return there starts no run.
    @Test
    func a_shell_at_its_prompt_is_no_run() {
        for command in ["-zsh", "/opt/homebrew/bin/nu --execute use ghostty *"] {
            let p = Pane(projectPath: "/", projectID: UUID())
            p.lineMode = .echoing
            p.recordUserInteraction()
            p.recordCommandSubmission(hasContent: true)
            let comm = String(command.split(separator: " ")[0])
            p.applyForeground(SessionForeground(comm: comm, isIdle: false, isShell: true, command: command))
            #expect(p.executionState == .idle)
        }
    }

    @Test
    func executionState_defaults_to_idle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(p.executionState == .idle)
    }

    @Test
    func initialForegroundBeforeUserInteraction_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        report(p, "sleep")
        p.markTerminalActivity()
        p.settleTerminalActivityIfQuiet(now: Date(timeIntervalSince1970: 3), quietInterval: 3)
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .idle)
    }

    @Test
    func progressBeforeUserInteraction_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func layoutCommand_tracksInitialForegroundBeforeUserInteraction() {
        let p = Pane(projectPath: "/", projectID: UUID(), start: .typed("npm test"))
        report(p, "npm")
        #expect(p.executionState == .running)
    }

    @Test
    func executionState_marks_running_then_done_then_idle_on_acknowledge() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markCommandFinished()
        #expect(p.executionState == .done)
        p.acknowledgeCommandCompletion()
        #expect(p.executionState == .idle)
    }

    @Test
    func progressFinishedFromIdle_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markProgressFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func progressStartAndFinish_tracksRunningThenDone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func progressRunning_isNotCompletedByForegroundOrOutputActivity() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        report(p, "sleep")
        p.markTerminalActivity(at: Date(timeIntervalSince1970: 100))
        p.settleTerminalActivityIfQuiet(now: Date(timeIntervalSince1970: 200), quietInterval: 3)
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_settlesCurrentForegroundProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "node")
        p.markCommandRunning()
        #expect(p.executionState == .running)
        p.markProgressFinished()
        #expect(p.executionState == .done)
        report(p, "node")
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_settlesNextForegroundProcessWhenNoneWasCaptured() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        p.markProgressFinished()
        #expect(p.executionState == .done)
        report(p, "node")
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_ignoresOutputFromSettledForegroundProcess() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "node")
        p.markCommandRunning()
        p.markProgressFinished()
        p.markTerminalActivity()
        #expect(p.executionState == .done)
    }

    @Test
    func progressFinished_allowsForegroundRestartAfterProcessChanges() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "node")
        p.markCommandRunning()
        p.markProgressFinished()
        report(p, "python")
        #expect(p.executionState == .running)
    }

    // MARK: - Progress failure (OSC 9;4 ERROR)

    /// The state a SET leaves a pane in once it has had input: a
    /// progress-owned run.
    private func progressRunningPane() -> Pane {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markCommandRunning()
        return p
    }

    @Test
    func progressEnd_endsTheRun() {
        let p = progressRunningPane()
        p.markProgressFinished()
        #expect(p.executionState == .done)
    }

    /// An end with no run to end marks nothing.
    @Test
    func progressEndBeforeAnyRun_marksNothing() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        p.markProgressFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func attention_comesFromTheSession() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(p.attention == MactermProtocol.Attention())
        let flags = MactermProtocol.Attention(unseen: true, failed: true, bell: false)
        p.receiveAttention(flags)
        #expect(p.attention == flags)
        p.receiveAttention(MactermProtocol.Attention())
        #expect(p.attention == MactermProtocol.Attention())
    }

    @Test
    func attention_postsOneNoticeForEachChange() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let count = LockedBox(0)
        let id = p.id
        // Filter by value: each post bridges the id to a new object, and an
        // `object:` filter compares objects by identity. Other tests post too.
        let token = NotificationCenter.default.addObserver(
            forName: .paneAttentionDidChange,
            object: nil,
            queue: nil
        ) { note in
            guard note.object as? UUID == id else { return }
            count.mutate { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let bell = MactermProtocol.Attention(bell: true)
        p.receiveAttention(bell)
        p.receiveAttention(bell)
        p.receiveAttention(MactermProtocol.Attention())

        #expect(count.value == 2)
    }

    @Test
    func markSeen_clearsTheFlagsAndADoneRun() {
        let p = progressRunningPane()
        p.markProgressFinished()
        p.receiveAttention(MactermProtocol.Attention(unseen: true, failed: true, bell: true))
        p.markSeen()
        #expect(p.attention == MactermProtocol.Attention())
        #expect(p.executionState == .idle)
    }

    @Test
    func interaction_marksThePaneSeen() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.receiveAttention(MactermProtocol.Attention(unseen: true, bell: true))
        p.recordUserInteraction()
        #expect(p.attention == MactermProtocol.Attention())
    }

    /// A pane with no surface shows nothing: an unloaded pinned tab must not
    /// keep a dot or the Dock badge.
    @Test
    func teardown_dropsTheFlags() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.receiveAttention(MactermProtocol.Attention(unseen: true, bell: true))
        p.surfacesWillTearDown(hadView: false)
        #expect(p.attention == MactermProtocol.Attention())
    }

    @Test
    func commandFinishedFromIdle_staysIdle() {
        // Shell integration emits OSC 133;D on every precmd, including empty
        // commands (Enter, Ctrl-C, Ctrl-L on an idle prompt). A COMMAND_FINISHED
        // with no preceding running state must not flip the pane to `.done`, or
        // clearing an idle terminal would persist a spurious checkmark.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markCommandFinished()
        #expect(p.executionState == .idle)
    }

    @Test
    func commandFinishedFromRunning_marksDone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "sleep")
        #expect(p.executionState == .running)
        p.markCommandFinished()
        #expect(p.executionState == .done)
    }

    @Test
    func foregroundReport_marks_nonShell_process_as_running() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "sleep")
        #expect(p.foregroundProcessName == "sleep")
        #expect(p.executionState == .running)
    }

    @Test
    func foregroundReport_marks_done_when_foreground_returns_to_shell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "sleep")
        report(p, shellName(), shell: true)
        #expect(p.foregroundProcessName == shellName())
        #expect(p.executionState == .done)
    }

    @Test
    func foregroundReport_marks_longLivedApps_as_running_without_exclusions_when_terminalIsCanonical() {
        for process in ["claude", "pi", "node", "ssh"] {
            let p = Pane(projectPath: "/", projectID: UUID())
            p.recordUserInteraction()
            report(p, process)
            #expect(p.foregroundProcessName == process)
            #expect(p.executionState == .running)
        }
    }

    @Test
    func rawForegroundProcess_doesNotStartFromForegroundAlone() {
        let p = Pane(projectPath: "/", projectID: UUID())
        report(p, "node", raw: true)
        #expect(p.foregroundProcessName == "node")
        #expect(p.executionState == .idle)
    }

    @Test
    func rawForegroundProcess_demotesExistingForegroundOnlyRun_thenSettlesWhenQuiet() {
        // A TUI that spawns canonical, prints, then goes raw (claude, pi) is
        // *starting* its work, not finishing — the raw switch demotes the
        // foreground-owned run to the activity source instead of completing
        // it outright, so it stays `.running` until output actually goes
        // quiet rather than locking the pane `.done` for the whole session.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.recordUserInteraction()
        report(p, "node")
        #expect(p.executionState == .running)

        report(p, "node", raw: true)
        #expect(p.executionState == .running)

        // No further output: the demoted run quiet-settles like any other
        // activity-sourced run.
        p.settleTerminalActivityIfQuiet(now: Date().addingTimeInterval(5), quietInterval: 3)
        #expect(p.executionState == .done)
    }

    @Test
    func rawForegroundProcess_usesOutputActivityUntilQuiet() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        report(p, "node", raw: true)
        p.markTerminalActivity(at: start)
        #expect(p.executionState == .running)

        report(p, "node", raw: true)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(p.executionState == .done)
    }

    @Test
    func terminalActivityWithoutUserInteraction_staysIdle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.markTerminalActivity()
        #expect(p.executionState == .idle)
    }

    @Test
    func terminalActivityAfterUserInteraction_marksRunningUntilQuiet() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        p.markTerminalActivity(at: start)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(2), quietInterval: 3)
        #expect(p.executionState == .running)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(p.executionState == .done)
    }

    @Test
    func commandSubmissionStartsOnSecondInPlaceOutputHeartbeatForAgent() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "pi"
        let submittedAt = Date(timeIntervalSince1970: 100)
        p.recordCommandSubmission(hasContent: true, at: submittedAt)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(0.5))
        #expect(p.executionState == .idle)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(1))
        #expect(p.executionState == .running)
    }

    /// The view carries a programmatic payload's content evidence past the
    /// submission that consumed it only when this is true — otherwise a
    /// `pane run "…"` followed within the carry window by a genuinely blank
    /// Return would report content it doesn't have.
    @Test
    func inPlaceOutputStartIsAllowedOnlyForAnAgentForeground() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(!p.allowsInPlaceOutputStart)
        p.foregroundProcessName = "zsh"
        #expect(!p.allowsInPlaceOutputStart)
        p.foregroundProcessName = "pi"
        #expect(p.allowsInPlaceOutputStart)
    }

    @Test
    func commandSubmissionDoesNotArmInPlaceOutputForOrdinaryRawProgram() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "nvim"
        let submittedAt = Date(timeIntervalSince1970: 100)
        p.recordCommandSubmission(hasContent: true, at: submittedAt)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(0.5))
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(1))
        #expect(p.executionState == .idle)
    }

    @Test
    func blankSubmissionSuppressesImmediateGrowthAndScrollbarActivity() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let submittedAt = Date(timeIntervalSince1970: 100)
        p.markOutputActivity(totalRows: 10, now: submittedAt.addingTimeInterval(-1))
        p.recordCommandSubmission(hasContent: false, at: submittedAt)

        p.markOutputActivity(totalRows: 20, now: submittedAt.addingTimeInterval(0.25))
        p.markTerminalActivity(at: submittedAt.addingTimeInterval(0.5))
        #expect(p.executionState == .idle)
    }

    @Test
    func outputActivitySchedulesQuietPollWake() async {
        let p = Pane(projectPath: "/", projectID: UUID(), activityQuietPollDelay: 0.02)
        p.recordUserInteraction()
        p.markOutputActivity(totalRows: 10)

        await confirmation("quiet output wakes the paused poll") { confirm in
            let fired = LockedBox(false)
            let token = NotificationCenter.default.addObserver(
                forName: .terminalQuietSettleDeadline,
                object: p,
                queue: .main
            ) { _ in
                fired.mutate { $0 = true }
                confirm()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            p.markOutputActivity(totalRows: 20)
            // Poll rather than sleeping a fixed multiple of the delay: a
            // co-scheduled spike on a loaded CI runner can push a 20ms timer
            // well past any fixed margin (cf. #181). The generous ceiling only
            // bounds a genuine failure; a healthy run exits on the first tick.
            for _ in 0 ..< 200 where !fired.value {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// The scheduled wake must land strictly *after* the quiet threshold it
    /// needs to observe as crossed — a wake at exactly the threshold only
    /// settles while timer jitter runs positive, and an occluded window has no
    /// other timer left to retry with.
    @Test
    func quietPollWakeLandsAfterTheSettleThreshold() {
        #expect(TerminalActivityTiming.quietPollDelay > TerminalActivityTiming.quietInterval)
        #expect(
            TerminalActivityTiming.quietPollDelay
                == TerminalActivityTiming.quietInterval + TerminalActivityTiming.quietPollMargin
        )
    }

    @Test
    func foregroundProcessWithOutput_remainsRunningUntilItReturnsToShell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        report(p, "node")
        p.markTerminalActivity(at: start)
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(30), quietInterval: 3)
        #expect(p.executionState == .running)

        report(p, shellName(), shell: true)
        #expect(p.executionState == .done)
    }

    @Test
    func silentForegroundProcess_doesNotSettleUntilItReturnsToShell() {
        let p = Pane(projectPath: "/", projectID: UUID())
        let start = Date(timeIntervalSince1970: 100)
        p.recordUserInteraction()
        report(p, "sleep")
        p.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(30), quietInterval: 3)
        #expect(p.executionState == .running)
        report(p, shellName(), shell: true)
        #expect(p.executionState == .done)
    }

    @Test
    func init_stores_project_path() {
        let p = Pane(projectPath: "/tmp/foo", projectID: UUID())
        #expect(p.projectPath == "/tmp/foo")
    }

    @Test
    func destroySurfaces_is_safe_without_a_view() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(SurfaceRegistry.shared.view(of: p) == nil)
        SurfaceRegistry.shared.destroySurfaces(of: p) // must not crash
        SurfaceRegistry.shared.destroySurfaces(of: p) // idempotent
        #expect(SurfaceRegistry.shared.view(of: p) == nil)
    }

    // MARK: - zmx session naming

    @Test
    func session_name_slugs_from_project_path_basename() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let p = Pane(projectPath: "/Users/me/dev/Macterm", projectID: UUID(), id: id)
        #expect(p.sessionName == "macterm-macterm-aaaaaaaabbbb")
        #expect(p.sessionSlug == "Macterm")
    }

    @Test
    func explicit_session_slug_wins_over_path_basename() {
        let p = Pane(projectPath: NSHomeDirectory(), projectID: UUID(), sessionSlug: ZmxSessionName.quickTerminalSlug)
        #expect(p.sessionName.hasPrefix("macterm-quick-"))
    }

    @Test
    func split_inherits_the_source_panes_session_slug() throws {
        let source = Pane(projectPath: "/tmp", projectID: UUID(), sessionSlug: "myproj")
        let root = SplitNode.pane(source)
        let (newRoot, newID) = root.splitting(
            paneID: source.id, direction: .horizontal, position: .second,
            projectPath: "/somewhere/else", projectID: source.projectID
        )
        let createdID = try #require(newID)
        let newPane = try #require(newRoot.findPane(id: createdID))
        #expect(newPane.sessionSlug == "myproj")
        #expect(newPane.sessionName.hasPrefix("macterm-myproj-"))
        #expect(newPane.sessionName != source.sessionName)
    }

    // MARK: - Agent icon

    @Test
    func pane_matches_an_agent_by_its_invoked_name_and_clears_it_at_the_shell() {
        let pane = Pane(projectPath: "/", projectID: UUID())
        pane.applyForeground(SessionForeground(comm: "2.1.207", isIdle: false, command: "claude"))
        #expect(pane.agentIcon == .claude)
        pane.applyForeground(SessionForeground(comm: "zsh", isIdle: true, isShell: true, command: "zsh"))
        #expect(pane.agentIcon == nil)
    }

    @Test
    func pane_has_no_agent_while_the_shell_is_idle() {
        let pane = Pane(projectPath: "/", projectID: UUID())
        pane.applyForeground(SessionForeground(comm: "zsh", isIdle: true, isShell: true, command: "claude"))
        #expect(pane.agentIcon == nil)
    }

    @Test
    func remote_pane_matches_an_agent_from_the_report() {
        let pane = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        pane.applyForeground(SessionForeground(comm: "/opt/homebrew/bin/codex", command: "codex --yolo"))
        #expect(pane.agentIcon == .codex)
    }

    @Test
    func remote_pane_matches_a_version_named_agent_by_its_command_line() {
        // Claude Code's native install: macOS `ps -o comm=` gives the versioned
        // binary's path, and only args names the CLI.
        let pane = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        pane.applyForeground(SessionForeground(
            comm: "/Users/me/.local/share/claude/versions/2.1.207",
            isIdle: false,
            command: "claude --resume"
        ))
        #expect(pane.agentIcon == .claude)
    }

    @Test
    func remote_pane_matches_an_interpreter_run_agent_by_its_script() {
        let pane = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        pane.applyForeground(SessionForeground(
            comm: "node",
            isIdle: false,
            command: "node /usr/local/lib/node_modules/@google/gemini-cli/bin/gemini"
        ))
        #expect(pane.agentIcon == .gemini)
    }

    @Test
    func remote_pane_loses_its_agent_when_the_shell_returns() {
        let pane = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        pane.applyForeground(SessionForeground(comm: "2.1.207", isIdle: false, command: "claude"))
        #expect(pane.agentIcon == .claude)
        pane.applyForeground(SessionForeground(comm: "-zsh", isIdle: true, command: "-zsh"))
        #expect(pane.agentIcon == nil)
    }

    @Test
    func remote_pane_keeps_its_agent_through_an_empty_report() {
        // nil (an empty report) changes nothing, as
        // for the name and the command.
        let pane = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        pane.applyForeground(SessionForeground(comm: "2.1.207", isIdle: false, command: "claude"))
        pane.applyForeground(nil)
        #expect(pane.agentIcon == .claude)
    }

    @Test
    func remote_pane_shows_no_agent_for_an_ordinary_program() {
        let pane = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        pane.applyForeground(SessionForeground(comm: "btop", isIdle: false, command: "btop --utf-force"))
        #expect(pane.agentIcon == nil)
    }

    // MARK: - Close confirmation (needsConfirmClose)

    @Test
    func needsConfirmClose_is_false_without_a_surface() {
        // No live NSView → nothing this session spawned can be running,
        // local or remote. (Remote leftovers from earlier state must not
        // stage a dialog for a pane that never came on screen.)
        let local = Pane(projectPath: "/", projectID: UUID())
        #expect(!local.needsConfirmClose)
        let remote = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        remote.executionState = .running
        remote.applyForegroundName("hx")
        #expect(!remote.needsConfirmClose)
    }

    @Test
    func remoteCloseVerdict_running_execution_state_is_busy() {
        // A command mid-output (OSC 133 / activity heartbeats) is busy even
        // before any report lands.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.executionState = .running
        #expect(p.remoteNeedsConfirmClose == true)
    }

    @Test
    func remoteCloseVerdict_shell_at_prompt_is_idle() {
        // A report of the session's shell means an idle prompt — the
        // exact case that must NOT warn (an idle local pane doesn't). `-zsh`
        // is the login form the host actually reports.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyForegroundName("-zsh")
        #expect(p.remoteNeedsConfirmClose == false)
        #expect(!p.needsConfirmClose)
    }

    @Test
    func remoteCloseVerdict_program_foreground_is_busy() {
        // A reported program is busy even when the execution tracker has
        // quiet-settled (a silent editor produces no heartbeats).
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyForegroundName("hx")
        #expect(p.executionState != .running)
        #expect(p.remoteNeedsConfirmClose == true)
    }

    @Test
    func host_idle_verdict_beats_the_local_shell_database() {
        // A remote-only login shell the local /etc/shells doesn't list: the
        // host says its group owns the tty, so an idle prompt must not warn.
        let remote = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        remote.applyForeground(
            SessionForeground(comm: "-exotic-shell", isIdle: true, command: nil)
        )
        #expect(remote.foregroundProcessName == "exotic-shell")
        #expect(remote.remoteNeedsConfirmClose == false)

        // The inverse: a NESTED shell running inside the session shell reads
        // as a shell name locally, but the host sees a different foreground
        // group — closing kills it, so it warns (matching libghostty's
        // local surface semantics, where a nested shell is a running child).
        remote.applyForeground(
            SessionForeground(comm: "zsh", isIdle: false, command: nil)
        )
        #expect(remote.remoteNeedsConfirmClose == true)

        // No host verdict (pgid read failure): fall back to
        // the local database heuristic.
        remote.applyForeground(
            SessionForeground(comm: "zsh", isIdle: nil, command: nil)
        )
        #expect(remote.remoteNeedsConfirmClose == false)
    }

    @Test
    func remoteCloseVerdict_is_nil_before_any_report() {
        // No report has ever landed (a host with no server, or before the
        // first report) → no verdict; `needsConfirmClose` falls back to the
        // conservative surface reading.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        #expect(p.remoteNeedsConfirmClose == nil)
    }

    // MARK: - Remote foreground command (layout `run:` capture)

    @Test
    func remoteForegroundCommand_records_a_running_programs_full_command_line() {
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyForeground(SessionForeground(comm: "btop", command: "btop --utf-force"))
        #expect(p.remoteForegroundCommand == "btop --utf-force")
    }

    @Test
    func remoteForegroundCommand_is_nil_while_idle_at_the_remote_prompt() {
        // A shell in the foreground is an idle prompt — the same "idle saves
        // no run" contract local panes get. `-zsh` is the login form the
        // host actually reports; its args carry the same dash.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyForeground(SessionForeground(comm: "btop", command: "btop"))
        p.applyForeground(SessionForeground(comm: "-zsh", command: "-zsh"))
        #expect(p.remoteForegroundCommand == nil)
    }

    @Test
    func remoteForegroundCommand_falls_back_to_the_comm_basename_without_args() {
        // A report with no args field (a ps that reported
        // nothing) still yields a usable `run:` — the short name.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyForeground(SessionForeground(comm: "/usr/local/bin/hx", command: nil))
        #expect(p.remoteForegroundCommand == "hx")
    }

    @Test
    func remoteForegroundCommand_survives_an_empty_report() {
        // nil (an empty report) keeps the last-known
        // command, mirroring the name-freeze contract.
        let p = Pane(projectPath: "me@host.example:proj", projectID: UUID())
        p.applyForeground(SessionForeground(comm: "btop", command: "btop --utf-force"))
        p.applyForeground(nil)
        #expect(p.remoteForegroundCommand == "btop --utf-force")
    }

    /// A plain ssh shell runs in one surface. Every other surface shows the
    /// notice, and no surface does while no plain shell runs.
    @Test
    func only_the_surfaces_that_do_not_run_a_plain_shell_show_the_notice() {
        let p = Pane(projectPath: "/tmp", projectID: UUID())
        let running = UUID()
        let other = UUID()
        #expect(!p.plainShellRunsElsewhere(than: running))
        #expect(!p.plainShellRunsElsewhere(than: other))

        p.plainShellSurfaceID = running
        #expect(!p.plainShellRunsElsewhere(than: running))
        #expect(p.plainShellRunsElsewhere(than: other))

        // The window that ran it closed: the shell runs in the other.
        p.plainShellSurfaceID = other
        #expect(p.plainShellRunsElsewhere(than: running))
        #expect(!p.plainShellRunsElsewhere(than: other))

        // The link ended the shell (lost or exited): no notice.
        p.receiveLinkEvent(.plainShellRunsIn(nil))
        #expect(!p.plainShellRunsElsewhere(than: running))
        #expect(!p.plainShellRunsElsewhere(than: other))
    }
}
