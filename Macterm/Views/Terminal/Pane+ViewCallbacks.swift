import AppKit

extension Pane {
    /// Connect the view's callbacks that feed the pane's own state: titles,
    /// notifications and project memory.
    /// `PaneSurface.ensureNSView` calls this when it makes the view, so the callbacks work
    /// before any window draws the pane. A pane in a `tab new --no-focus` tab,
    /// or in a background tab that a launch warmed, otherwise recorded no
    /// submission and no output, and `pane list` showed its run as idle.
    /// The callbacks that need the window that draws the pane (focus, splits,
    /// zoom, process exit, tab titles, links and the adaptive background)
    /// stay in `TerminalSurface.configure`.
    ///
    /// The session's own messages (foreground, title, tty mode, marks,
    /// state, status, attention) and its end come once, through the pane's
    /// `PaneLink` (`receiveLinkEvent`), not through the views. Every surface
    /// of a pane parses the same output with libghostty, so the callbacks
    /// that count what it reads (notifications, project memory) act
    /// only for the surface of the link's counting view
    /// (`PaneSurface.countsOutput`). `PaneSurface` sets the search, copy mode, link and read-only
    /// callbacks.
    func connectViewCallbacks(_ view: GhosttyTerminalNSView) {
        view.onInteraction = { [weak self] in
            self?.recordUserInteraction()
        }
        view.onSurfaceSized = { [weak view] in
            guard let surface = view?.owningSurface else { return }
            NotificationCenter.default.post(name: .terminalSurfaceSized, object: surface.id)
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
        // A surface with no session reports its own titles.
        view.onTitleChange = { [weak self] title in self?.receiveReportedTitle(title) }
        // libghostty's callbacks: only the counting surface counts what it parses.
        let counts = { [weak view] in view?.owningSurface?.countsOutput ?? true }
        view.onDesktopNotification = { [weak self, weak view] title, body in
            guard let self, counts() else { return }
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
            guard let self, counts() else { return }
            // A surface on a channel gets the shell's 133;D from the session
            // (`receiveSessionMark`); a surface with no session has only this
            // one. The prompt gate and the title expiry read it.
            if view?.channelRuntime == nil {
                receiveSessionMark(MactermProtocol.Mark(kind: .end))
                let duration = Double(durationNs) / 1_000_000_000
                recordCommandEnd(
                    command: command,
                    exitCode: exitCode < 0 ? nil : Int(exitCode),
                    startedAt: Date().addingTimeInterval(-duration),
                    outputTail: nil,
                    view: view
                )
            }
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

    /// A mark of the pane's session, once for the pane, from the link's
    /// counting view (`view`): the prompt gate and the title expiry
    /// (`receiveSessionMark(_:)`), and the command's start and its end for
    /// project memory.
    func receiveSessionMark(_ mark: MactermProtocol.Mark, view: GhosttyTerminalNSView?) {
        receiveSessionMark(mark)
        switch mark.kind {
        case .output:
            commandStartedAt = Date()
        case .end:
            let command = mark.command.map { String(decoding: $0.bytes, as: UTF8.self) }
            recordCommandEnd(
                command: command,
                exitCode: mark.exitCode.map(Int.init),
                startedAt: commandStartedAt,
                outputTail: mark.outputTail.map { String(decoding: $0.bytes, as: UTF8.self) },
                view: view
            )
            commandStartedAt = nil
        case .prompt,
             .input,
             .unknown:
            break
        }
    }

    /// Hands a finished command to project memory (off unless the user
    /// turned it on, macOS 26+). A failure's output tail comes from the
    /// session's end mark: nothing reads the screen.
    private func recordCommandEnd(
        command: String?,
        exitCode: Int?,
        startedAt: Date?,
        outputTail: String?,
        view: GhosttyTerminalNSView?
    ) {
        let end = CommandEnd(
            paneID: id,
            projectID: projectID,
            command: command,
            exitCode: exitCode,
            directory: view?.currentPwd,
            startedAt: startedAt,
            finishedAt: Date(),
            outputTail: outputTail
        )
        ProjectMemory.shared.commandEnded(end)
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

    /// The session ended: the pane closes, once. The handler is the one of
    /// the window that draws the pane (`TerminalSurface.configure`), or the
    /// warm's (`AppState.warmPane`): the first surface that has one, from the
    /// preferred surface on.
    func sessionDidEnd() {
        let registry = SurfaceRegistry.shared
        let all = registry.surfaces(of: self)
        guard !all.isEmpty else { return }
        let preferred = registry.preferredSurface(of: self)
        let ordered = [preferred] + all.filter { $0 !== preferred }
        ordered.lazy.compactMap(\.nsView).compactMap(\.onProcessExit).first?()
    }

    /// Tells the session that the user saw the pane, on the channel of one
    /// of its surfaces. Every client of the session then gets the cleared
    /// flags.
    func sendSeenToSession() {
        let views = SurfaceRegistry.shared.surfaces(of: self).lazy.compactMap(\.nsView)
        views.first { $0.channelRuntime != nil }?.sendSeen()
    }
}
