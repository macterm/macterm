import Foundation
@testable import Macterm
import Testing

/// Tests for the pane's title model: the OSC-title provenance gate
/// (`receiveReportedTitle`) and its expiry, both judged against the session's
/// foreground reports (`applyForeground`), the same for local and remote
/// panes.
@MainActor
struct PaneTitleTests {
    private func makePane() -> Pane {
        Pane(projectPath: "/", projectID: UUID())
    }

    private let hx = SessionForeground(comm: "/opt/homebrew/bin/hx", isIdle: false, isShell: false, command: "hx")
    private let nu = SessionForeground(comm: "/opt/homebrew/bin/nu", isIdle: true, isShell: true, command: "nu")

    // MARK: - receiveReportedTitle (provenance gate)

    @Test
    func title_from_program_is_adopted() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("✳ Fix tab switcher")
        #expect(pane.programTitle == "✳ Fix tab switcher")
    }

    @Test
    func title_from_shell_prompt_is_ignored() {
        let pane = makePane()
        pane.applyForeground(nu)
        pane.receiveReportedTitle("~/dev/macterm")
        #expect(pane.programTitle == nil)
    }

    @Test
    func blank_title_is_ignored() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("   ")
        #expect(pane.programTitle == nil)
    }

    @Test
    func title_is_trimmed() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("  hello \n")
        #expect(pane.programTitle == "hello")
    }

    @Test
    func same_program_can_update_its_title() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("first")
        pane.receiveReportedTitle("second")
        #expect(pane.programTitle == "second")
    }

    @Test
    func bare_version_title_is_ignored() {
        // Claude Code sets its version as the title at its prompt; it must not
        // pin the tab to `2.1.202`.
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("2.1.202")
        #expect(pane.programTitle == nil)
        pane.receiveReportedTitle("✳ Claude Code")
        #expect(pane.programTitle == "✳ Claude Code")
    }

    @Test
    func looksLikeVersionString_matches_only_bare_dotted_numbers() {
        #expect(ProcessInspector.looksLikeVersionString("2.1.202"))
        #expect(ProcessInspector.looksLikeVersionString("1.0"))
        #expect(ProcessInspector.looksLikeVersionString("10.20.30.40"))
        // Not versions: no dot, non-numeric, or version embedded in a name.
        #expect(!ProcessInspector.looksLikeVersionString("claude"))
        #expect(!ProcessInspector.looksLikeVersionString("node"))
        #expect(!ProcessInspector.looksLikeVersionString("v2.1.202"))
        #expect(!ProcessInspector.looksLikeVersionString("2.1.202-beta"))
        #expect(!ProcessInspector.looksLikeVersionString("2"))
        #expect(!ProcessInspector.looksLikeVersionString("."))
        #expect(!ProcessInspector.looksLikeVersionString(""))
    }

    // MARK: - Expiry

    @Test
    func title_survives_while_its_program_holds_the_foreground() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("session")
        pane.applyForeground(hx)
        #expect(pane.programTitle == "session")
    }

    @Test
    func title_expires_when_foreground_returns_to_shell() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("session")
        pane.applyForeground(nu)
        #expect(pane.programTitle == nil)
        #expect(pane.displayTitle == "nu")
    }

    @Test
    func title_expires_when_a_different_program_takes_over() {
        // claude exits and btop takes the pty: claude's title must not be
        // put on btop.
        let pane = makePane()
        pane.applyForeground(SessionForeground(comm: "2.1.289", isIdle: false, isShell: false, command: "claude"))
        pane.receiveReportedTitle("session")
        pane.applyForeground(SessionForeground(comm: "btop", isIdle: false, isShell: false, command: "btop"))
        #expect(pane.programTitle == nil)
        #expect(pane.displayTitle == "btop")
    }

    @Test
    func title_expires_when_surface_is_gone() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("session")
        pane.surfacesWillTearDown(hadView: true)
        #expect(pane.foregroundSample == nil)
        #expect(pane.programTitle == nil)
        // No report: a title outside a run names nothing.
        pane.receiveReportedTitle("later")
        #expect(pane.programTitle == nil)
    }

    @Test
    func prompt_mark_clears_a_local_title() {
        let pane = makePane()
        pane.applyForeground(hx)
        pane.receiveReportedTitle("session")
        pane.notePromptReturned()
        #expect(pane.programTitle == nil)
    }

    // MARK: - Prompt hooks

    private func shell(_ name: String) -> SessionForeground {
        SessionForeground(comm: name, isIdle: true, isShell: true, command: name)
    }

    private func program(_ name: String) -> SessionForeground {
        SessionForeground(comm: name, isIdle: false, isShell: false, command: name)
    }

    /// A hook-heavy shell starts `starship`, `mise` or `zoxide` at each
    /// prompt. nushell gives each one a process group of its own, so the
    /// session reports it in front for a moment. It must never name the tab.
    @Test
    func promptHookNeverBecomesTheTabName() {
        let pane = makePane()
        pane.applyForeground(shell("nu"))
        // The shell reports its command finished, so it is now at a prompt.
        pane.notePromptReturned()

        pane.applyForeground(program("starship"))
        #expect(pane.foregroundProcessName == "nu")
        #expect(pane.displayTitle == "nu")
        #expect(pane.agentIcon == nil)

        pane.applyForeground(program("mise"))
        #expect(pane.foregroundProcessName == "nu")

        // The shell itself is always let through.
        pane.applyForeground(shell("nu"))
        #expect(pane.foregroundProcessName == "nu")
    }

    /// A submitted command means the shell is no longer at a prompt, so its
    /// name lands on the first report.
    @Test
    func submittedCommandIsNamedImmediately() {
        let pane = makePane()
        pane.applyForeground(shell("nu"))
        pane.notePromptReturned()

        pane.recordCommandSubmission(hasContent: true)
        pane.applyForeground(program("hx"))
        #expect(pane.foregroundProcessName == "hx")
    }

    /// A shell with no OSC 133 marks never reports a prompt, so the gate
    /// never arms.
    @Test
    func withoutShellIntegration_namingIsUnchanged() {
        let pane = makePane()
        pane.applyForeground(program("npm"))
        #expect(pane.foregroundProcessName == "npm")
        pane.applyForeground(program("node"))
        #expect(pane.foregroundProcessName == "node")
    }

    // MARK: - Session messages

    @Test
    func the_state_message_seeds_the_shell_of_a_local_pane() {
        let pane = makePane()
        pane.receiveSessionState(MactermProtocol.State(
            pid: 10, shellPid: 11, pty: ProtocolBin(Data("/dev/ttys004".utf8)), cols: 80, rows: 24
        ))
        #expect(pane.sessionShell == SessionShell(pid: 11, ttyPath: "/dev/ttys004"))
        pane.surfacesWillTearDown(hadView: true)
        #expect(pane.sessionShell == nil)
    }

    @Test
    func the_state_message_of_a_remote_session_is_not_kept() {
        let pane = makeRemotePane()
        pane.receiveSessionState(MactermProtocol.State(
            pid: 10, shellPid: 11, pty: ProtocolBin(Data("/dev/pts/3".utf8)), cols: 80, rows: 24
        ))
        #expect(pane.sessionShell == nil)
    }

    @Test
    func an_osc7_url_gives_its_path() {
        func path(_ url: String) -> String? {
            SurfaceChannelHost.path(ofCwdURL: Data(url.utf8))
        }
        #expect(path("file://mac.local/Users/me/dev%20x") == "/Users/me/dev x")
        // Ghostty's shell integration sends the raw path.
        #expect(path("kitty-shell-cwd://mac.local/tmp/issue#42?a%b") == "/tmp/issue#42?a%b")
        #expect(path("file:///tmp") == "/tmp")
        #expect(path("file://host") == nil)
        #expect(path("/tmp") == nil)
    }

    // MARK: - Remote panes (#104): execution-gated titles, names from the host's reports

    private func makeRemotePane() -> Pane {
        Pane(projectPath: "devbox:~/dev/api", projectID: UUID())
    }

    private let claude = SessionForeground(comm: "2.1.289", isIdle: false, command: "claude")
    private let zsh = SessionForeground(comm: "-zsh", isIdle: true, isShell: true, command: "-zsh")

    @Test
    func the_current_title_before_the_first_report_is_dropped() {
        // A new channel gets the session's current title at `hello`, before
        // the attach that asks for the foreground. It may be a prompt's title
        // from before the program in front started, so it names nothing.
        let pane = makeRemotePane()
        pane.receiveReportedTitle("dev@box: ~/work")
        #expect(pane.programTitle == nil)
        pane.applyForeground(SessionForeground(comm: "top", isIdle: false, isShell: false, command: "top"))
        #expect(pane.displayTitle == "top")
        // A title after the report is new output, and counts.
        pane.receiveReportedTitle("top - load")
        #expect(pane.programTitle == "top - load")
    }

    /// A Claude Code turn: typed, running with a progress title, ended.
    private func runTurn(_ pane: Pane, title: String = "◐ Terminal session icons") {
        pane.recordUserInteraction()
        pane.markCommandRunning()
        pane.receiveReportedTitle(title)
        pane.markProgressFinished()
    }

    @Test
    func remote_title_is_adopted_only_while_executing() {
        let pane = makeRemotePane()
        // At the prompt with no report: nothing says a program holds the pty.
        pane.receiveReportedTitle("~/dev/api")
        #expect(pane.programTitle == nil)

        // The tracker gates running on a user interaction (typing the
        // command), same as the real flow.
        pane.recordUserInteraction()
        pane.markCommandRunning()
        pane.receiveReportedTitle("✳ remote session")
        #expect(pane.programTitle == "✳ remote session")
    }

    @Test
    func remote_title_expires_when_the_run_ends_at_the_shell() {
        // The shell's report lands before the prompt that ends the run.
        let pane = makeRemotePane()
        pane.applyForeground(claude)
        pane.recordUserInteraction()
        pane.markCommandRunning()
        pane.receiveReportedTitle("✳ remote session")
        pane.applyForeground(zsh)
        pane.markCommandFinished()
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_title_outlives_a_turn_while_the_agent_holds_the_pty() {
        // No flicker to the process name between turns.
        let pane = makeRemotePane()
        pane.applyForeground(claude)
        runTurn(pane)
        #expect(pane.programTitle == "◐ Terminal session icons")
        pane.receiveReportedTitle("✳ Terminal session icons")
        #expect(pane.programTitle == "✳ Terminal session icons")
    }

    @Test
    func remote_title_without_a_report_is_kept_only_for_its_run() {
        // A host with no server (a plain shell) reports nothing: a title is
        // shown while its run lasts, and nothing else is.
        let pane = makeRemotePane()
        runTurn(pane)
        #expect(pane.programTitle == nil)
        pane.receiveReportedTitle("✳ Terminal session icons")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_prompt_title_is_dropped_while_the_shell_holds_the_pty() {
        let pane = makeRemotePane()
        pane.applyForeground(zsh)
        pane.receiveReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_report_of_the_shell_clears_an_idle_title() {
        // The agent quits between turns, so no run ends: the report alone
        // settles it.
        let pane = makeRemotePane()
        pane.applyForeground(claude)
        pane.receiveReportedTitle("✳ Terminal session icons")
        #expect(pane.programTitle == "✳ Terminal session icons")
        pane.applyForeground(zsh)
        #expect(pane.programTitle == nil)
        pane.receiveReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_prompt_return_clears_the_title_at_once() {
        // OSC 133;D is the host's shell owning its prompt.
        let pane = makeRemotePane()
        pane.applyForeground(claude)
        runTurn(pane)
        pane.notePromptReturned()
        #expect(pane.programTitle == nil)
        // A title after it is the prompt's.
        pane.receiveReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_prompt_return_after_the_title_drops_it() {
        // A title hook that runs before ghostty's precmd titles first, then
        // OSC 133;D lands.
        let pane = makeRemotePane()
        pane.applyForeground(claude)
        pane.receiveReportedTitle("~/dev")
        pane.notePromptReturned()
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_title_from_a_nested_shell_is_discarded() {
        // The host says the session's shell doesn't own the tty, but what
        // does is another shell: its prompt titles are churn.
        let pane = makeRemotePane()
        pane.applyForeground(SessionForeground(comm: "zsh", isIdle: false, command: "zsh"))
        pane.receiveReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_multiplexer_is_a_program() {
        // The host never calls tmux a shell (Debian lists it in /etc/shells),
        // so its titles and its `run:` are a program's.
        let pane = makeRemotePane()
        pane.applyForeground(SessionForeground(comm: "tmux", isIdle: false, isShell: false, command: "tmux attach"))
        pane.receiveReportedTitle("build: make")
        #expect(pane.programTitle == "build: make")
        #expect(pane.remoteForegroundCommand == "tmux attach")
    }

    @Test
    func remote_title_from_a_shell_only_the_host_knows_is_discarded() {
        // `elvish` is in the host's /etc/shells and not the Mac's: the host's
        // verdict decides.
        let pane = makeRemotePane()
        pane.applyForeground(SessionForeground(comm: "elvish", isIdle: false, isShell: true, command: "elvish"))
        pane.receiveReportedTitle("~/dev")
        #expect(pane.programTitle == nil)
    }

    @Test
    func remote_pane_idle_title_is_the_host() {
        let pane = makeRemotePane()
        #expect(pane.displayTitle == "devbox")
    }

    @Test
    func remote_foreground_name_comes_from_the_report_and_keeps_basename() {
        let pane = makeRemotePane()
        // A macOS remote reports comm as a full path; keep the basename.
        pane.applyForegroundName("/usr/local/bin/btop")
        #expect(pane.displayTitle == "btop")
        // No name (nil) keeps the last-known name — no title flapping.
        pane.applyForegroundName(nil)
        #expect(pane.displayTitle == "btop")
    }

    @Test
    func remote_login_shell_dash_is_stripped() {
        // A login shell's argv[0] carries a leading '-' (`-/opt/homebrew/bin/nu`,
        // `-zsh`) — kernel comm never does, so it must be stripped only here.
        #expect(Pane.normalizeRemoteComm("-/opt/homebrew/bin/nu") == "nu")
        #expect(Pane.normalizeRemoteComm("-zsh") == "zsh")
        #expect(Pane.normalizeRemoteComm("/usr/bin/hx") == "hx")
        #expect(Pane.normalizeRemoteComm("btop") == "btop")

        let pane = makeRemotePane()
        pane.applyForegroundName("-/opt/homebrew/bin/nu")
        #expect(pane.displayTitle == "nu")
    }

    @Test
    func remote_version_named_program_takes_its_invoked_name() {
        // Claude Code's native install sets its comm to its version; locally
        // the executable names it, remotely the command line does.
        #expect(Pane.remoteProcessName(comm: "/x/versions/2.1.207", command: "claude --resume") == "claude")
        #expect(Pane.remoteProcessName(comm: "2.1.207", command: "/Users/me/.local/bin/claude") == "claude")
        #expect(Pane.remoteProcessName(comm: "2.1.207", command: nil) == "2.1.207")
        #expect(Pane.remoteProcessName(comm: "-zsh", command: "-zsh") == "zsh")

        let pane = makeRemotePane()
        pane.applyForeground(claude)
        #expect(pane.displayTitle == "claude")
    }

    @Test
    func local_pane_is_not_remote() {
        let pane = makePane()
        #expect(!pane.isRemote)
        #expect(pane.remoteHost == nil)
    }

    // MARK: - displayTitle

    @Test
    func displayTitle_falls_back_to_process_name_without_a_program_title() {
        let pane = makePane()
        pane.applyForeground(hx)
        #expect(pane.displayTitle == "hx")
    }

    @Test
    func tab_autoTitle_uses_program_title_for_its_segment() {
        let pane = makePane()
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        pane.applyForeground(hx)
        pane.receiveReportedTitle("✳ session")
        #expect(tab.autoTitle == "✳ session")
    }
}
