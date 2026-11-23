import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemotePaneDriver")

/// What one remote pane does (0057, 0195, 0261, 0264): one task that asks
/// the pane's `RemoteHost` what to run, and runs it on the views of the
/// pane. There is one driver for each pane (its `PaneLink` owns it), so the
/// pane's state machine runs once, however many windows show the pane. Its
/// states:
///
/// - connecting: it waits for the host (`RemoteHost.attachment`): a login,
///   a check or an install that runs;
/// - running: the session runs on the host's link, and each view that is
///   ready has a `PaneSession` (its own channel, size and claim);
/// - plain: a `PlainShell`, a pty with ssh, for a host with no server. It
///   shows in one view only (`plainOwner`), because a pty is one terminal.
///   That view leads and the others do not, so a window that is not key
///   shows "Showing in another window" as for a session. A claim from
///   another view moves the shell there, with its screen replayed;
/// - waiting: the pane is lost, or it has nothing to run. It waits for the
///   host's next try (`RemoteHost.nextTry`): a trigger of the app after the
///   host's backoff, or a key.
///
/// A lost link ends the reading of every view and tells the host
/// (`RemoteHost.lost`): the pane shows its badge and its disabled cursor,
/// and waits. A session that is gone from the host closes the pane. `stop`
/// cancels the task, and every wait ends.
@MainActor
final class RemotePaneDriver {
    private enum State {
        case connecting
        case waiting
        case running(RemoteServers.Link)
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

    /// One view of the pane: a surface, or a test's host. It is the view's
    /// route for input, size and claims.
    final class View: PaneInputRoute, @unchecked Sendable {
        let host: any PaneSessionHost
        fileprivate weak var driver: RemotePaneDriver?
        /// Read and written on the main actor.
        fileprivate var ready = false
        fileprivate var session: PaneSession?

        fileprivate init(host: any PaneSessionHost, driver: RemotePaneDriver) {
            self.host = host
            self.driver = driver
        }

        /// The view has its surface: it can show the session.
        @MainActor
        func start() {
            driver?.viewReady(self)
        }

        /// The view goes. The session keeps running.
        @MainActor
        func stop() {
            driver?.removeView(self)
        }

        nonisolated func sendInput(_ data: Data) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.driver?.route(data, from: self) } }
        }

        nonisolated func claim(grid: PaneGrid?) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.driver?.claim(grid: grid, from: self) } }
        }

        nonisolated func sendSize(_ grid: PaneGrid?) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.driver?.inputRoute(of: self)?.sendSize(grid) } }
        }

        nonisolated func seen() {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.driver?.inputRoute(of: self)?.seen() } }
        }
    }

    let name: String
    private let hosts: RemoteHosts
    private var state = State.connecting
    private var task: Task<Void, Never>?
    private weak var pane: Pane?
    private var host: RemoteHost?
    /// The views, in the order they came. Only a ready view shows a session.
    private var views: [View] = []
    /// The view that shows the plain shell.
    private weak var plainOwner: View?
    /// The plain shell's output, for its owner, and the log that replays
    /// its screen in the next owner.
    private let plainOutput = PlainOutput()
    /// The end of the session or the plain shell that runs.
    private var ending: CheckedContinuation<End, Never>?
    /// Input that waits for the first session: a layout's `initial_input`,
    /// and keys typed before the first connect ends. The next view session
    /// that starts sends it. A pane that runs plain drops it, because it was
    /// for another session. Keys typed while the pane is lost are dropped,
    /// by decision (Ethan, 2026-11-16, option C): they were typed at a stale
    /// screen.
    private var earlyInput = Data()
    /// Input of a session that never attached, in order. It goes before
    /// `earlyInput`.
    private var undelivered = Data()
    /// The session attached at least once in this run.
    private var attached = false
    /// The session told a client of this running state that it attached.
    private var runAttached = false
    /// After this time with no attach, the first connect is slow
    /// (`RemoteHost.firstConnectIsSlow`).
    private let slowConnectAfter: Duration

    /// A connect to a host whose server does not answer runs until the
    /// handshake gives up (15 s, `RemoteServers.Configuration.handshakeTimeout`).
    /// A login that is slower than this time shows the badge too.
    static let slowConnectAfter: Duration = .seconds(3)

    init(
        name: String,
        hosts: RemoteHosts = .shared,
        slowConnectAfter: Duration = RemotePaneDriver.slowConnectAfter
    ) {
        self.name = name
        self.hosts = hosts
        self.slowConnectAfter = slowConnectAfter
    }

    /// Adds a view of the pane. It shows nothing until `View.start`.
    func addView(_ host: any PaneSessionHost) -> View {
        let view = View(host: host, driver: self)
        views.append(view)
        return view
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

    // MARK: - Views

    private func viewReady(_ view: View) {
        guard !view.ready, views.contains(where: { $0 === view }) else { return }
        view.ready = true
        switch state {
        case let .running(link): startSession(of: view, on: link)
        case .plain: showPlain(in: view)
        default: break
        }
    }

    private func removeView(_ view: View) {
        guard let index = views.firstIndex(where: { $0 === view }) else { return }
        views.remove(at: index)
        view.ready = false
        if let session = view.session {
            view.session = nil
            session.stop()
            let kept = session.takePendingInput()
            if !kept.isEmpty { undelivered.append(kept) }
        }
        if plainOwner === view {
            plainOwner = nil
            if case let .plain(shell) = state, let next = views.first(where: \.ready) {
                hand(shell, to: next)
            } else {
                plainOutput.retarget(nil)
            }
        }
    }

    /// Whether the plain shell shows in the view of `host`. nil when the
    /// pane runs no plain shell.
    func showsPlainShell(in host: any PaneSessionHost) -> Bool? {
        guard case .plain = state else { return nil }
        return plainOwner?.host === host
    }

    /// Every view, for what the pane shows in all of them.
    private func each(_ body: (any PaneSessionHost) -> Void) {
        for view in views {
            body(view.host)
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
                    each { $0.paneFeed(Data(Self.paneText(RemotePaneText.noPlainShell).utf8)) }
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
        each { $0.paneExited(code: nil, signal: nil) }
    }

    private func runChannel(link: RemoteServers.Link, create: String?) async -> End {
        if let create {
            guard let made = await hosts.createLaunch(link: link, directory: create) else {
                return Task.isCancelled ? .done : .lost
            }
            guard !Task.isCancelled else { return .done }
            if let note = made.note { each { $0.paneFeed(Data(Self.paneText(note).utf8)) } }
            // The one create of the pane: every view attaches to it.
            do {
                let grid = views.first(where: \.ready)?.host.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
                try await PaneSession.create(on: link.connection, name: name, launch: made.launch, grid: grid)
            } catch {
                let reason = String(describing: error)
                logger.info("remote pane: session=\(self.name, privacy: .public) create failed: \(reason, privacy: .public)")
                return Task.isCancelled ? .done : .lost
            }
            guard !Task.isCancelled else { return .done }
        }
        state = .running(link)
        runAttached = false
        for view in views where view.ready {
            startSession(of: view, on: link)
        }
        return await withCheckedContinuation { ending = $0 }
    }

    /// Starts the channel of one view on the host's link. The first session
    /// to start takes the input that waits.
    private func startSession(of view: View, on link: RemoteServers.Link) {
        guard view.session == nil else { return }
        let forward = Forward(driver: self, view: view)
        let session = PaneSession(
            name: name, wantsForeground: true, wantsTty: true, reconnects: false, missingIsExit: false,
            host: forward,
            connect: { link.connection }
        )
        forward.session = session
        view.session = session
        session.start()
        let waiting = undelivered + earlyInput
        undelivered = Data()
        earlyInput = Data()
        if !waiting.isEmpty { session.sendInput(waiting) }
    }

    private func runPlain(_ arguments: [String]) async -> End {
        let grid = views.first(where: \.ready)?.host.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
        let shell = PlainShell(arguments: arguments, grid: grid, host: plainOutput) { [weak self] status in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.plainExited(status) } }
        }
        guard let shell else {
            each { $0.paneFeed(Data(Self.paneText("Macterm cannot start ssh.").utf8)) }
            return .nothing
        }
        plainOutput.clearLog()
        state = .plain(shell)
        for view in views where view.ready {
            showPlain(in: view)
        }
        return await withCheckedContinuation { ending = $0 }
    }

    /// The plain shell shows in its owner only. Any other view starts clear
    /// and does not lead, as a client of a session that another window
    /// leads: the app shows the same notice.
    private func showPlain(in view: View) {
        guard case let .plain(shell) = state else { return }
        if plainOwner == nil {
            hand(shell, to: view)
        } else if plainOwner !== view {
            view.host.paneFeed(PaneSession.resetScreen)
            view.host.paneLead(false)
        }
    }

    /// `view` shows the plain shell from now on: its screen is the shell's
    /// output again (`PlainOutput.retarget`), it leads, and the pty takes
    /// its size.
    private func hand(_ shell: PlainShell, to view: View) {
        let previous = plainOwner
        plainOwner = view
        plainOutput.retarget(view.host)
        if let previous, previous !== view {
            previous.host.paneFeed(PaneSession.resetScreen)
            previous.host.paneLead(false)
        }
        view.host.paneLead(true)
        shell.sendSize(view.host.paneGrid())
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
            each { $0.paneExited(code: UInt8(truncatingIfNeeded: code), signal: nil) }
            end(.done)
        }
    }

    /// The session or the plain shell that runs ended.
    private func end(_ end: End) {
        guard let ending else { return }
        self.ending = nil
        ending.resume(returning: end)
    }

    private func sessionAttached() {
        attached = true
        guard !runAttached else { return }
        runAttached = true
        host?.sessionAttached(name, pane: pane)
    }

    /// The connection stopped: the pane is lost and waits for a try.
    private func linkStopped() {
        logger.info("remote pane: session=\(self.name, privacy: .public) link stopped")
        end(.lost)
    }

    private func sessionExited() {
        end(.done)
    }

    private func teardown() {
        switch state {
        case .running:
            for view in views {
                guard let session = view.session else { continue }
                view.session = nil
                session.stop()
                // Input that never reached a channel waits for the next session.
                undelivered.append(session.takePendingInput())
            }
        case let .plain(shell):
            shell.terminate()
            plainOwner = nil
            plainOutput.retarget(nil)
            plainOutput.clearLog()
            // No view leads a shell that is gone.
            each { $0.paneLead(nil) }
        default: break
        }
        if case .closed = state { return }
        state = .waiting
    }

    // MARK: - Input

    /// Where a view's size, claims and `seen` go now: its session, or the
    /// plain shell when the view shows it.
    private func inputRoute(of view: View) -> (any PaneInputRoute)? {
        switch state {
        case .running: view.session
        case let .plain(shell): plainOwner === view ? shell : nil
        default: nil
        }
    }

    /// A view claims, as the key window's surfaces do. A plain shell moves
    /// to a ready view that claims it; a session takes the claim itself.
    private func claim(grid: PaneGrid?, from view: View) {
        if case let .plain(shell) = state {
            if view.ready, plainOwner !== view { hand(shell, to: view) }
            return
        }
        inputRoute(of: view)?.claim(grid: grid)
    }

    private func route(_ data: Data, from view: View) {
        switch state {
        case .running:
            if let session = view.session {
                session.sendInput(data)
            } else {
                // The view has no channel yet: the next one that starts sends it.
                keep(data)
            }
        case let .plain(shell):
            // Only the view that shows the shell types into it: another
            // view's replies to the terminal's queries are not the shell's.
            if plainOwner === view { shell.sendInput(data) }
        case .waiting,
             .connecting:
            // The key connects at once, and the login may ask. Its bytes
            // wait only for a first session, never in a lost pane. In
            // `connecting` it can be the `initial_input` of a layout,
            // written while the surface starts.
            if !isLost { keep(data) }
            host?.retry(name)
        case .closed: break
        }
    }

    /// A key that the running session could not send: the link is down. The
    /// key is dropped, and asks to connect, as a key in a lost pane does.
    private func keyFoundLinkDown() {
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

    // MARK: - The plain shell's output

    /// The plain shell's output goes to the view that shows it. The target
    /// changes on the main actor; the shell reads on a queue of its own.
    ///
    /// A pty has no snapshot, so the output is also kept in a log: the next
    /// owner gets the log from a clear screen, and shows what the last owner
    /// showed. A log over `logLimit` keeps its last `logKept` bytes, so a
    /// long run replays its end only.
    private final class PlainOutput: PaneSessionHost, @unchecked Sendable {
        static let logLimit = 2 << 20
        static let logKept = 1 << 20

        private let lock = NSLock()
        private var target: (any PaneSessionHost)?
        private var log = Data()

        /// The output goes to `host` from now on, after the log. The lock
        /// keeps the order: no output comes between the log and the next.
        func retarget(_ host: (any PaneSessionHost)?) {
            lock.lock()
            defer { lock.unlock() }
            target = host
            guard let host else { return }
            host.paneFeed(PaneSession.resetScreen)
            if !log.isEmpty { host.paneFeed(log) }
        }

        func clearLog() {
            lock.lock()
            log = Data()
            lock.unlock()
        }

        func paneFeed(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            log.append(data)
            if log.count > Self.logLimit { log = Data(log.suffix(Self.logKept)) }
            target?.paneFeed(data)
        }

        func paneGrid() -> PaneGrid {
            lock.lock()
            defer { lock.unlock() }
            return target?.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
        }

        // A plain shell has no session: nothing reports these.
        func paneForeground(_: MactermProtocol.Foreground) {}
        func paneTtyMode(_: MactermProtocol.TtyMode) {}
        func paneExited(code _: UInt8?, signal _: UInt8?) {}
        func paneGone() {}
    }

    // MARK: - The session's host

    /// What a session of this driver reports: everything goes to its view,
    /// and the end of the channel goes to the driver. A report counts only
    /// from a session of the driver's running state: an old session must
    /// not stop a new one.
    private final class Forward: PaneSessionHost, @unchecked Sendable {
        private weak var driver: RemotePaneDriver?
        private let view: View
        private var surface: any PaneSessionHost { view.host }
        /// Set once, on the main actor, before the session starts.
        weak var session: PaneSession?

        init(driver: RemotePaneDriver, view: View) {
            self.driver = driver
            self.view = view
        }

        /// Runs `body` on the main actor, for a session of the driver's
        /// running state only.
        private func onDriver(_ body: @escaping @MainActor (RemotePaneDriver) -> Void) {
            DispatchQueue.main.async { [weak driver, self] in
                MainActor.assumeIsolated {
                    guard let driver, case .running = driver.state, let session, view.session === session else { return }
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
