import AppKit

extension Pane {
    /// Connect the view's callbacks that feed the pane's own state: execution
    /// tracking, attention flags, titles, notifications and project memory.
    /// `PaneSurface.ensureNSView` calls this when it makes the view, so the callbacks work
    /// before any window draws the pane. A pane in a `tab new --no-focus` tab,
    /// or in a background tab that a launch warmed, otherwise recorded no
    /// submission and no output, and `pane list` showed its run as idle.
    /// The callbacks that need the window that draws the pane (focus, splits,
    /// zoom, process exit, tab titles, links, the adaptive background, and
    /// `onRunEnded`) stay in `TerminalSurface.configure`.
    ///
    /// The session's own messages (foreground, title, tty mode, marks,
    /// state, attention) come on every surface's channel and say the same
    /// thing, so every surface applies them. Every surface of a pane also
    /// parses the same output with libghostty, so the callbacks that count
    /// what it reads (runs, notifications, project memory) act only for the
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
        // Order matters: `onInteraction` clears the tracker's in-place start
        // arming that `onCommandSubmitted` sets, and the view calls them in
        // that order. See `GhosttyTerminalNSView.onCommandSubmitted`.
        view.onCommandSubmitted = { [weak self, weak view] hasContent in
            guard let self else { return }
            // Before the tracker leaves the prompt: memory captures the line
            // only while the shell is at its prompt.
            ProjectMemory.shared.commandSubmitted(pane: self, view: view)
            recordCommandSubmission(hasContent: hasContent)
        }
        view.canCarryCommandInput = { [weak self] in self?.allowsInPlaceOutputStart ?? false }
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
        view.onAttention = { [weak self] flags in self?.receiveAttention(flags) }
        view.onTitleChange = { [weak self] title in self?.receiveReportedTitle(title) }
        view.onSessionState = { [weak self] state in self?.receiveSessionState(state) }
        view.onSessionForeground = { [weak self] foreground in self?.applyForeground(foreground) }
        view.onTtyMode = { [weak self] mode in self?.lineMode = mode }
        view.onSessionMark = { [weak self] mark in
            // OSC 133;D: the shell owns its prompt again. It feeds the title
            // gate and the tracker's prompt hold.
            if mark.kind == .end { self?.notePromptReturned() }
        }
        // libghostty's callbacks: only the feed surface counts what it parses.
        let isFeed = { [weak view] in view?.owningSurface?.isFeed ?? true }
        view.onDesktopNotification = { [weak self, weak view] title, body in
            guard let self, isFeed() else { return }
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            NotificationHandler.shared.post(pane: self, title: title, body: body)
        }
        view.onProgressStarted = { [weak self] in
            guard isFeed() else { return }
            self?.markCommandRunning()
        }
        view.onProgressFinished = { [weak self, weak view] in
            // Only a live run can end. Whether it failed is the session's
            // flag (`Pane.attention`).
            guard let self, isFeed(), executionState == .running else { return }
            markProgressFinished()
            view?.onRunEnded?()
        }
        view.onOutputActivity = { [weak self, weak view] total in
            if let view {
                AdaptiveTerminalChrome.shared.terminalDidOutput(view)
                // A prompt is output: re-read the tty now rather than at the
                // next idle poll, so the bubble is up before the user types.
                PasswordPromptMonitor.shared.viewDidOutput(view)
            }
            guard let self, isFeed() else { return }
            // The single activity source. Output heartbeats fire from the pty
            // IO path regardless of occlusion, so they also reach background
            // tabs, and they carry the row total so the tracker can tell
            // growth from an in-place redraw. The session's foreground and
            // tty mode reach the tracker on their own (`applyForeground`).
            markOutputActivity(totalRows: total)
        }
        view.onCommandFinished = { [weak self, weak view] exitCode, durationNs, command in
            guard let self, isFeed() else { return }
            // A surface on a channel gets the shell's 133;D from the session
            // (`onSessionMark`); a surface with no session has only this one.
            if view?.channelRuntime == nil { notePromptReturned() }
            // Project memory: off unless the user turned it on, macOS 26+.
            ProjectMemory.shared.commandFinished(
                pane: self, view: view, exitCode: exitCode, durationNs: durationNs, reportedCommand: command
            )
            markCommandFinished()
            view?.onRunEnded?()
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
