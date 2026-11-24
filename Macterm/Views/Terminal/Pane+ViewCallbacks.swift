import AppKit

extension Pane {
    /// Connect the view's callbacks that feed the pane's own state.
    /// `PaneSurface.ensureNSView` calls this when it makes the view, so the
    /// callbacks work before any window draws the pane. The callbacks that
    /// need the window that draws the pane (focus, splits, zoom, process
    /// exit, tab titles, links and the adaptive background) stay in
    /// `TerminalSurface.configure`. `PaneSurface` sets the search, copy
    /// mode, link and read-only callbacks.
    ///
    /// The session's messages (foreground, title, tty mode, marks, folder,
    /// state, status, attention, notifications, bell) and its end come once,
    /// through the pane's `PaneLink` (`receiveLinkEvent`), not through the
    /// views. libghostty's callbacks for the same facts act only for a
    /// surface whose session does not send them
    /// (`GhosttyTerminalNSView.sessionSendsFacts`): a surface with no session,
    /// and a plain ssh shell, which runs in one surface.
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
        view.onDesktopNotification = { [weak self, weak view] title, body in
            guard let self, view?.sessionSendsFacts == false else { return }
            postDesktopNotification(title: title, body: body)
        }
        view.onOutputActivity = { [weak view] _ in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalDidOutput(view)
            // A prompt is output: re-read the tty now rather than at the
            // next idle poll, so the bubble is up before the user types.
            PasswordPromptMonitor.shared.viewDidOutput(view)
        }
        view.onCommandFinished = { [weak self, weak view] exitCode, durationNs, command in
            guard let self, let view, !view.sessionSendsFacts else { return }
            // The prompt gate and the title expiry read the 133;D.
            receiveSessionMark(MactermProtocol.Mark(kind: .end))
            let duration = Double(durationNs) / 1_000_000_000
            let code = exitCode < 0 ? nil : Int(exitCode)
            recordCommandEnd(
                command: command,
                exitCode: code,
                startedAt: Date().addingTimeInterval(-duration),
                outputTail: nil,
                directory: view.currentPwd
            )
            notifyCommandFinished(exitCode: code, duration: duration)
        }
    }

    /// An OSC 133 mark of the pane's session, once for the pane: the prompt
    /// gate and the title expiry (`receiveSessionMark(_:)`), the command's
    /// start, and at its end Project Insights and the Command Finished
    /// notification. A command whose start came before the channel attached
    /// has no duration and gets no notification, as in Ghostty.
    func receiveCommandMark(_ mark: MactermProtocol.Mark) {
        receiveSessionMark(mark)
        switch mark.kind {
        case .output:
            commandStartedAt = Date()
        case .end:
            let startedAt = commandStartedAt
            commandStartedAt = nil
            let exitCode = mark.exitCode.map(Int.init)
            recordCommandEnd(
                command: mark.command.map { String(decoding: $0.bytes, as: UTF8.self) },
                exitCode: exitCode,
                startedAt: startedAt,
                outputTail: mark.outputTail.map { String(decoding: $0.bytes, as: UTF8.self) },
                directory: sessionDirectory
            )
            if let startedAt { notifyCommandFinished(exitCode: exitCode, duration: Date().timeIntervalSince(startedAt)) }
        case .prompt,
             .input,
             .unknown:
            break
        }
    }

    /// Whether the user looks at the pane: the app is active and the pane is
    /// the focused pane of the key window. A notification is then not posted.
    private var isFocusedInKeyWindow: Bool {
        NSApp.isActive && SurfaceRegistry.shared.surfaces(of: self).contains {
            guard let view = $0.nsView else { return false }
            return view.isFocused && view.window?.isKeyWindow == true
        }
    }

    /// A desktop notification that a program asked for (OSC 9, OSC 777).
    func postDesktopNotification(title: String, body: String) {
        guard !isFocusedInKeyWindow else { return }
        NotificationHandler.shared.post(pane: self, title: title, body: body)
    }

    /// The bell rang: the beep, the sound and the Dock bounce of the user's
    /// `bell-features`, once for the pane (`GhosttyCallbacks.ringBell`).
    func ringBell() {
        GhosttyCallbacks.ringBell()
    }

    /// The Command Finished notification. `exitCode` nil: not known.
    private func notifyCommandFinished(exitCode: Int?, duration: TimeInterval) {
        guard !isFocusedInKeyWindow else { return }
        let formatted = Self.formatDuration(duration)
        let body = if let exitCode {
            String(localized: "Exited with code \(exitCode) (\(formatted))")
        } else {
            String(localized: "Completed in \(formatted)")
        }
        NotificationHandler.shared.post(pane: self, title: String(localized: "Command Finished"), body: body)
    }

    /// Hands a finished command to project memory (off unless the user
    /// turned it on, macOS 26+). A failure's output tail comes from the
    /// session's end mark: nothing reads the screen.
    private func recordCommandEnd(
        command: String?,
        exitCode: Int?,
        startedAt: Date?,
        outputTail: String?,
        directory: String?
    ) {
        let end = CommandEnd(
            paneID: id,
            projectID: projectID,
            command: command,
            exitCode: exitCode,
            directory: directory,
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
