import CoreGraphics
import Foundation

/// A pane is the leaf of the split tree — one terminal surface.
@MainActor @Observable
final class Pane: Identifiable {
    let id = UUID()
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
    /// Stable session id for zmx-backed persistence, distinct from `id` (which
    /// is regenerated on every restore). Fresh for a new pane; the restore
    /// path will pass the saved one.
    let sessionID: UUID
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
    /// init: the poll and title paths read it every tick.
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
    /// attached on the host's server (0057, `RemoteHosts.sessionAttached`):
    /// the folder of its creation, then the shell's own (OSC 7) at each
    /// save. nil: the pane never had a v2 session there (a new pane, or one
    /// from before v2), so a missing session is made. When it is set and
    /// the session is gone, the pane closes. It is persisted
    /// (`PaneSnapshot.hostSessionDirectory`).
    @ObservationIgnored
    var hostSessionDirectory: String?
    /// A remote pane whose connection stopped or failed (`RemoteHosts`): the
    /// app tries again by itself, and a key connects at once. Its frozen
    /// screen is not dimmed: its cursor is faint and does not blink
    /// (`GhosttyTerminalNSView.isCursorDisabled`), and its badge row says
    /// `Connection lost` (`TerminalPane`), so that it does not look live.
    /// Never persisted.
    var isRemoteLinkLost = false {
        didSet { if isRemoteLinkLost { remoteLineMode = nil } }
    }

    /// A lost pane for which a try runs now: its badge says `Reconnecting`.
    /// Never persisted.
    var isRemoteReconnecting = false

    /// The badge of a remote pane whose connection is lost, or nil.
    enum RemoteLinkBadge: Equatable {
        /// A try runs now.
        case reconnecting
        /// No try runs now.
        case lost
    }

    var remoteLinkBadge: RemoteLinkBadge? {
        guard isRemoteLinkLost else { return nil }
        return isRemoteReconnecting ? .reconnecting : .lost
    }

    /// Process the pane launches on first surface creation, injected into the
    /// shell as `command + "\n"`. Set from a declarative layout; nil for an
    /// interactively-created pane (plain shell). Recorded here so a layout
    /// `apply` can match a live pane by its declared command even after the
    /// process has exited (see LayoutReconciler).
    let command: String?
    /// Shell binary to launch as the pane's program. nil → resolved from the
    /// ghostty config / login shell at surface-creation time.
    let shell: String?
    /// Extra environment variables for the spawned shell. nil/empty → none.
    let env: [String: String]?
    /// The latest observation of this pane's foreground — name, shell-ness,
    /// provenance, and when it was made (`ForegroundSample`). The single
    /// foreground truth for BOTH worlds: local samples come from the process
    /// table via `refreshForegroundProcess()`, remote ones from the host's
    /// reports via `applyRemoteForeground`. nil = no observation has ever
    /// been made (pre-surface locally; no report yet remotely) — a
    /// state the busy-close policy treats conservatively. Republished only
    /// when the observation changes, so a steady poll doesn't re-render the
    /// sidebar every tick.
    private(set) var foregroundSample: ForegroundSample?

    /// The basename of the pane's live foreground process — a running command
    /// (`hx`, `btop`), or the pane's shell when idle at a prompt (so a nested
    /// `zsh` launched inside `nu` shows `zsh`). This is the tab name's
    /// default source. Reads through `foregroundSample`; the setter is a
    /// seam for tests (and synthesizes a sample with origin matching the
    /// pane's world) — production sampling goes through
    /// `refreshForegroundProcess()` / `applyRemoteForeground`.
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
                origin: isRemote ? .remoteEvent : .processTable(pid: nil),
                sampledAt: Date()
            )
        }
    }

    /// A title a foreground *program* set via OSC 0/2 (claude's session
    /// summary, ssh's `user@host`). When present it wins over
    /// `foregroundProcessName` in `displayTitle`. The escape sequence itself
    /// carries no provenance — a shell that titles from its prompt (nushell,
    /// Starship, ghostty shell-integration — emitting `~/dir`, `host:~/dir`)
    /// is indistinguishable from a program naming its session — so
    /// `receiveReportedTitle` recovers provenance from the process table:
    /// a title is adopted only while the foreground process is NOT a shell,
    /// and it's pinned to that pid — `applyForegroundRefresh` expires it the
    /// moment a different process (usually the shell, on exit) takes the
    /// foreground, so an idle pane falls back to the process name.
    private(set) var programTitle: String?

    /// The foreground pid that set `programTitle`, used to expire it.
    @ObservationIgnored
    private var programTitlePID: pid_t?

    /// The AI coding agent in this pane's foreground (claude, codex, …), for
    /// the sidebar's agent logo. Derived in `applyForegroundRefresh` from the
    /// foreground process's `comm`/argv[0] and cached against the pid, so the
    /// poll's steady ticks don't re-read argv or churn `@Observable`.
    private(set) var agentIcon: AgentIcon?

    /// The foreground pid `agentIcon` was computed for.
    @ObservationIgnored
    private var agentIconPID: pid_t?

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
        attention = flags
    }

    /// The user looked at the pane. The flags clear here at once, and the
    /// session clears its own (`sendSeenToSession`). A `.done` run state
    /// goes back to `.idle`.
    func markSeen() {
        acknowledgeCommandCompletion()
        guard attention != MactermProtocol.Attention() else { return }
        attention = MactermProtocol.Attention()
        sendSeenToSession()
    }

    var executionState: TerminalExecutionState = .idle {
        didSet {
            guard executionState != oldValue else { return }
            // A remote pane's OSC title expires when its command ends — the
            // execution edge is the pid-change analogue local panes get from
            // the poll (see `receiveRemoteReportedTitle`). An agent that
            // finishes a turn ends its run and keeps the foreground, so the
            // title stays while the host's latest report says a program
            // holds the pty: the shell's own report comes before the prompt
            // that ended the run. A pane with no report keeps no title.
            if isRemote, oldValue == .running, programTitle != nil, !remoteProgramHoldsForeground {
                programTitle = nil
            }
            // Transitions (idle→running, running→done) are exactly when the
            // adaptive poll should speed up; steady-state assignments and
            // per-frame heartbeats don't reach here (value unchanged).
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
    }

    /// A snapshot of the remote pane's session starts or ends
    /// (`PaneChannelEvent`). Its replay is not new output.
    func receiveRemoteSnapshot(started: Bool) {
        guard isRemote else { return }
        isReceivingRemoteSnapshot = started
    }

    /// Between the two snapshot marks of a remote pane: the output is the
    /// session's replay, not new output. Its title is the last one that the
    /// session saw, maybe a prompt's from before the program in front
    /// started, so it never names the tab (`receiveReportedTitle`): the
    /// pushed foreground does. Cleared with the surface and when the
    /// connection stops.
    @ObservationIgnored
    private(set) var isReceivingRemoteSnapshot = false

    /// The pane's connection stopped (`RemoteHosts`): a replay that it cut
    /// is over.
    func remoteLinkDidStop() {
        isReceivingRemoteSnapshot = false
    }

    @ObservationIgnored
    private var executionTracker = TerminalExecutionTracker()
    /// The global foreground poll pauses when the app has no visible window.
    /// Keep one lightweight wake scheduled from the final IO heartbeat so an
    /// occluded activity-owned run can still quiet-settle.
    @ObservationIgnored
    private var activityQuietPollWork: DispatchWorkItem?
    private let activityQuietPollDelay: TimeInterval

    /// Rate limit on what a reported title costs (`TitleReportThrottle`):
    /// the first title after a quiet window is evaluated at once, the rest
    /// of the window's titles are held and the newest flushed once at its
    /// end by `titleFlushWork`. Not observed: the title it holds is not yet
    /// the pane's.
    @ObservationIgnored
    private var titleReportThrottle: TitleReportThrottle
    @ObservationIgnored
    private var titleFlushWork: DispatchWorkItem?

    /// Re-read the foreground process name from the process table and publish it
    /// only when it changed (so a steady poll doesn't churn `@Observable` and
    /// re-render the sidebar every tick). Driven by `AppState`'s poll.
    ///
    /// It also feeds the execution tracker, whatever the status indicator
    /// setting is: `pane list` reports the state, and the setting only
    /// chooses what the tab row draws.
    func refreshForegroundProcess() {
        // Remote panes (#104): the local process table only knows the ssh
        // client — reading it would stomp the reported name, expire
        // remote OSC titles, and feed the execution tracker a perpetual
        // "ssh is running". Names come from the host's reports
        // (`applyRemoteForeground`), titles from `receiveRemoteReportedTitle`,
        // execution state from OSC 133 markers and activity heartbeats.
        guard !isRemote else { return }
        // Resolved ONCE and reused below, including inside the argv0 closure —
        // re-resolving there could disagree with this frame's pid on a wrapped
        // pane and would double the resolver work when the fallback fires.
        let resolvedPID = ProcessInspector.resolvedForegroundPID(forPane: self)
        applyForegroundRefresh(
            name: ProcessInspector.runningProcessName(forPane: self),
            // The RESOLVED foreground pid (session-side shell/program for a
            // wrapped pane), NOT the raw `nsView.foregroundPID` (the zmx
            // connect client). `programTitlePID` is pinned to this resolved pid, so the
            // expiry compare in `applyForegroundRefresh` must use the same
            // source — otherwise a wrapped pane's client pid never matches and
            // every adopted OSC title (e.g. Claude Code's "✳ Claude Code")
            // expires on the very next 250ms poll, snapping back to the process
            // name.
            foregroundPID: resolvedPID,
            foregroundIsShell: ProcessInspector.foregroundProcessIsShell(forPane: self),
            terminalInputIsRaw: ProcessInspector.terminalInputIsRaw(forPane: self),
            argv0: { resolvedPID.flatMap(ProcessInspector.invokedNameBasename(pid:)) }
        )
    }

    /// Whether a foreground sample must be ignored for this pane's IDENTITY
    /// (its name and agent icon).
    ///
    /// A hook-heavy shell forks a REAL process every time it draws a prompt —
    /// `starship prompt`, `mise hook-env`, `zoxide` — and each is briefly the
    /// pane's foreground. Publishing one renamed the tab to `starship`, and
    /// because the poll STOPS while the window is occluded and the app is
    /// inactive (`PollCadence.mode` → `.paused`), that wrong name then stuck
    /// until something re-sampled: clicking the app, or any keystroke.
    ///
    /// While the shell sits at a prompt nothing the user launched is running,
    /// so a non-shell foreground there can only be such a hook. A shell name
    /// (and `nil`) is always allowed through, so returning to the prompt
    /// restores the shell name at once. Shell-ness is decided by basename
    /// (`/etc/shells` + login shell + `$SHELL` — a set lookup, no syscall).
    ///
    /// This gates the name and icon only. `programTitle` expiry stays keyed on
    /// the foreground pid, so a title can never be misattributed. A long-lived
    /// program (claude, hx) reports no completion while it runs, so the gate is
    /// never armed underneath it, and a shell with no OSC 133 integration never
    /// arms it at all — those panes keep exactly today's naming behavior.
    private func ignoresForegroundIdentity(_ name: String?) -> Bool {
        guard executionTracker.isShellAtPrompt, let name else { return false }
        return !ProcessInspector.isShellProcessName(name)
    }

    /// Testable core of `refreshForegroundProcess`: publish a changed process
    /// name, and expire `programTitle` when the pid that set it no longer
    /// holds the foreground, then feed the execution tracker.
    func applyForegroundRefresh(
        name: String?,
        foregroundPID: pid_t?,
        foregroundIsShell: Bool = false,
        terminalInputIsRaw: Bool = false,
        argv0: () -> String? = { nil }
    ) {
        // A prompt hook must not rename the tab. Title expiry below is NOT
        // gated: a changed pid means the title's owner lost the foreground, and
        // a title must never be misattributed to a different process.
        if !ignoresForegroundIdentity(name) {
            let nameChanged = name != foregroundProcessName
            if nameChanged {
                foregroundSample = ForegroundSample(
                    name: name,
                    isIdleShell: ProcessInspector.isShellProcessName(name),
                    origin: .processTable(pid: foregroundPID),
                    sampledAt: Date()
                )
            }
            // A steady foreground (same pid, same comm) keeps the cached icon; a
            // change re-matches — argv[0] is only read when comm alone doesn't
            // identify an agent.
            if nameChanged || foregroundPID != agentIconPID {
                agentIconPID = foregroundPID
                let icon = foregroundPID == nil ? nil : AgentIcon.match(comm: name, argv0: argv0)
                if icon != agentIcon { agentIcon = icon }
            }
        }
        if programTitle != nil, programTitlePID != foregroundPID {
            programTitle = nil
            programTitlePID = nil
        }
        applyForegroundExecutionState(
            name: name,
            foregroundPID: foregroundPID,
            foregroundIsShell: foregroundIsShell,
            terminalInputIsRaw: terminalInputIsRaw
        )
    }

    func markCommandRunning() {
        executionState = executionTracker.markProgressStarted(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    func markCommandFinished() {
        executionState = executionTracker.markCommandFinished(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    /// Whether the shell sits at its prompt (OSC 133;D since the last real
    /// submission). A foreground seen then is a prompt hook, not a command —
    /// the rule the tracker's own start gate and the naming path apply; the
    /// widget recipe capture reads it for the same reason.
    var isShellAtPrompt: Bool { executionTracker.isShellAtPrompt }

    /// The shell returned to a prompt (OSC 133;D). The naming path uses it to
    /// reject prompt-hook processes.
    func notePromptReturned() {
        executionTracker.notePromptReturned()
        // On a remote pane, OSC 133;D is the host's shell saying it owns the
        // prompt again, so the program's title goes now. Agents don't emit
        // OSC 133; the shell around them does.
        if isRemote { programTitle = nil }
    }

    /// A progress report ended the pane's run: REMOVE, PAUSE or ERROR. Whether
    /// the run failed is the session's to say (`attention.failed`).
    func markProgressFinished() {
        executionState = executionTracker.markProgressFinished(currentState: executionState)
        cancelActivityQuietPollIfNeeded()
    }

    /// The row-growth activity primitive that `markOutputActivity` delegates
    /// to on a growing heartbeat. Exposed directly so tests can seed an
    /// activity-sourced run at a chosen instant without a growth baseline.
    func markTerminalActivity(at date: Date = Date()) {
        executionState = executionTracker.markTerminalActivity(
            at: date,
            currentState: executionState
        )
    }

    func settleTerminalActivityIfQuiet(
        now: Date = Date(),
        quietInterval: TimeInterval = TerminalActivityTiming.quietInterval
    ) {
        executionState = executionTracker.settleIfQuiet(
            now: now,
            quietInterval: quietInterval,
            currentState: executionState
        )
        cancelActivityQuietPollIfNeeded()
    }

    /// Handle a throttled `OUTPUT_ACTIVITY` heartbeat — the pane's sole source
    /// of terminal activity. It fires from the pty IO path (not the renderer),
    /// so unlike the scrollbar it also reaches occluded/background panes and
    /// its silence is always meaningful. `setup.sh` requires the GhosttyKit
    /// ABI that emits it, so the quiet-settle needs no occluded-pane exemption.
    /// Growth-vs-keepalive is decided in `TerminalExecutionTracker`.
    func markOutputActivity(totalRows: UInt64, now: Date = Date()) {
        executionState = executionTracker.markOutputActivity(totalRows: totalRows, at: now, currentState: executionState)
        scheduleActivityQuietPollIfNeeded()
    }

    private func scheduleActivityQuietPollIfNeeded() {
        guard executionTracker.isActivitySourced else {
            cancelActivityQuietPollIfNeeded()
            return
        }
        // Rescheduled on every heartbeat (~2 Hz per live pane), so this uses a
        // plain work item rather than spawning and cancelling a `Task` each
        // time — the same idiom the view's `commandSubmissionEvidenceReset`
        // uses.
        activityQuietPollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            activityQuietPollWork = nil
            // This dedicated deadline bypasses ordinary event coalescing: if
            // every window is occluded there may be no timer left to retry.
            // AppState still performs the settle, so that the poll's other
            // work stays in one place.
            NotificationCenter.default.post(name: .terminalQuietSettleDeadline, object: self)
        }
        activityQuietPollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + activityQuietPollDelay, execute: work)
    }

    private func cancelActivityQuietPollIfNeeded() {
        guard !executionTracker.isActivitySourced else { return }
        activityQuietPollWork?.cancel()
        activityQuietPollWork = nil
    }

    @discardableResult
    func acknowledgeCommandCompletion() -> Bool {
        guard executionState == .done else { return false }
        executionState = .idle
        return true
    }

    func recordUserInteraction() {
        executionTracker.recordUserInteraction()
        // Typing into or clicking the pane is the user looking at it — the
        // same event ghostty clears its bell on (`keyDown`).
        markSeen()
        // Keystrokes are the strongest "about to launch something" signal —
        // and the only one available while the non-activating quick terminal
        // has keyboard focus without app focus.
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    /// True when a recognized AI agent holds the foreground. Two things key off
    /// it: the two-heartbeat in-place start heuristic (below), and the view's
    /// decision to carry a programmatic payload's content evidence forward —
    /// both are only meaningful in a raw-mode agent TUI, where a bracketed
    /// paste can leave the payload sitting unsubmitted in the editor buffer.
    var allowsInPlaceOutputStart: Bool {
        agentIcon != nil || AgentIcon.match(processName: foregroundProcessName) != nil
    }

    func recordCommandSubmission(hasContent: Bool, at date: Date = Date()) {
        // Plain Return is ambiguous in editors and menus. Only a nonempty
        // submission in a recognized AI agent gets the two-heartbeat in-place
        // start heuristic; ordinary programs still use process/row evidence.
        let allowInPlaceOutputStart = allowsInPlaceOutputStart
        executionTracker.recordCommandSubmission(
            at: date,
            allowInPlaceOutputStart: allowInPlaceOutputStart,
            hasContent: hasContent
        )
        acknowledgeCommandCompletion()
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    private func applyForegroundExecutionState(
        name: String?,
        foregroundPID: pid_t?,
        foregroundIsShell: Bool,
        terminalInputIsRaw: Bool
    ) {
        executionState = executionTracker.refreshForeground(
            name: name,
            pid: foregroundPID,
            foregroundIsShell: foregroundIsShell,
            terminalInputIsRaw: terminalInputIsRaw,
            currentState: executionState
        )
        cancelActivityQuietPollIfNeeded()
    }

    /// Handle an OSC 0/2 title reported by the surface. Refreshes the
    /// foreground process (a title arrival is a command boundary); adopts the
    /// string as `programTitle` only when a real program — not the shell — is
    /// in the foreground (see `programTitle` for why).
    ///
    /// Throttled (`TitleReportThrottle`): the provenance lookup and the
    /// refresh are ~100µs of syscalls, which a zmx session replaying
    /// prompt-heavy scrollback at launch — a title per prompt, 150k of them
    /// measured as 14s of frozen main thread — cannot pay per title. The
    /// first title after a quiet window is handled here and now; the rest of
    /// the window's titles are held, and the newest is handled once at the
    /// window's end (`flushHeldTitle`), gated against the foreground that
    /// holds the pane then — no later than the poll's own next tick would
    /// have looked. `receiveReportedTitle(_:programPID:)` is the unthrottled
    /// core.
    func receiveReportedTitle(_ title: String) {
        // Before the throttle, which can hold a title past the end mark.
        guard !isReceivingRemoteSnapshot else { return }
        switch titleReportThrottle.receive(title, at: Date()) {
        case .evaluate:
            evaluateReportedTitle(title)
        case let .held(flushAfter):
            guard let flushAfter else { return }
            let work = DispatchWorkItem { [weak self] in self?.flushHeldTitle() }
            titleFlushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + flushAfter, execute: work)
        }
    }

    private func flushHeldTitle() {
        titleFlushWork = nil
        guard let title = titleReportThrottle.flush(at: Date()) else { return }
        evaluateReportedTitle(title)
    }

    /// The unthrottled title path: the remote gate, or the local provenance
    /// lookup feeding `receiveReportedTitle(_:programPID:)`.
    private func evaluateReportedTitle(_ title: String) {
        if isRemote {
            receiveRemoteReportedTitle(title)
            return
        }
        receiveReportedTitle(title, programPID: ProcessInspector.foregroundProgramPID(forPane: self))
    }

    /// Drop a title held for a surface that is going away, and the flush
    /// scheduled for it. The throttle forgets its window too, so the next
    /// surface's first title is evaluated at once rather than held with no
    /// flush coming.
    private func cancelHeldTitle() {
        titleFlushWork?.cancel()
        titleFlushWork = nil
        titleReportThrottle.reset()
    }

    /// Remote-pane title path (#104): there is no local foreground pid to
    /// gate provenance on (the local process is always `ssh`), so remote
    /// signals stand in. A title arriving while a command runs (OSC 133 /
    /// activity / progress) is the program naming itself and is shown at
    /// once. One arriving at a prompt OSC 133;D announced is shell churn,
    /// discarded exactly like the local gate discards it. Any other title is
    /// judged against the host's latest foreground report, which the host
    /// sends before the output that follows it: shown when a program holds
    /// the pty (an agent idling between turns: Claude Code's `✳ task`, which
    /// no run state covers), dropped when the shell does or when no report
    /// came. Expiry is the running→ended edge in `executionState.didSet`,
    /// OSC 133;D (`notePromptReturned`), or a report of the shell
    /// (`applyRemoteForeground`).
    func receiveRemoteReportedTitle(_ title: String) {
        // A title arrival is a command boundary — wake the poll. Deferred for
        // the same render-loop reason as the local path.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Discard a bare version number (see the local path) — e.g. remote
        // Claude Code emitting `2.1.202` as its title.
        guard !ProcessInspector.looksLikeVersionString(trimmed) else { return }
        if executionState != .running {
            guard !isShellAtPrompt, remoteProgramHoldsForeground else { return }
        }
        if trimmed != programTitle { programTitle = trimmed }
        programTitlePID = nil
    }

    /// Whether the host's latest report is a program rather than a shell —
    /// the host's own verdict and the shell name both, so a nested shell's
    /// prompt titles don't count.
    private var remoteProgramHoldsForeground: Bool {
        guard let sample = foregroundSample, sample.name != nil, sample.origin == .remoteEvent else { return false }
        return !sample.isIdleShell && !remoteForegroundIsShell
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

    /// Tier-2 naming input for remote panes (#104): the foreground that the
    /// host's session reports for this pane (`ZmxForegroundEvents`). A macOS
    /// remote reports `comm` as a full executable path — keep the basename,
    /// matching local kernel-comm behavior. A version-shaped `comm` (Claude Code's native
    /// install sets its own to `2.1.207`) is named by its invoked name
    /// instead, as `ProcessInspector.runningProcessName` falls back to the
    /// executable locally. nil keeps the last-known name and command.
    ///
    /// Both verdicts prefer the HOST's own reading, falling back to the local
    /// shell database only when the report has none. The idle verdict
    /// (`foreground.isIdle`) is foreground pgid == session leader, and the
    /// shell verdict (`foreground.isShell`) is the host's `/etc/shells`. The
    /// local database is wrong in both directions across hosts: a remote-only
    /// login shell it doesn't list would read busy at an idle prompt forever
    /// and its nested prompt titles as a program's, and a NESTED shell running
    /// inside the session shell would read idle even though closing kills it
    /// — the host-side verdict matches libghostty's local surface semantics
    /// (a nested shell is a running child) instead.
    ///
    /// `remoteForegroundCommand` follows the local `runningCommand` contract:
    /// a shell foreground records no command, anything else records the
    /// report's full command line — falling back to the comm basename when the
    /// report carried no args field. Deliberately the shell verdict, not
    /// the idle one: locally, `runningCommand` returns nil for any shell
    /// argv[0], nested or not, and layout capture mirrors that.
    func applyRemoteForeground(_ foreground: RemoteForeground?) {
        guard let foreground, !foreground.comm.isEmpty else { return }
        let name = Self.remoteProcessName(comm: foreground.comm, command: foreground.command)
        guard !name.isEmpty else { return }
        let origin = ForegroundSample.Origin.remoteEvent
        let isShell = foreground.isShell ?? ProcessInspector.isShellProcessName(name)
        let isIdleShell = foreground.isIdle ?? isShell
        if name != foregroundProcessName || isIdleShell != foregroundSample?.isIdleShell
            || origin != foregroundSample?.origin
        {
            foregroundSample = ForegroundSample(
                name: name,
                isIdleShell: isIdleShell,
                origin: origin,
                sampledAt: Date()
            )
        }
        remoteForegroundIsShell = isShell
        remoteForegroundCommand = isShell ? nil : (foreground.command ?? name)
        // The shell is back in front: whatever program titled the pane has
        // gone, and the run-state edge may never have fired (it ended idle).
        if !remoteProgramHoldsForeground, executionState != .running, programTitle != nil {
            programTitle = nil
        }
        // The agent logo, by the local rule: `comm` first, then the invoked
        // name, which the report's `ps -o args=` carries in place of the local
        // KERN_PROCARGS2 argv. Re-matched only when the report changes, as
        // the local path caches against the pid.
        guard foreground != lastAppliedRemoteForeground else { return }
        lastAppliedRemoteForeground = foreground
        let icon = isIdleShell ? nil : AgentIcon.match(comm: name) {
            foreground.command.flatMap { command in
                ProcessInspector.remoteInvokedNames(commandLine: command).first {
                    AgentIcon.match(processName: $0) != nil
                }
            }
        }
        if icon != agentIcon { agentIcon = icon }
    }

    /// How the host's pty reads input, from the session's `tty_mode`. nil
    /// until the first report, and for a pane with no host session.
    @ObservationIgnored
    var remoteLineMode: TerminalLineMode?

    /// The latest report's shell verdict on the foreground (see
    /// `applyRemoteForeground`).
    @ObservationIgnored
    private(set) var remoteForegroundIsShell = false

    /// The latest report, for the password asker.
    var remoteForegroundReport: RemoteForeground? { lastAppliedRemoteForeground }

    /// The report the agent logo was last matched against.
    @ObservationIgnored
    private var lastAppliedRemoteForeground: RemoteForeground?

    /// The tab name for a reported remote foreground: the basename of `comm`
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

    /// Name-only convenience over `applyRemoteForeground` (no args, no host
    /// idle verdict — falls back to the local shell database).
    func applyRemoteForegroundName(_ comm: String?) {
        guard let comm else { return }
        applyRemoteForeground(RemoteForeground(comm: comm, isIdle: nil, command: nil))
    }

    /// Basename of a remote `ps -o comm=` value, minus the leading `-` a
    /// login shell carries in its argv[0] (`-/opt/homebrew/bin/nu` → `nu`,
    /// `-zsh` → `zsh`). Local kernel `comm` never has this dash, so the
    /// stripping is remote-only. Pure + static for testing.
    static func normalizeRemoteComm(_ comm: String) -> String {
        let stripped = comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
        return (stripped as NSString).lastPathComponent
    }

    /// Testable core of `receiveReportedTitle`. `programPID` is the pane's
    /// foreground pid when that process is a non-shell program, nil otherwise.
    func receiveReportedTitle(_ title: String, programPID: pid_t?) {
        // A title arrival is a command boundary — wake the adaptive poll so
        // the other panes' names catch up too. Deferred one turn, so the poll
        // never runs inside the caller's own work.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
        refreshForegroundProcess()
        guard let programPID else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A bare version number is not a useful display title — Claude Code
        // emits its version (`2.1.202`) as an OSC 2 title at its prompt. Discard
        // it so `displayTitle` falls back to the process name instead of pinning
        // the version. (Its real status titles aren't version-shaped, so they
        // still adopt normally.)
        guard !ProcessInspector.looksLikeVersionString(trimmed) else { return }
        if trimmed != programTitle { programTitle = trimmed }
        programTitlePID = programPID
    }

    /// Whether this remote pane's connection stopped (#281, 0057): its client
    /// (`macterm remote-pane`) waits on the pane's tty while the session
    /// lives on the host. Read at trigger time by the reconnect sweep. Local
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
        cancelHeldTitle()
        guard hadView else { return }
        isReceivingRemoteSnapshot = false
        remoteLineMode = nil
        // A remote pane's report described the connection that goes now.
        // The next connection's session reports again; until then nothing
        // is known, so the close falls back to the surface's reading.
        if isRemote {
            foregroundSample = nil
            remoteForegroundCommand = nil
            remoteForegroundIsShell = false
            lastAppliedRemoteForeground = nil
        }
        // A notification whose pane no longer exists routes nowhere on tap, so
        // drop any still sitting in Notification Center. Ghostty does the same
        // when a surface is removed.
        NotificationHandler.shared.clearDelivered(paneID: id)
    }

    var processTitle: String {
        // The live foreground process name (`hx`, `btop`) when a program is
        // running, else the shell name when idle. Always process-table derived
        // (never the OSC title) — the quit confirmation lists real process
        // names, and `displayTitle` falls back here. For a remote pane the
        // name comes from the host's report; before one lands (or when the
        // host has no server) the host name is the honest fallback — the
        // local login shell never runs in a remote pane.
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
        sessionID: UUID = UUID(),
        sessionSlug: String? = nil,
        sessionName persistedSessionName: String? = nil,
        command: String? = nil,
        shell: String? = nil,
        env: [String: String]? = nil,
        activityQuietPollDelay: TimeInterval = TerminalActivityTiming.quietPollDelay,
        titleReportInterval: TimeInterval = PollCadence.fastInterval
    ) {
        titleReportThrottle = TitleReportThrottle(interval: titleReportInterval)
        self.projectPath = projectPath
        self.projectID = projectID
        self.sessionID = sessionID
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
            sessionName = ZmxSessionName.make(projectName: slug, paneSessionID: sessionID)
        }
        self.command = command
        self.shell = shell
        self.env = env
        self.activityQuietPollDelay = activityQuietPollDelay
        executionTracker = TerminalExecutionTracker(
            hasUserInteraction: command != nil || env?[CustomPaletteScript.commandVariable] != nil
        )
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
    /// it; `LocalSessions.requestTimeout` (local) and the host link's request
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
