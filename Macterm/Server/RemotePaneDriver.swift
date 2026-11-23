import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemotePaneDriver")

/// What one view of a remote pane does (0057, 0195, 0264): one task that
/// asks the pane's `RemoteHost` what to run, and runs it on the pane's
/// surface. Its states:
///
/// - connecting: it waits for the host (`RemoteHost.attachment`): a login,
///   a check or an install that runs;
/// - running: a `PaneSession` on the host's link feeds the surface;
/// - plain: a `PlainShell`, a pty with ssh, for a host with no server;
/// - waiting: the pane is lost, or it has nothing to run. It waits for the
///   host's next try (`RemoteHost.nextTry`): a trigger of the app after the
///   host's backoff, or a key.
///
/// A lost link ends the session's reading and tells the host
/// (`RemoteHost.lost`): the pane shows its badge and its disabled cursor,
/// and waits. A session that is gone from the host closes the pane. `stop`
/// cancels the task, and every wait ends.
@MainActor
final class RemotePaneDriver: PaneInputRoute {
    private enum State {
        case connecting
        case waiting
        case running(PaneSession)
        case plain(PlainShell)
        case closed
    }

    /// How a session or a plain shell of the driver ended.
    private enum End {
        /// The connection stopped.
        case lost
        /// A key found the connection down: connect at once, and the login
        /// may ask.
        case keyFoundLinkDown
        /// Nothing to run now (ssh did not start, a create that the host did
        /// not answer): wait for the next try.
        case nothing
        /// The shell exited, or the driver stopped.
        case done
    }

    let name: String
    private let surface: any PaneSessionHost
    private let hosts: RemoteHosts
    private var state = State.connecting
    private var task: Task<Void, Never>?
    private weak var pane: Pane?
    private var host: RemoteHost?
    /// The end of the session or the plain shell that runs.
    private var ending: CheckedContinuation<End, Never>?
    /// Input that waits for the first session: a layout's `initial_input`,
    /// and keys typed before the first connect ends. The next attach sends
    /// it. A pane that runs plain drops it, because it was for another
    /// session. Keys typed while the pane is lost are dropped, by decision
    /// (Ethan, 2026-11-16, option C): they were typed at a stale screen.
    private var earlyInput = Data()
    /// Input of a session that never attached, in order. It goes before
    /// `earlyInput`.
    private var undelivered = Data()
    /// The session attached at least once in this run.
    private var attached = false
    /// After this time with no attach, the first connect is slow
    /// (`RemoteHost.firstConnectIsSlow`).
    private let slowConnectAfter: Duration

    /// A connect to a host whose server does not answer runs until the
    /// handshake gives up (15 s, `RemoteServers.Configuration.handshakeTimeout`).
    /// A login that is slower than this time shows the badge too.
    static let slowConnectAfter: Duration = .seconds(3)

    init(
        name: String,
        surface: any PaneSessionHost,
        hosts: RemoteHosts = .shared,
        slowConnectAfter: Duration = RemotePaneDriver.slowConnectAfter
    ) {
        self.name = name
        self.surface = surface
        self.hosts = hosts
        self.slowConnectAfter = slowConnectAfter
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
        watchFirstConnect()
    }

    func stop() {
        task?.cancel()
        task = nil
        teardown()
        state = .closed
        end(.done)
    }

    /// A pane that came back after a restart shows nothing while its first
    /// connect runs. When that connect is slow, the badge says so.
    private func watchFirstConnect() {
        Task { @MainActor [weak self, slowConnectAfter] in
            try? await Task.sleep(for: slowConnectAfter)
            guard let self, !attached, let host, let pane else { return }
            switch state {
            case .connecting,
                 .waiting: host.firstConnectIsSlow(name, pane: pane)
            case .running,
                 .plain,
                 .closed: break
            }
        }
    }

    // MARK: - The loop

    private func run() async {
        // A pane that restores before the app has installed its state waits
        // for it. No pane: the pane closed.
        guard let pane = try? await hosts.pane(for: name) else {
            if !Task.isCancelled { close() }
            return
        }
        guard let host = hosts.host(of: pane), let directory = RemoteHosts.Target(pane)?.directory else {
            close()
            return
        }
        self.pane = pane
        self.host = host
        var prompts = true
        while !Task.isCancelled {
            state = .connecting
            let attachment: RemoteHost.Attachment
            do {
                attachment = try await host.attachment(for: name, pane: pane, directory: directory, prompts: prompts)
            } catch is CancellationError {
                return
            } catch {
                if case RemoteHost.Failure.noPlainShell = error {
                    surface.paneFeed(Data(Self.paneText(RemotePaneText.noPlainShell).utf8))
                }
                guard let next = await waitForTry(host) else { return }
                prompts = next
                continue
            }
            let end: End
            switch attachment {
            case .ended:
                close()
                return
            case let .plain(arguments):
                earlyInput = Data()
                undelivered = Data()
                surface.paneFeed(PaneSession.resetScreen)
                end = await runPlain(arguments)
            case let .channel(link, create):
                end = await runChannel(link: link, create: create)
            }
            teardown()
            switch end {
            case .done:
                return
            case .lost:
                host.lost(name, pane: pane)
            case .keyFoundLinkDown:
                host.lost(name, pane: pane)
                host.retry(name)
                prompts = true
                continue
            case .nothing:
                break
            }
            guard let next = await waitForTry(host) else { return }
            prompts = next
        }
    }

    /// Waits for the host's next try. nil when the driver stopped.
    private func waitForTry(_ host: RemoteHost) async -> Bool? {
        state = .waiting
        return try? await host.nextTry(for: name)
    }

    private func close() {
        state = .closed
        surface.paneExited(code: nil, signal: nil)
    }

    private func runChannel(link: RemoteServers.Link, create: String?) async -> End {
        var launch: PaneSession.Launch?
        if let create {
            guard let made = await hosts.createLaunch(link: link, directory: create) else {
                return Task.isCancelled ? .done : .lost
            }
            guard !Task.isCancelled else { return .done }
            launch = made.launch
            if let note = made.note { surface.paneFeed(Data(Self.paneText(note).utf8)) }
        }
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
        return await withCheckedContinuation { ending = $0 }
    }

    private func runPlain(_ arguments: [String]) async -> End {
        let shell = PlainShell(arguments: arguments, grid: surface.paneGrid(), host: surface) { [weak self] status in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.plainExited(status) } }
        }
        guard let shell else {
            surface.paneFeed(Data(Self.paneText("Macterm cannot start ssh.").utf8))
            return .nothing
        }
        state = .plain(shell)
        return await withCheckedContinuation { ending = $0 }
    }

    private func plainExited(_ status: Int32) {
        guard case .plain = state else { return }
        // ssh exits 255 when the connection stops: the pane waits. Any other
        // status is the shell's: the pane ends.
        let code = (status >> 8) & 0xFF
        if code == 255 {
            end(.lost)
        } else {
            state = .closed
            surface.paneExited(code: UInt8(truncatingIfNeeded: code), signal: nil)
            end(.done)
        }
    }

    /// The session or the plain shell that runs ended.
    private func end(_ end: End) {
        guard let ending else { return }
        self.ending = nil
        ending.resume(returning: end)
    }

    fileprivate func sessionAttached() {
        attached = true
        host?.sessionAttached(name, pane: pane)
    }

    /// The connection stopped: the pane is lost and waits for a try.
    fileprivate func linkStopped() {
        logger.info("remote pane: session=\(self.name, privacy: .public) link stopped")
        end(.lost)
    }

    fileprivate func sessionExited() {
        end(.done)
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
        if case .closed = state { return }
        state = .waiting
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

    nonisolated func seen() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.currentRoute()?.seen() } }
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
            // The key connects at once. Its bytes wait only for a first
            // session, never in a lost pane.
            if !isLost { keep(data) }
            host?.retry(name)
        case .connecting:
            // The `initial_input` of a layout, written while the surface
            // starts, or a key during the connect: it goes to the session
            // when one runs. A key lets the connect ask for the login.
            if !isLost { keep(data) }
            host?.retry(name)
        case .closed: break
        }
    }

    /// A key that the running session could not send: the link is down. The
    /// key is dropped, and asks to connect, as a key in a lost pane does.
    fileprivate func keyFoundLinkDown() {
        end(.keyFoundLinkDown)
    }

    private var isLost: Bool {
        host?.isLost(name) ?? false
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
    /// surface, and the end of the channel goes to the driver. A report counts
    /// only from the driver's running session: an old session must not stop
    /// a new one.
    private final class Forward: PaneSessionHost, @unchecked Sendable {
        private weak var driver: RemotePaneDriver?
        private let surface: any PaneSessionHost
        /// Set once, on the main actor, before the session starts.
        weak var session: PaneSession?

        init(driver: RemotePaneDriver, surface: any PaneSessionHost) {
            self.driver = driver
            self.surface = surface
        }

        /// Runs `body` on the main actor, for the driver's running session only.
        private func onDriver(_ body: @escaping @MainActor (RemotePaneDriver) -> Void) {
            DispatchQueue.main.async { [weak driver, self] in
                MainActor.assumeIsolated {
                    guard let driver, case let .running(running) = driver.state, let session, running === session else { return }
                    body(driver)
                }
            }
        }

        func paneFeed(_ data: Data) {
            surface.paneFeed(data)
        }

        func paneGrid() -> PaneGrid {
            surface.paneGrid()
        }

        func paneTitle(_ title: Data) {
            surface.paneTitle(title)
        }

        func paneCwd(_ url: Data) {
            surface.paneCwd(url)
        }

        func paneMark(_ mark: MactermProtocol.Mark) {
            surface.paneMark(mark)
        }

        func paneStatus(_ status: MactermProtocol.Status) {
            surface.paneStatus(status)
        }

        func paneLead(_ leader: Bool?) {
            surface.paneLead(leader)
            // The session tells each client that attached whether it leads:
            // the session runs on the host.
            guard leader != nil else { return }
            onDriver { $0.sessionAttached() }
        }

        func paneForeground(_ foreground: MactermProtocol.Foreground) {
            surface.paneForeground(foreground)
        }

        func paneTtyMode(_ mode: MactermProtocol.TtyMode) {
            surface.paneTtyMode(mode)
        }

        func paneAttention(_ flags: MactermProtocol.Attention) {
            surface.paneAttention(flags)
        }

        func paneExited(code: UInt8?, signal: UInt8?) {
            surface.paneExited(code: code, signal: signal)
            onDriver { $0.sessionExited() }
        }

        func paneLinkLost() {
            onDriver { $0.linkStopped() }
        }

        func paneInputUndelivered(_: Data) {
            onDriver { $0.keyFoundLinkDown() }
        }

        func paneGone() {
            paneLinkLost()
        }
    }
}
