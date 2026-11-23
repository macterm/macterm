import AppKit

extension Pane {
    /// Connect the view's callbacks that feed the pane's own state: the run
    /// state, attention flags, titles, notifications and project memory.
    /// `PaneSurface.ensureNSView` calls this when it makes the view, so the callbacks work
    /// before any window draws the pane. A pane in a `tab new --no-focus` tab,
    /// or in a background tab that a launch warmed, otherwise recorded no
    /// submission and no output, and `pane list` showed its run as idle.
    /// The callbacks that need the window that draws the pane (focus, splits,
    /// zoom, process exit, tab titles, links, the adaptive background, and
    /// `onRunEnded`) stay in `TerminalSurface.configure`.
    ///
    /// The session's own messages (foreground, title, tty mode, marks,
    /// state, status, attention) come on every surface's channel and say the
    /// same thing, so every surface applies them. Every surface of a pane also
    /// parses the same output with libghostty, so the callbacks that count
    /// what it reads (notifications, project memory) act only for the
    /// feed surface (`PaneSurface.isFeed`), which each one asks when it
    /// fires: when the first surface goes, the next one takes over with no
    /// handoff. `PaneSurface` sets the search, copy mode, link and read-only
    /// callbacks.
    func connectViewCallbacks(_ view: GhosttyTerminalNSView) {
        view.onInteraction = { [weak self] in
            self?.recordUserInteraction()
        }
        view.onSurfaceSized = { [weak view] in
            guard let surface = view?.owningSurface else { return }
            NotificationCenter.default.post(name: .terminalSurfaceSized, object: surface.id)
        }
        view.onCommandSubmitted = { [weak self, weak view] in
            guard let self else { return }
            // Memory captures the line only while the shell is at its prompt,
            // which the session's 133;C ends after this Return.
            ProjectMemory.shared.commandSubmitted(pane: self, view: view)
        }
        // The surface half of the passthrough gate. The key responders decline
        // the event first; without this, `isAppShortcut` would still swallow it
        // here. Both consult `KeybindPassthrough` so they can't disagree.
        view.yieldsToProgram = { [weak self] event in
            guard let self else { return false }
            return KeybindPassthrough.yields(event: event, pane: self)
        }
        view.titleProvider = { [weak self] in self?.displayTitle }
        // Chrome and password prompts follow each view, not the pane.
        view.onTerminalRender = { [weak view] in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalDidRender(view)
        }
        view.onBackgroundColorChange = { [weak view] color in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalBackgroundDidChange(color, in: view)
        }
        // Every surface's channel gets the same messages from the session.
        view.onAttention = { [weak self, weak view] flags in
            self?.receiveAttention(flags)
            // A run ended that no client showed: the window that draws this
            // surface marks it seen when the user looks at it. The session
            // sends the flags after the status that ended the run.
            if flags.unseen { view?.onRunEnded?() }
        }
        view.onTitleChange = { [weak self] title in self?.receiveReportedTitle(title) }
        view.onSessionState = { [weak self] state in self?.receiveSessionState(state) }
        view.onSessionForeground = { [weak self] foreground in self?.applyForeground(foreground) }
        view.onTtyMode = { [weak self] mode in self?.lineMode = mode }
        view.onSessionMark = { [weak self] mark in self?.receiveSessionMark(mark) }
        view.onSessionStatus = { [weak self, weak view] status in
            guard let channel = view?.owningSurface?.id else { return }
            self?.receiveSessionStatus(status, channel: channel)
        }
        // libghostty's callbacks: only the feed surface counts what it parses.
        let isFeed = { [weak view] in view?.owningSurface?.isFeed ?? true }
        view.onDesktopNotification = { [weak self, weak view] title, body in
            guard let self, isFeed() else { return }
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            NotificationHandler.shared.post(pane: self, title: title, body: body)
        }
        view.onOutputActivity = { [weak view] _ in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalDidOutput(view)
            // A prompt is output: re-read the tty now rather than at the
            // next idle poll, so the bubble is up before the user types.
            PasswordPromptMonitor.shared.viewDidOutput(view)
        }
        view.onCommandFinished = { [weak self, weak view] exitCode, durationNs, command in
            guard let self, isFeed() else { return }
            // A surface with no session has only libghostty's 133;D: the
            // prompt gate and the title expiry read it.
            if view?.channelRuntime == nil { receiveSessionMark(MactermProtocol.Mark(kind: .end)) }
            // Project memory: off unless the user turned it on, macOS 26+.
            ProjectMemory.shared.commandFinished(
                pane: self, view: view, exitCode: exitCode, durationNs: durationNs, reportedCommand: command
            )
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            let durationSec = Double(durationNs) / 1_000_000_000
            let duration = Self.formatDuration(durationSec)
            let body = if exitCode < 0 {
                String(localized: "Completed in \(duration)")
            } else {
                String(localized: "Exited with code \(Int(exitCode)) (\(duration))")
            }
            NotificationHandler.shared.post(pane: self, title: String(localized: "Command Finished"), body: body)
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            let value = String(format: "%.1f", seconds)
            return String(localized: "\(value)s", comment: "A duration in seconds, as in 4.2s")
        } else if seconds < 3600 {
            let rounded = Int(seconds.rounded())
            let mins = rounded / 60
            let secs = rounded % 60
            return String(localized: "\(mins)m \(secs)s", comment: "A duration in minutes and seconds, as in 3m 20s")
        } else {
            let rounded = Int(seconds.rounded())
            let hours = rounded / 3600
            let mins = (rounded % 3600) / 60
            return String(localized: "\(hours)h \(mins)m", comment: "A duration in hours and minutes, as in 2h 5m")
        }
    }

    /// Tells the session that the user saw the pane, on the channel of one
    /// of its surfaces. Every client of the session then gets the cleared
    /// flags.
    func sendSeenToSession() {
        let views = SurfaceRegistry.shared.surfaces(of: self).lazy.compactMap(\.nsView)
        views.first { $0.channelRuntime != nil }?.sendSeen()
    }
}
