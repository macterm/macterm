import Foundation
import notify
import os

private let logger = Logger(subsystem: appBundleID, category: "RemotePaneDriver")

/// What one remote pane does (0057, 0195): it asks `RemoteHosts` what to do,
/// and runs the answer on the pane's surface. Its states:
///
/// - running: a `PaneSession` on the host's link feeds the surface;
/// - plain: a `PlainShell`, a pty with ssh, for a host with no server;
/// - waiting: a line of Macterm's is on the screen. A wake (a login that
///   ended, a trigger of the reconnect sweep) or a key asks again.
///
/// A lost link ends the session's reading and asks `RemoteHosts` with
/// `lost`: the pane dims under one line and waits for a trigger or a key.
/// The app's backoff and triggers (`AppState.reconnectDroppedRemotePanes`)
/// own the next try. A session that is gone from the host closes the pane.
@MainActor
final class RemotePaneDriver: PaneInputRoute {
    private enum State {
        case idle
        case waiting
        case running(PaneSession)
        case plain(PlainShell)
        case closed
    }

    let name: String
    private let surface: any PaneSessionHost
    private let hosts: RemoteHosts
    private var state = State.idle
    /// Tells a late answer from a current one.
    private var generation = 0
    private var wakeToken: Int32 = NOTIFY_TOKEN_INVALID
    /// Input that waits for a session: a layout's `initial_input`, and keys
    /// typed while the pane waits. The next attach sends it. A pane that
    /// runs plain drops it, because it was for another session.
    private var earlyInput = Data()
    /// Input that a lost link refused, in order. It goes before `earlyInput`.
    private var undelivered = Data()
    /// A key found the link down: connect at once after the `lost` answer.
    private var retryAfterLost = false

    init(name: String, surface: any PaneSessionHost, hosts: RemoteHosts = .shared) {
        self.name = name
        self.surface = surface
        self.hosts = hosts
    }

    func start() {
        registerWake()
        step(.ask)
    }

    func stop() {
        generation += 1
        retryAfterLost = false
        teardown()
        state = .closed
        if wakeToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(wakeToken)
            wakeToken = NOTIFY_TOKEN_INVALID
        }
    }

    // MARK: - Steps

    private func step(_ event: RemotePaneEvent) {
        generation += 1
        let mine = generation
        Task { @MainActor in
            // A pane that restores before the app has installed its state
            // waits: no panes would read as "the pane closed".
            while hosts.panes == nil {
                try? await Task.sleep(for: .milliseconds(200))
                guard mine == generation else { return }
            }
            let answer = await hosts.answer(event, session: name, panes: hosts.panes?(name) ?? [])
            guard mine == generation else { return }
            apply(answer, generation: mine)
        }
    }

    private func apply(_ answer: RemotePaneAnswer, generation mine: Int) {
        if case .closed = state { return }
        teardown()
        switch answer {
        case let .wait(message):
            if let message { surface.paneFeed(Data(Self.paneText(message).utf8)) }
            state = .waiting
            if retryAfterLost {
                retryAfterLost = false
                step(.retry)
            }
        case .close:
            state = .closed
            surface.paneExited(code: nil, signal: nil)
        case let .plain(arguments, message):
            earlyInput = Data()
            undelivered = Data()
            surface.paneFeed(PaneSession.resetScreen)
            if let message { surface.paneFeed(Data(Self.paneText(message).utf8)) }
            runPlain(arguments)
        case let .attach(link, create):
            attach(link: link, create: create, generation: mine)
        }
    }

    private func attach(link: RemoteServers.Link, create: String?, generation mine: Int) {
        Task { @MainActor in
            var launch: PaneSession.Launch?
            if let create {
                guard let made = await hosts.createLaunch(link: link, directory: create) else {
                    guard mine == generation else { return }
                    linkStopped()
                    return
                }
                guard mine == generation else { return }
                launch = made.launch
                if let note = made.note { surface.paneFeed(Data(Self.paneText(note).utf8)) }
            }
            // A step that came after this answer owns the pane now.
            guard mine == generation else { return }
            let forward = Forward(driver: self, surface: surface)
            let session = PaneSession(
                name: name, launch: launch, wantsForeground: true, wantsTty: true, reconnects: false,
                host: forward,
                connect: { link.connection }
            )
            forward.session = session
            state = .running(session)
            session.start()
            let waiting = undelivered + earlyInput
            undelivered = Data()
            earlyInput = Data()
            if !waiting.isEmpty { session.sendInput(waiting) }
        }
    }

    private func runPlain(_ arguments: [String]) {
        let mine = generation
        let shell = PlainShell(arguments: arguments, grid: surface.paneGrid(), host: surface) { [weak self] status in
            DispatchQueue.main.async { self?.plainExited(status, generation: mine) }
        }
        if let shell {
            state = .plain(shell)
        } else {
            surface.paneFeed(Data(Self.paneText("Macterm cannot start ssh.").utf8))
            state = .waiting
        }
    }

    private func plainExited(_ status: Int32, generation mine: Int) {
        guard mine == generation, case .plain = state else { return }
        // ssh exits 255 when the connection stops: the pane waits. Any other
        // status is the shell's: the pane ends.
        let code = (status >> 8) & 0xFF
        if code == 255 {
            linkStopped()
        } else {
            state = .closed
            surface.paneExited(code: UInt8(truncatingIfNeeded: code), signal: nil)
        }
    }

    fileprivate func sessionAttached() {
        hosts.sessionAttached(name, panes: hosts.panes?(name) ?? [])
    }

    /// The connection stopped: the pane dims and waits for a trigger.
    fileprivate func linkStopped() {
        if case .closed = state { return }
        logger.info("remote pane: session=\(self.name, privacy: .public) link stopped")
        teardown()
        state = .waiting
        step(.lost)
    }

    private func teardown() {
        switch state {
        case let .running(session):
            session.stop()
            // Input that never reached a channel waits for the next session.
            undelivered.append(session.takePendingInput())
        case let .plain(shell): shell.terminate()
        default: break
        }
        state = .idle
    }

    private func registerWake() {
        notify_register_dispatch(RemoteHosts.wakeName(for: name), &wakeToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
    }

    private func woke() {
        switch state {
        case .waiting,
             .idle: step(.ask)
        default: break
        }
    }

    // MARK: - Input

    nonisolated func sendInput(_ data: Data) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.route(data) } }
    }

    nonisolated func claim(grid: PaneGrid?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.currentRoute()?.claim(grid: grid) } }
    }

    nonisolated func sendSize(_ grid: PaneGrid?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.currentRoute()?.sendSize(grid) } }
    }

    private func currentRoute() -> (any PaneInputRoute)? {
        switch state {
        case let .running(session): session
        case let .plain(shell): shell
        default: nil
        }
    }

    private func route(_ data: Data) {
        switch state {
        case let .running(session): session.sendInput(data)
        case let .plain(shell): shell.sendInput(data)
        case .waiting:
            // The key waits for the new session.
            keep(data)
            step(.retry)
        case .idle:
            // The `initial_input` of a layout, written while the surface
            // starts: it goes to the session when one runs.
            keep(data)
        case .closed: break
        }
    }

    /// A key that the running session could not send: the link is down, and
    /// the key asks to connect, as a key in a pane that waits does.
    fileprivate func keyFoundLinkDown(_ data: Data) {
        keep(data)
        retryAfterLost = true
        linkStopped()
    }

    fileprivate func keepUndelivered(_ data: Data) {
        // A pane that closed has no later attach.
        if case .closed = state { return }
        keep(data)
    }

    private func keep(_ data: Data) {
        if earlyInput.count + data.count <= 1 << 20 { earlyInput.append(data) }
    }

    /// Macterm's line, on a line of its own: each line ends with CR LF,
    /// because the screen can be in any mode.
    nonisolated static func paneText(_ message: String) -> String {
        "\r\n" + message.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    // MARK: - The session's host

    /// What a session of this driver reports: everything goes to the
    /// surface, and a lost link goes to the driver. A report counts only from
    /// the driver's running session: an old session must not stop a new one.
    private final class Forward: PaneSessionHost, @unchecked Sendable {
        private weak var driver: RemotePaneDriver?
        private let surface: any PaneSessionHost
        /// Set once, on the main actor, before the session starts.
        weak var session: PaneSession?

        init(driver: RemotePaneDriver, surface: any PaneSessionHost) {
            self.driver = driver
            self.surface = surface
        }

        @MainActor
        private func isCurrent(_ driver: RemotePaneDriver) -> Bool {
            guard case let .running(running) = driver.state, let session else { return false }
            return running === session
        }

        func paneFeed(_ data: Data) {
            surface.paneFeed(data)
        }

        func paneGrid() -> PaneGrid {
            surface.paneGrid()
        }

        func paneSnapshot(started: Bool) {
            surface.paneSnapshot(started: started)
            // Each attach starts with a snapshot: the session runs.
            guard started else { return }
            DispatchQueue.main.async { [weak driver, self] in
                MainActor.assumeIsolated {
                    guard let driver, isCurrent(driver) else { return }
                    driver.sessionAttached()
                }
            }
        }

        func paneForeground(_ foreground: MactermProtocol.Foreground) {
            surface.paneForeground(foreground)
        }

        func paneTtyMode(_ mode: MactermProtocol.TtyMode) {
            surface.paneTtyMode(mode)
        }

        func paneLead(_ leader: Bool?) {
            surface.paneLead(leader)
        }

        func paneExited(code: UInt8?, signal: UInt8?) {
            surface.paneExited(code: code, signal: signal)
        }

        func paneLinkLost() {
            DispatchQueue.main.async { [weak driver, self] in
                MainActor.assumeIsolated {
                    guard let driver, isCurrent(driver) else { return }
                    driver.linkStopped()
                }
            }
        }

        func paneInputUndelivered(_ data: Data) {
            DispatchQueue.main.async { [weak driver, self] in
                MainActor.assumeIsolated {
                    guard let driver else { return }
                    if isCurrent(driver) { return driver.keyFoundLinkDown(data) }
                    // A late failure of an old session counts only while the pane waits.
                    if case .waiting = driver.state { driver.keepUndelivered(data) }
                }
            }
        }

        func paneGone() {
            paneLinkLost()
        }
    }
}
