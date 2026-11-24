import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "Pane")

/// A pane is the leaf of the split tree — one terminal surface.
@MainActor @Observable
final class Pane: Identifiable {
    /// The pane's id. It is also its session id, and a restore keeps it.
    let id: UUID
    let projectPath: String
    /// The workspace this pane currently belongs to — the ROUTING identity used
    /// to locate the pane's tab (notification-click navigation bakes this into
    /// `userInfo`; the quit sweep groups panes by it). Restampable because a tab
    /// can be moved between projects (`AppState.moveTab`); `rebind(projectID:)`
    /// updates it. Distinct from SESSION identity (`sessionName`/`sessionSlug`/
    /// `projectPath`/`remoteSpec`), which stays tied to where the session was
    /// created and must NOT change on a move — the shell keeps running on its
    /// original host under its original name.
    private(set) var projectID: UUID
    /// The pane's zmx session name (`macterm-<slug>-<hex>`), fixed at creation
    /// and — once persistence lands — stored verbatim in the snapshot, never
    /// re-derived: the slug embeds the project *at creation*, and a later
    /// project rename must not orphan the session. The slug comes from the
    /// project path's basename (which is the project's name for every project
    /// added from a folder); callers with a better label (quick terminal)
    /// pass `sessionSlug` explicitly, and splits inherit the source pane's.
    let sessionName: String
    /// The raw slug this pane's session was named under, so a split-off
    /// sibling groups under the same project in `zmx ls`.
    let sessionSlug: String
    /// Whether this pane's project is remote (#104) — its `projectPath` is an
    /// scp-style spec and its session lives on the remote host. Cached at
    /// init.
    let isRemote: Bool
    /// The remote host name for display fallback (`processTitle` shows it
    /// while no remote process name is known). nil for local panes.
    let remoteHost: String?
    /// The parsed scp-style spec for a remote pane (`.remote(user,host,dir)`),
    /// or nil for a local pane. Cached at init so the spawn (`ensureNSView`)
    /// and teardown (`killPersistentSession`) paths don't re-parse
    /// `projectPath` — they read this instead.
    @ObservationIgnored
    let remoteSpec: ProjectPath?
    /// For a remote pane, the host folder of its session, once its session
    /// attached on the host's server (0057, `RemoteHost.sessionAttached`):
    /// the folder of its creation, then the shell's own (OSC 7) at each
    /// save. nil: the pane never had a v2 session there (a new pane, or one
    /// from before v2), so a missing session is made. When it is set and
    /// the session is gone, the pane closes. It is persisted
    /// (`PaneSnapshot.hostSessionDirectory`).
    @ObservationIgnored
    var hostSessionDirectory: String?
    /// The host of a remote pane (`RemoteHosts.host(of:)`), set when its
    /// first view asks. The pane reads its link state from it. A host lives
    /// for the run of the app.
    var linkHost: RemoteHost?

    /// A remote pane whose connection stopped or failed (its host's session
    /// table, 0264): the app tries again by itself, and a key connects at
    /// once. Its frozen screen is not dimmed: its cursor is faint and does
    /// not blink (`GhosttyTerminalNSView.isCursorDisabled`), and its badge row
    /// says `Connection Lost` (`TerminalPane`), so that it does not look
    /// live. Never persisted.
    var isRemoteLinkLost: Bool {
        linkHost?.isLost(sessionName) ?? false
    }

    /// A try runs now for a lost pane, or a slow first connect runs for a
    /// pane that came back after a restart (`RemoteHost.firstConnectIsSlow`):
    /// its badge says `Reconnecting`. Never persisted.
    var isRemoteReconnecting: Bool {
        linkHost?.isReconnecting(sessionName) ?? false
    }

    /// The badge of a remote pane whose connection is lost or slow, or nil.
    enum RemoteLinkBadge: Equatable {
        /// A try, or a slow first connect, runs now.
        case reconnecting
        /// No try runs now.
        case lost
    }

    var remoteLinkBadge: RemoteLinkBadge? {
        if isRemoteReconnecting { return .reconnecting }
        return isRemoteLinkLost ? .lost : nil
    }

    /// The command the pane runs when its shell starts (`PaneStartCommand`).
    /// nil for a plain shell.
    let start: PaneStartCommand?
    /// Shell binary to launch as the pane's program. nil → resolved from the
    /// ghostty config / login shell at surface-creation time.
    let shell: String?
    /// Extra environment variables for the spawned shell. nil/empty → none.
    let env: [String: String]?
    /// The latest foreground that the pane's session reported, and when it
    /// came (`ForegroundSample`): the same input for local and remote panes
    /// (`applyForeground`). nil before the first report, and while no
    /// channel is up: a state the busy-close policy treats conservatively.
    /// Republished only when the report changes.
    private(set) var foregroundSample: ForegroundSample?

    /// The basename of the pane's live foreground process — a running command
    /// (`hx`, `btop`), or the pane's shell when idle at a prompt (so a nested
    /// `zsh` launched inside `nu` shows `zsh`). This is the tab name's
    /// default source. Reads through `foregroundSample`; the setter is a
    /// seam for tests. Reports go through `applyForeground`.
    var foregroundProcessName: String? {
        get { foregroundSample?.name }
        set {
            guard let newValue else {
                foregroundSample = nil
                return
            }
            foregroundSample = ForegroundSample(
                name: newValue,
                isIdleShell: ProcessInspector.isShellProcessName(newValue),
                sampledAt: Date()
            )
        }
    }

    /// A title that a foreground *program* set with OSC 0/2 (claude's session
    /// summary, ssh's `user@host`). When present it wins over
    /// `foregroundProcessName` in `displayTitle`. The escape sequence has no
    /// provenance: a shell that titles from its prompt (nushell, Starship)
    /// looks the same as a program that names its session. So
    /// `receiveReportedTitle` judges it against the session's foreground
    /// report, which comes in order with the output.
    private(set) var programTitle: String?

    /// The AI coding agent in this pane's foreground (claude, codex, …), for
    /// the sidebar's agent logo. Matched again only when the report changes
    /// (`applyForeground`).
    private(set) var agentIcon: AgentIcon?

    /// The session's attention flags (design/004 §6). `unseen`: a run ended
    /// and no client showed the pane since. `failed`: that run failed.
    /// `bell`: the bell rang. The session keeps them, also while the app is
    /// quit. It sends them on the pane's channel (`receiveAttention`). The
    /// dots and the Dock badge read them. Each change posts
    /// `.paneAttentionDidChange`.
    private(set) var attention = MactermProtocol.Attention() {
        didSet {
            guard attention != oldValue else { return }
            NotificationCenter.default.post(name: .paneAttentionDidChange, object: id)
        }
    }

    func receiveAttention(_ flags: MactermProtocol.Attention) {
        guard flags != attention else { return }
        let text = "unseen=\(flags.unseen) failed=\(flags.failed) bell=\(flags.bell)"
        logger.info("pane \(self.id, privacy: .public) attention: \(text, privacy: .public)")
        attention = flags
    }

    /// The user looked at the pane. The flags clear here at once, and the
    /// session clears its own (`sendSeenToSession`). A `.done` run state
    /// goes back to `.idle`, because it is the `unseen` flag.
    func markSeen() {
        guard attention != MactermProtocol.Attention() else { return }
        logger.info("pane \(self.id, privacy: .public) seen")
        attention = MactermProtocol.Attention()
        sendSeenToSession()
    }

    /// The pane's run state, from its session only (design/004 §2): the
    /// session's status says `running`; else a run ended that no client
    /// showed (`attention.unseen`) is `.done`; else `.idle`. A pane with no
    /// channel (a plain surface, a remote shell with no server) has no
    /// status, so it stays idle.
    var executionState: TerminalExecutionState {
        if isSessionRunning { return .running }
        return attention.unseen ? .done : .idle
    }

    /// Whether the session's `status` message says that a run goes on. The
    /// session ends a run at OSC 133;D, at a new prompt, at the end of a
    /// progress report, and for a program with no marks (`events.zig`). The
    /// pane's link gives it the status of its counting view only
    /// (`PaneLink.counts`). When that view's channel ends,
    /// `PaneSession.channelEnded` sends `idle`: at an attach, the session
    /// sends its status only when it is not idle.
    private var isSessionRunning = false {
        didSet {
            guard isSessionRunning != oldValue else { return }
            // A program's OSC title expires when its command ends (see
            // `receiveReportedTitle`). An agent that finishes a turn ends its
            // run and keeps the foreground, so the title stays while the
            // latest report says a program holds the pty: the shell's own
            // report comes before the prompt that ended the run. A pane with
            // no report keeps no title.
            if !isSessionRunning, programTitle != nil, !programHoldsForeground {
                programTitle = nil
            }
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
    }

    /// The session's `status` message, once for the pane.
    func receiveSessionStatus(_ status: MactermProtocol.Status) {
        isSessionRunning = status.state == .running
    }

    /// When the running command started: the session's `output` mark (OSC
    /// 133;C), for the `CommandEnd` of its `end` mark. nil while no command
    /// runs, and for a command that started before the channel attached.
    @ObservationIgnored
    var commandStartedAt: Date?

    /// The session's shell and pty, from the channel's `state` message
    /// (`receiveSessionState`). Code that needs a local pid reads it:
    /// `ProcessInspector.passwordAsker` and the `run:` capture of a layout.
    /// nil for a remote pane, and while no channel is up.
    @ObservationIgnored
    private(set) var sessionShell: SessionShell?

    /// The pane's link to its session: made at the first surface that runs
    /// from a channel, and kept for the pane's life. It makes the session,
    /// runs a remote pane's driver, and gives the pane the session's
    /// messages and its end once (`receiveLinkEvent`), however many windows
    /// show the pane.
    @ObservationIgnored
    private var link: PaneLink?

    var sessionLink: PaneLink {
        if let link { return link }
        let made = PaneLink.make(for: self)
        made.onEvent = { [weak self] event in self?.receiveLinkEvent(event) }
        link = made
        return made
    }

    /// The pane runs a plain ssh shell (a host with no server).
    var runsPlainShell: Bool {
        link?.runsPlainShell ?? false
    }

    /// `needsConfirmClose` for a pane that runs a plain shell, after its
    /// host answered (0494, `ForegroundPolicy.plainShellNeedsConfirmClose`).
    /// nil when the pane runs none.
    func plainShellNeedsConfirmClose(timeout: Duration) async -> Bool? {
        guard let idle = await link?.plainShellIsIdle(timeout: timeout) else { return nil }
        return ForegroundPolicy.plainShellNeedsConfirmClose(shellIdle: idle, executionState: executionState)
    }

    /// A message of the pane's session, once for the pane.
    func receiveLinkEvent(_ event: PaneLinkEvent) {
        switch event {
        case let .state(state): receiveSessionState(state)
        case let .foreground(foreground): applyForeground(foreground)
        case let .title(title): receiveReportedTitle(title)
        case let .ttyMode(mode): lineMode = mode
        case let .mark(mark, host): receiveSessionMark(mark, view: host?.terminalView)
        case let .status(status): receiveSessionStatus(status)
        case let .attention(flags): receiveAttention(flags)
        case .ended: sessionDidEnd()
        case let .plainShellRunsIn(host): plainShellSurfaceID = host?.surfaceID
        }
    }

    /// The surface that runs the pane's plain ssh shell (a host with no
    /// server), or nil. A pty is one terminal and no session holds it, so
    /// no other window can take it: the pane's other surfaces show a notice
    /// in place of the terminal. When that surface goes, the pane gets a
    /// fresh shell. Live state only; the link sets it (`receiveLinkEvent`).
    var plainShellSurfaceID: UUID?

    /// Whether the surface `surfaceID` shows the notice that the pane's
    /// plain ssh shell runs in another window.
    func plainShellRunsElsewhere(than surfaceID: UUID) -> Bool {
        guard let owner = plainShellSurfaceID else { return false }
        return owner != surfaceID
    }

    /// The channel's `state` message. A remote session's pid is on the
    /// host, so it is not kept.
    func receiveSessionState(_ state: MactermProtocol.State) {
        guard !isRemote, state.shellPid > 0, state.shellPid <= Int64(Int32.max) else { return }
        let tty = String(decoding: state.pty.bytes, as: UTF8.self)
        sessionShell = SessionShell(pid: pid_t(state.shellPid), ttyPath: tty.isEmpty ? nil : tty)
    }

    /// Whether the shell sits at its prompt: the session's last OSC 133 mark
    /// was the end of a command (133;D), with no new command (133;C) since.
    /// A foreground seen then is a prompt hook, not a command. The naming
    /// path, the title gate, project memory and the widget recipe capture
    /// read it. A shell with no marks never sets it.
    @ObservationIgnored
    private(set) var isShellAtPrompt = false

    /// An OSC 133 mark that the session parsed.
    func receiveSessionMark(_ mark: MactermProtocol.Mark) {
        switch mark.kind {
        case .end:
            isShellAtPrompt = true
            // The shell owns the prompt again, so the program's title goes
            // now. Agents don't emit OSC 133; the shell around them does.
            programTitle = nil
        case .output:
            isShellAtPrompt = false
        default:
            break
        }
    }

    func recordUserInteraction() {
        // Typing into or clicking the pane is the user looking at it — the
        // same event ghostty clears its bell on (`keyDown`).
        markSeen()
        // Keystrokes are the strongest "about to launch something" signal —
        // and the only one available while the non-activating quick terminal
        // has keyboard focus without app focus.
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    /// Whether a report must not name the pane: a program in front while the
    /// shell sits at its prompt (OSC 133;D since the last real submission).
    /// A hook-heavy shell starts a real process each time it draws a prompt
    /// (`starship prompt`, `mise hook-env`). nushell gives each one a process
    /// group of its own, so the session reports it in front for a moment.
    /// While the shell sits at a prompt nothing the user launched runs, so a
    /// program in front there is such a hook. A shell is always let through,
    /// so the return to the prompt names the pane at once. A shell with no
    /// OSC 133 marks never arms this.
    private func isPromptHook(isShell: Bool) -> Bool {
        isShellAtPrompt && !isShell
    }

    /// An OSC 0/2 title from the session's `title` message. The session sends
    /// the foreground before the output that follows it, so the title is
    /// judged against the report that holds the pane now.
    /// - A title while the session says a run goes on shows at
    ///   once: the program names itself.
    /// - A title at a prompt that OSC 133;D announced is the shell's: dropped.
    /// - Any other title shows when a program holds the pty (an agent idle
    ///   between turns: Claude Code's `✳ task`), and is dropped when the
    ///   shell does or when no report came. The current title that a new
    ///   channel gets at `hello` comes before its first report, so it is
    ///   dropped.
    ///
    /// It expires at the end of a run (`isSessionRunning`), at OSC
    /// 133;D (`receiveSessionMark`), and at a report of the shell or of
    /// another program (`applyForeground`).
    func receiveReportedTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare version number is not a title: Claude Code sets its version
        // (`2.1.202`) as the title at its prompt.
        guard !ProcessInspector.looksLikeVersionString(trimmed) else { return }
        if executionState != .running {
            guard !isShellAtPrompt, programHoldsForeground else { return }
        }
        if trimmed != programTitle { programTitle = trimmed }
    }

    /// Whether the latest report is a program rather than a shell: the
    /// session's own verdict and the shell name both, so a nested shell's
    /// prompt titles don't count.
    private var programHoldsForeground: Bool {
        guard let sample = foregroundSample, sample.name != nil else { return false }
        return !sample.isIdleShell && !foregroundReportIsShell
    }

    /// The full command line of the remote foreground process, from the host's
    /// report (`ps -o args=` there) — what Save Layout records as the pane's `run:` and the
    /// reconciler matches against, standing in for the local KERN_PROCARGS2
    /// argv (`ProcessInspector.runningCommand`). nil while the remote pane is
    /// idle at its shell prompt or before any report has landed — the same
    /// "idle saves no run" contract local panes get. Not observed: only the
    /// on-demand layout paths read it, and each report applies it again.
    @ObservationIgnored
    private(set) var remoteForegroundCommand: String?

    /// The foreground that the pane's session reports: the tab's name, the
    /// agent logo, the title gate and the tracker's foreground, for local and
    /// remote panes. The session reads the pty's foreground process group
    /// before it forwards each chunk of output, and every 500 ms
    /// (`foreground.zig`). macOS reports `comm` as a full executable path:
    /// the name is its basename. A version-shaped `comm` (Claude Code's
    /// native install sets its own to `2.1.207`) is named by its invoked name
    /// instead. nil keeps the last-known name and command.
    ///
    /// Both verdicts are the session's own, with the local shell database
    /// only as a fallback when the report has none. The idle verdict
    /// (`foreground.isIdle`) is foreground pgid == the process that the
    /// session started, and the shell verdict (`foreground.isShell`) is the
    /// host's `/etc/shells`. On a host the session starts the shell, so a
    /// nested shell is a running child, as libghostty reads it. A local
    /// session starts login(1), which starts the shell in a group of its own,
    /// so a local pane uses the shell verdict for both (issue 0448). A
    /// prompt hook never names the pane (`isPromptHook`). For the run
    /// tracker only, a shell that runs `-c` or a script is a program
    /// (`trackerForeground`): `pane run '/bin/sh -c "…"'` is a run.
    ///
    /// `remoteForegroundCommand` follows the local `runningCommand` contract:
    /// a shell foreground records no command, anything else records the
    /// report's full command line, or the name when the report carried no
    /// args. It is the shell verdict, not the idle one: `runningCommand`
    /// returns nil for any shell argv[0], nested or not.
    func applyForeground(_ foreground: SessionForeground?) {
        guard let foreground, !foreground.comm.isEmpty else { return }
        let name = Self.remoteProcessName(comm: foreground.comm, command: foreground.command)
        guard !name.isEmpty else { return }
        let isShell = foreground.isShell ?? ProcessInspector.isShellProcessName(name)
        // A local session runs the shell under login(1), so the session's own
        // process group is login's, and `isIdle` is false at an idle prompt.
        // A local pane judges by the shell verdict.
        let isIdleShell = isRemote ? (foreground.isIdle ?? isShell) : isShell
        // A prompt hook must not name the tab: see `isPromptHook`.
        guard !isPromptHook(isShell: isShell) else { return }
        foregroundReportIsShell = isShell
        let nameChanged = name != foregroundProcessName
        if nameChanged || isIdleShell != foregroundSample?.isIdleShell {
            foregroundSample = ForegroundSample(name: name, isIdleShell: isIdleShell, sampledAt: Date())
        }
        remoteForegroundCommand = isShell ? nil : (foreground.command ?? name)
        // Another program took the pty: the title was the last one's.
        if nameChanged, programTitle != nil { programTitle = nil }
        // The shell is back in front: whatever program titled the pane has
        // gone, and the run-state edge may never have fired (it ended idle).
        if !programHoldsForeground, executionState != .running, programTitle != nil {
            programTitle = nil
        }
        // The agent logo: `comm` first, then the invoked name from the
        // report's command line. Matched again only when the report changes.
        guard foreground != lastAppliedForeground else { return }
        lastAppliedForeground = foreground
        let icon = isIdleShell ? nil : AgentIcon.match(comm: name) {
            foreground.command.flatMap { command in
                ProcessInspector.remoteInvokedNames(commandLine: command).first {
                    AgentIcon.match(processName: $0) != nil
                }
            }
        }
        if icon != agentIcon { agentIcon = icon }
    }

    /// How the session's pty reads input, from its `tty_mode`. nil until the
    /// first report, and for a pane with no session.
    @ObservationIgnored
    var lineMode: TerminalLineMode?

    /// The latest report's shell verdict on the foreground (see
    /// `applyForeground`).
    @ObservationIgnored
    private(set) var foregroundReportIsShell = false

    /// The latest report, for the password asker.
    var foregroundReport: SessionForeground? { lastAppliedForeground }

    /// The report the agent logo was last matched against.
    @ObservationIgnored
    private var lastAppliedForeground: SessionForeground?

    /// The tab name for a reported foreground: the basename of `comm`
    /// (`normalizeRemoteComm`), or, when that is a bare version, the name the
    /// command line was invoked as. That is its first word: `args` loses
    /// argv's quoting, so an invoked path with a space in it names the tab
    /// after the part before the space. Pure + static for testing.
    static func remoteProcessName(comm: String, command: String?) -> String {
        let base = normalizeRemoteComm(comm)
        guard ProcessInspector.looksLikeVersionString(base),
              let argv0 = command?.split(separator: " ").first
        else { return base }
        let invoked = normalizeRemoteComm(String(argv0))
        return invoked.isEmpty ? base : invoked
    }

    /// Name-only convenience over `applyForeground` (no args, no host
    /// idle verdict — falls back to the local shell database).
    func applyForegroundName(_ comm: String?) {
        guard let comm else { return }
        applyForeground(SessionForeground(comm: comm, isIdle: nil, command: nil))
    }

    /// Basename of a remote `ps -o comm=` value, minus the leading `-` a
    /// login shell carries in its argv[0] (`-/opt/homebrew/bin/nu` → `nu`,
    /// `-zsh` → `zsh`). Local kernel `comm` never has this dash, so the
    /// stripping is remote-only. Pure + static for testing.
    static func normalizeRemoteComm(_ comm: String) -> String {
        let stripped = comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
        return (stripped as NSString).lastPathComponent
    }

    /// Whether this remote pane's connection stopped (#281, 0057): its driver
    /// waits for its host's next try while the session lives on the host.
    /// Read at trigger time by the reconnect sweep. Local
    /// panes are never "disconnected": they have no network to lose.
    var isDisconnected: Bool {
        isRemote && isRemoteLinkLost
    }

    /// The ssh destination of a remote pane (`[user@]host`), the key of its
    /// host's one connection. nil for a local pane.
    nonisolated var remoteDestination: String? {
        guard case let .remote(user, host, _) = remoteSpec else { return nil }
        return HostCommands.destination(user: user, host: host)
    }

    /// The remote-side busy verdict alone (see
    /// `ForegroundPolicy.remoteNeedsConfirmClose`), nil when no report has
    /// ever arrived. Kept as a pane property so tests exercise the
    /// decision without a live NSView.
    var remoteNeedsConfirmClose: Bool? {
        ForegroundPolicy.remoteNeedsConfirmClose(
            sample: foregroundSample,
            executionState: executionState
        )
    }

    /// The model's half of a surface teardown, before
    /// `SurfaceRegistry.destroySurfaces` destroys the views. Safe to call
    /// more than once.
    func surfacesWillTearDown(hadView: Bool) {
        // A pane with no surface shows nothing. The panes of an unloaded
        // pinned tab stay in the tree, and must keep no dot and no badge.
        // Only the copy here clears. Before the guard, so that a pane with
        // no view also clears.
        attention = MactermProtocol.Attention()
        guard hadView else { return }
        lineMode = nil
        // The reports described the channels that go now. The next channel's
        // session reports again; until then nothing is known, so the close
        // falls back to the surface's reading.
        foregroundSample = nil
        programTitle = nil
        remoteForegroundCommand = nil
        foregroundReportIsShell = false
        lastAppliedForeground = nil
        sessionShell = nil
        isSessionRunning = false
        isShellAtPrompt = false
        // A notification whose pane no longer exists routes nowhere on tap, so
        // drop any still sitting in Notification Center. Ghostty does the same
        // when a surface is removed.
        NotificationHandler.shared.clearDelivered(paneID: id)
    }

    var processTitle: String {
        // The live foreground process name (`hx`, `btop`) when a program is
        // running, else the shell name when idle. Always the session's report
        // (never the OSC title): the quit confirmation lists real process
        // names, and `displayTitle` falls back here. Before a remote pane's
        // first report (or when the host has no server) the host name is the
        // fallback: the local login shell never runs in a remote pane.
        if let proc = foregroundProcessName, !proc.isEmpty { return proc }
        if let remoteHost { return remoteHost }
        return Self.defaultShellName
    }

    /// What the tab/sidebar shows for this pane: a program-reported OSC title
    /// when one is live (see `programTitle`), else the process name.
    var displayTitle: String {
        if let title = programTitle, !title.isEmpty { return title }
        return processTitle
    }

    /// Display fallback for a pane with no foreground process yet (its surface
    /// hasn't been created) — the name of the login shell it will run. Resolves
    /// from the password database (`getpwuid`), the same shell libghostty
    /// launches when no explicit `command` is set. We avoid `$SHELL`: that's the
    /// shell of whatever launched the app (often `/bin/zsh`), not the user's
    /// login shell, so a `nu` user would otherwise see "zsh". Once the surface
    /// is live, `foregroundProcessName` (the actual `comm`) takes over.
    private static let defaultShellName: String = {
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }()

    var sidebarSegmentTitle: String {
        displayTitle
    }

    init(
        projectPath: String,
        projectID: UUID,
        id: UUID = UUID(),
        sessionSlug: String? = nil,
        sessionName persistedSessionName: String? = nil,
        start: PaneStartCommand? = nil,
        shell: String? = nil,
        env: [String: String]? = nil
    ) {
        // A project with no folder (`Project.hasFolder`) starts its shells
        // in the folder of the scratch tabs.
        let projectPath = projectPath.isEmpty ? ScratchTabs.fallbackRoot : projectPath
        self.projectPath = projectPath
        self.projectID = projectID
        self.id = id
        if case let .remote(_, host, _)? = ProjectPath.parse(projectPath) {
            isRemote = true
            remoteHost = host
            remoteSpec = ProjectPath.remote(from: projectPath)
        } else {
            isRemote = false
            remoteHost = nil
            remoteSpec = nil
        }
        if let persistedSessionName {
            // Restore path: the snapshot's name is authoritative and used
            // VERBATIM — the slug inside it reflects the project at creation,
            // and re-deriving after a project rename would target a session
            // that doesn't exist. The slug is recovered only so a split off
            // this pane groups with it.
            sessionName = persistedSessionName
            self.sessionSlug = ZmxSessionName.slug(fromName: persistedSessionName)
                ?? (projectPath as NSString).lastPathComponent
        } else {
            let slug = sessionSlug ?? (projectPath as NSString).lastPathComponent
            self.sessionSlug = slug
            sessionName = ZmxSessionName.make(projectName: slug, paneSessionID: id)
        }
        self.start = start
        self.shell = shell
        self.env = env
    }

    /// Re-point this pane at a new workspace after its tab is moved between
    /// projects (`AppState.moveTab`). Updates ONLY the routing identity — the
    /// `projectID` that notification navigation and the quit sweep key on — so a
    /// notification click after a move finds the tab in its new project.
    ///
    /// Session identity (`sessionName`, `sessionSlug`, `projectPath`,
    /// `remoteSpec`) is deliberately NOT touched: the shell
    /// keeps running on its original host under its original name, so a
    /// remote pane moved into a local project still tears down over ssh.
    func rebind(projectID: UUID) {
        self.projectID = projectID
    }

    /// Permanently kill this pane's session. Call ONLY when the pane is
    /// gone for good (closed, tab/project removed, dropped by a layout apply)
    /// — NOT on transient teardown (window hide, tab-switch churn), where the
    /// session must survive. Fire-and-forget: close paths aren't blocked on
    /// it; `serverRequestTimeout` (local) and the host link's request
    /// timeout (remote) bound a stuck peer. The client is
    /// a parameter so AppState's injectable instance flows through in tests.
    func killPersistentSession(using sessionClient: SessionClient) {
        let name = sessionName
        if let remote = remoteSpec {
            Task {
                await sessionClient.killRemoteSession(remote, name)
                // Post AFTER the kill so observers that re-list sessions see
                // the post-kill state instead of racing the still-alive one.
                NotificationCenter.default.post(name: .zmxSessionsChanged, object: nil)
            }
            return
        }
        Task {
            await sessionClient.killSession(name)
            NotificationCenter.default.post(name: .zmxSessionsChanged, object: nil)
        }
    }
}
