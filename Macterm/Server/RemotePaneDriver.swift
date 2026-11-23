import Foundation
import notify
import os

private let logger = Logger(subsystem: appBundleID, category: "RemotePaneDriver")

/// What one remote pane does (0057, 0195, 0261): it asks `RemoteHosts` what
/// to do, and runs the answer on the views of the pane. There is one driver
/// for each pane (its `PaneLink` owns it), so the pane's state machine runs
/// once, however many windows show the pane. Its states:
///
/// - running: the session runs on the host's link, and each view that is
///   ready has a `PaneSession` (its own channel, size and claim);
/// - plain: a `PlainShell`, a pty with ssh, for a host with no server. It
///   shows in one view only (`plainOwner`), because a pty is one terminal;
///   the other views show one line that says so;
/// - waiting: no session yet. A wake (a login that ended, the reconnect
///   sweep) or a key asks again.
///
/// A lost link ends the reading of every view and asks `RemoteHosts` with
/// `lost`: the pane shows its badge and its disabled cursor, and waits.
/// The app's sweep (`AppState.reconnectDroppedRemotePanes`) owns the next
/// quiet try, and a key connects at once. A session that is gone from the
/// host closes the pane.
@MainActor
final class RemotePaneDriver {
    private enum State {
        case idle
        case waiting
        case running(RemoteServers.Link)
        case plain(PlainShell)
        case closed
    }

    /// One view of the pane: a surface, or a test's host. It is the view's
    /// route for input, size and claims.
    final class View: PaneInputRoute, @unchecked Sendable {
        let host: any PaneSessionHost
        fileprivate weak var driver: RemotePaneDriver?
        /// Read and written on the main actor.
        fileprivate var ready = false
        fileprivate var session: PaneSession?
        /// The view showed the line that the plain shell is in another view.
        fileprivate var toldPlainElsewhere = false

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
            DispatchQueue.main.async { MainActor.assumeIsolated { self.driver?.inputRoute(of: self)?.claim(grid: grid) } }
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
    private var state = State.idle
    /// The views, in the order they came. Only a ready view shows a session.
    private var views: [View] = []
    /// The view that shows the plain shell.
    private weak var plainOwner: View?
    /// The plain shell's output, for its owner.
    private let plainOutput = PlainOutput()
    /// Tells a late answer from a current one.
    private var generation = 0
    private var wakeToken: Int32 = NOTIFY_TOKEN_INVALID
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
    /// A key found the link down: connect at once after the `lost` answer.
    private var retryAfterLost = false
    /// The session attached at least once in this run.
    private var attached = false
    /// The session told a client of this running state that it attached.
    private var runAttached = false
    private var started = false
    /// After this time with no attach, the first connect is slow
    /// (`RemoteHosts.firstConnectIsSlow`).
    private let slowConnectAfter: Duration

    /// A connect to a host whose server does not answer runs until the
    /// handshake gives up (15 s, `RemoteServers.Configuration.handshakeTimeout`).
    /// A login that is slower than this time shows the badge too.
    static let slowConnectAfter: Duration = .seconds(3)

    /// The line of a view that does not show the pane's plain shell.
    static let plainElsewhereText = "macterm: this ssh shell shows in one window only."

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
        guard !started else { return }
        started = true
        registerWake()
        step(.ask)
        watchFirstConnect()
    }

    /// A pane that came back after a restart shows nothing while its first
    /// connect runs. When that connect is slow, the badge says so.
    private func watchFirstConnect() {
        Task { @MainActor [weak self, slowConnectAfter] in
            try? await Task.sleep(for: slowConnectAfter)
            guard let self, !attached else { return }
            switch state {
            case .idle,
                 .waiting: hosts.firstConnectIsSlow(hosts.pane?(name))
            case .running,
                 .plain,
                 .closed: break
            }
        }
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
                plainOutput.target = nil
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

    // MARK: - Steps

    private func step(_ event: RemotePaneEvent) {
        generation += 1
        let mine = generation
        Task { @MainActor in
            // A pane that restores before the app has installed its state
            // waits: no pane would read as "the pane closed".
            while hosts.pane == nil {
                try? await Task.sleep(for: .milliseconds(200))
                guard mine == generation else { return }
            }
            let answer = await hosts.answer(event, session: name, pane: hosts.pane?(name))
            guard mine == generation else { return }
            apply(answer, generation: mine)
        }
    }

    private func apply(_ answer: RemotePaneAnswer, generation mine: Int) {
        if case .closed = state { return }
        teardown()
        switch answer {
        case let .wait(message):
            if let message { each { $0.paneFeed(Data(Self.paneText(message).utf8)) } }
            state = .waiting
            if retryAfterLost {
                retryAfterLost = false
                step(.retry)
            }
        case .close:
            state = .closed
            each { $0.paneExited(code: nil, signal: nil) }
        case let .plain(arguments):
            earlyInput = Data()
            undelivered = Data()
            runPlain(arguments)
        case let .attach(link, create):
            attach(link: link, create: create, generation: mine)
        }
    }

    private func attach(link: RemoteServers.Link, create: String?, generation mine: Int) {
        Task { @MainActor in
            if let create {
                guard let made = await hosts.createLaunch(link: link, directory: create) else {
                    guard mine == generation else { return }
                    linkStopped()
                    return
                }
                guard mine == generation else { return }
                if let note = made.note { each { $0.paneFeed(Data(Self.paneText(note).utf8)) } }
                // The one create of the pane: every view attaches to it.
                do {
                    let grid = views.first(where: \.ready)?.host.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
                    try await PaneSession.create(on: link.connection, name: name, launch: made.launch, grid: grid)
                } catch {
                    let reason = String(describing: error)
                    logger.info("remote pane: session=\(self.name, privacy: .public) create failed: \(reason, privacy: .public)")
                    guard mine == generation else { return }
                    linkStopped()
                    return
                }
            }
            // A step that came after this answer owns the pane now.
            guard mine == generation else { return }
            state = .running(link)
            runAttached = false
            for view in views where view.ready {
                startSession(of: view, on: link)
            }
        }
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

    private func runPlain(_ arguments: [String]) {
        let mine = generation
        let owner = views.first(where: \.ready)
        let grid = owner?.host.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
        let shell = PlainShell(arguments: arguments, grid: grid, host: plainOutput) { [weak self] status in
            DispatchQueue.main.async { self?.plainExited(status, generation: mine) }
        }
        guard let shell else {
            each { $0.paneFeed(Data(Self.paneText("Macterm cannot start ssh.").utf8)) }
            state = .waiting
            return
        }
        state = .plain(shell)
        for view in views where view.ready {
            showPlain(in: view)
        }
    }

    /// The plain shell shows in its owner only. Any other view says so, once.
    private func showPlain(in view: View) {
        guard case let .plain(shell) = state else { return }
        if plainOwner == nil {
            hand(shell, to: view)
        } else if plainOwner !== view, !view.toldPlainElsewhere {
            view.toldPlainElsewhere = true
            view.host.paneFeed(PaneSession.resetScreen)
            view.host.paneFeed(Data(Self.paneText(Self.plainElsewhereText).utf8))
        }
    }

    /// `view` shows the plain shell from now on: its screen starts clear,
    /// and the pty takes its size.
    private func hand(_ shell: PlainShell, to view: View) {
        plainOwner = view
        view.toldPlainElsewhere = false
        view.host.paneFeed(PaneSession.resetScreen)
        plainOutput.target = view.host
        shell.sendSize(view.host.paneGrid())
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
            each { $0.paneExited(code: UInt8(truncatingIfNeeded: code), signal: nil) }
        }
    }

    private func sessionAttached() {
        attached = true
        guard !runAttached else { return }
        runAttached = true
        hosts.sessionAttached(name, pane: hosts.pane?(name))
    }

    /// The connection stopped: the pane is lost and waits for a try.
    private func linkStopped() {
        if case .closed = state { return }
        logger.info("remote pane: session=\(self.name, privacy: .public) link stopped")
        teardown()
        state = .waiting
        step(.lost)
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
            plainOutput.target = nil
            for view in views {
                view.toldPlainElsewhere = false
            }
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

    /// Where a view's size, claims and `seen` go now: its session, or the
    /// plain shell when the view shows it.
    private func inputRoute(of view: View) -> (any PaneInputRoute)? {
        switch state {
        case .running: view.session
        case let .plain(shell): plainOwner === view ? shell : nil
        default: nil
        }
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
        case .waiting:
            // The key connects at once. Its bytes wait only for a first
            // session, never in a lost pane.
            if !isLost { keep(data) }
            step(.retry)
        case .idle:
            // The `initial_input` of a layout, written while the surface
            // starts: it goes to the session when one runs.
            keep(data)
        case .closed: break
        }
    }

    /// A key that the running session could not send: the link is down. The
    /// key is dropped, and asks to connect, as a key in a lost pane does.
    private func keyFoundLinkDown() {
        retryAfterLost = true
        linkStopped()
    }

    private var isLost: Bool {
        hosts.pane?(name)?.isRemoteLinkLost ?? false
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
    private final class PlainOutput: PaneSessionHost, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any PaneSessionHost)?

        var target: (any PaneSessionHost)? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }

        func paneFeed(_ data: Data) {
            target?.paneFeed(data)
        }

        func paneGrid() -> PaneGrid {
            target?.paneGrid() ?? PaneGrid(cols: 80, rows: 24)
        }

        // A plain shell has no session: nothing reports these.
        func paneForeground(_: MactermProtocol.Foreground) {}
        func paneTtyMode(_: MactermProtocol.TtyMode) {}
        func paneExited(code _: UInt8?, signal _: UInt8?) {}
        func paneGone() {}
    }

    // MARK: - The session's host

    /// What a session of this driver reports: everything goes to its view,
    /// and a lost link goes to the driver. A report counts only from a
    /// session of the driver's running state: an old session must not stop
    /// a new one.
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

        @MainActor
        private func isCurrent(_ driver: RemotePaneDriver) -> Bool {
            guard case .running = driver.state, let session else { return false }
            return view.session === session
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

        func paneAttention(_ flags: MactermProtocol.Attention) {
            surface.paneAttention(flags)
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

        func paneInputUndelivered(_: Data) {
            DispatchQueue.main.async { [weak driver, self] in
                MainActor.assumeIsolated {
                    guard let driver, isCurrent(driver) else { return }
                    driver.keyFoundLinkDown()
                }
            }
        }

        func paneGone() {
            paneLinkLost()
        }
    }
}
