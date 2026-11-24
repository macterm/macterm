import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteHost")

/// One remote host, by its ssh destination (0264, design/005). It is the one
/// owner of the host's state. It keeps:
///
/// - the login, the check and the install;
/// - the link to the host's server, and its roaming link;
/// - the plain shells of a host with no server;
/// - the sessions of the host's panes;
/// - one backoff for the automatic tries.
///
/// - **One state** (`State`). The panes read it: `Pane.isRemoteLinkLost` and
///   `Pane.isRemoteReconnecting` come from the session table, not from a
///   copy that something must keep in step.
/// - **A pane asks with `await`** (`attachment(for:pane:directory:prompts:)`). A login
///   or an install can wait minutes for the user: the call waits with it,
///   and every pane of the host waits for the same login. Task cancellation
///   ends a wait.
/// - **A lost pane waits for the host** (`nextTry(for:)`): a trigger of the
///   app (`reconnect`), after the host's backoff, or a key (`retry`).
/// - **One backoff for each host** (`RemoteReconnectPolicy`): the failure is
///   the host's, so N lost panes of one host make one streak.
/// - **The link pings its server** (`LinkHeartbeat`, every 3 s): a link
///   that does not answer closes, and its panes are lost in seconds.
@MainActor @Observable
final class RemoteHost {
    enum State {
        /// No connection, and no try runs.
        case idle
        case loggingIn
        /// The login is up: the host's server is checked, and connected.
        case checking
        /// The host has no server of this build: the user is asked to allow
        /// the install.
        case awaitingConsent
        case installing
        case ready(RemoteServers.Link)
        /// No server: each pane is a plain ssh shell over the login.
        case plain(SSHConnections.Route)
        /// The last try failed. The next automatic try waits for the
        /// backoff (`nextTryAt`).
        case unreachable(reason: String)

        var isTrying: Bool {
            switch self {
            case .loggingIn,
                 .checking,
                 .awaitingConsent,
                 .installing: true
            case .idle,
                 .ready,
                 .plain,
                 .unreachable: false
            }
        }
    }

    /// A step of a connect, which the state shows.
    enum Step {
        case loggingIn
        case checking
        case awaitingConsent
        case installing

        var state: State {
            switch self {
            case .loggingIn: .loggingIn
            case .checking: .checking
            case .awaitingConsent: .awaitingConsent
            case .installing: .installing
            }
        }
    }

    /// What a pane runs.
    enum Attachment {
        /// A channel to the session on the host's link. `create`: the
        /// session does not run: make it in this folder first.
        case channel(RemoteServers.Link, create: String?)
        /// No server on the host: a plain ssh shell (`ssh` arguments).
        case plain(arguments: [String])
        /// The session is gone from the host: the pane closes.
        case ended
    }

    /// What a connect gives.
    enum Opened {
        case link(RemoteServers.Link)
        case plain(SSHConnections.Route)
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The host cannot be reached now. The pane is lost.
        case unreachable(String)
        /// The bundle has no host scripts, or the folder is too long for one
        /// argument.
        case noPlainShell

        var description: String {
            switch self {
            case let .unreachable(reason): reason
            case .noPlainShell: "no plain shell for this folder"
            }
        }
    }

    /// What the host knows of one session of its panes.
    struct SessionState: Equatable {
        /// The connection stopped, or the last try failed. Never persisted.
        var lost = false
        /// A try runs now for a lost pane, or a slow first connect runs.
        var reconnecting = false
        /// When the app told a client to make it. A second client of the
        /// same pane (in a second window) can ask before the host lists the
        /// new session, and a channel can drop before the session starts: in
        /// this time a missing session is made, not reported as gone.
        var created: Date?
        /// The folder of a session that the app told a client to make, until
        /// the session attaches.
        var creating: String?
    }

    let destination: String
    private(set) var state: State = .idle {
        didSet {
            switch state {
            case .plain: if !isPlain { isPlain = true }
            case .ready: if isPlain { isPlain = false }
            default: break
            }
        }
    }

    /// The host's panes are plain ssh shells: the user declined the server,
    /// or the host has no build. It stays while the connection is down,
    /// until a link to the server is ready.
    private(set) var isPlain = false
    /// The roaming link hears nothing from the host now
    /// (`LinkTransport.isQuiet`). The link stays and its panes keep their
    /// channels, but the host cannot be reached.
    private(set) var isQuiet = false
    private(set) var sessions: [String: SessionState] = [:]

    @ObservationIgnored private unowned let owner: RemoteHosts
    /// The connect that runs. The token tells it from a later one.
    /// `prompts`: the login may ask the user.
    @ObservationIgnored private var opening: (token: UUID, prompts: Bool)?
    @ObservationIgnored private let opened = AsyncSignal<Void>()
    @ObservationIgnored private var tries: [String: AsyncSignal<Bool>] = [:]
    @ObservationIgnored private(set) var backoff = RemoteReconnectPolicy()
    /// Lists that failed on the current link, in a row.
    @ObservationIgnored private var listFailures = 0
    /// The roaming link (design/009), and the ssh link that it replaced as
    /// the host's link. Panes that attached over the ssh link stay on it
    /// until it ends.
    @ObservationIgnored private var transport: LinkTransport?
    @ObservationIgnored private var standby: RemoteServers.Link?
    /// Tells a late event of an older roaming link from the current one.
    @ObservationIgnored private var roamingGeneration = 0

    init(destination: String, owner: RemoteHosts) {
        self.destination = destination
        self.owner = owner
    }

    private var configuration: RemoteHosts.Configuration { owner.configuration }

    /// The host's link to its server, when it is up.
    var link: RemoteServers.Link? {
        if case let .ready(link) = state { link } else { nil }
    }

    /// The time of the next automatic try. nil: a try may start now.
    var nextTryAt: Date? {
        backoff.nextAttempt
    }

    func isLost(_ session: String) -> Bool {
        sessions[session]?.lost ?? false
    }

    func isReconnecting(_ session: String) -> Bool {
        sessions[session]?.reconnecting ?? false
    }

    // MARK: - A pane

    /// What the pane runs now. It waits for a login, a check or an install
    /// that runs, and starts one when the host has no connection. `prompts`:
    /// the connect may ask the user (a login, the install). Only a pane's
    /// own start and a key in it may; an automatic try may not. Throws
    /// `Failure.unreachable` when the host cannot be reached: the pane is
    /// lost and waits for `nextTry(for:)`.
    func attachment(for session: String, pane: Pane, directory: String, prompts: Bool) async throws -> Attachment {
        while true {
            try Task.checkCancellation()
            switch state {
            case .idle,
                 .unreachable:
                open(prompts: prompts)
                try await waitForOpen(session, pane: pane)
            case .loggingIn,
                 .checking,
                 .awaitingConsent,
                 .installing:
                // A quiet try cannot answer a key: a key logs in itself.
                if prompts, opening?.prompts == false { open(prompts: true) }
                try await waitForOpen(session, pane: pane)
            case let .plain(route):
                settle(session, lost: false)
                guard let command = configuration.scripts?.plainCommand(directory: directory) else {
                    throw Failure.noPlainShell
                }
                return .plain(arguments: owner.connections.ttyArguments(route, destination, command))
            case let .ready(link):
                if let answer = try await decide(session, pane: pane, directory: directory, link: link) {
                    return answer
                }
            }
        }
    }

    /// Waits until the connect that runs ends. Throws when it failed.
    private func waitForOpen(_ session: String, pane: Pane) async throws {
        if opening != nil { try await opened.wait() }
        if case let .unreachable(reason) = state {
            lose(session, pane: pane)
            throw Failure.unreachable(reason)
        }
    }

    private func decide(_ session: String, pane: Pane, directory: String, link: RemoteServers.Link) async throws -> Attachment? {
        guard configuration.key != nil else { return .ended }
        guard let listed = await link.list() else {
            try Task.checkCancellation()
            // A roaming link whose transport still runs is waiting for the
            // network: the next trigger asks again. Only a dead transport
            // drops it (`roamingEnded`).
            if link.isRoaming, link.connection.isOpen, self.link === link {
                backoff.tryFailed(now: Date())
                lose(session, pane: pane)
                throw Failure.unreachable("the roaming link did not answer")
            }
            // The link broke. Only a failure on the host's current link
            // counts, and drops it: another request may have made a new one
            // meanwhile. Two failures in a row are the host's answer.
            guard self.link === link else { return nil }
            drop()
            listFailures += 1
            guard listFailures < 2 else {
                listFailures = 0
                backoff.tryFailed(now: Date())
                lose(session, pane: pane)
                throw Failure.unreachable("the host's server did not list its sessions")
            }
            return nil
        }
        try Task.checkCancellation()
        listFailures = 0
        // A session whose shell exited: the list read its status, so the
        // host's server ends it, and a create replaces it.
        let found = listed.first { $0.name == session }
        var entry = sessions[session] ?? SessionState()
        // A reported folder with a control character, or a relative one, gives the project folder.
        let known = pane.hostSessionDirectory.map { HostCommands.isSafeHostFolder($0) ? $0 : directory }
        let justCreated = entry.created.map { Date().timeIntervalSince($0) < configuration.creationGrace } ?? false
        if found?.isRunning == true { entry.created = nil }
        let step = RemoteHosts.step(
            running: found?.isRunning == true,
            // A second client makes the session in the folder of the first create.
            sessionDirectory: justCreated ? known ?? entry.creating : known,
            justCreated: justCreated,
            projectDirectory: directory
        )
        switch step {
        case .attach:
            sessions[session] = entry
            settle(session, lost: false)
            if pane.hostSessionDirectory == nil { pane.hostSessionDirectory = directory }
            return .channel(link, create: nil)
        case let .create(folder):
            entry.created = Date()
            // The folder counts only when the session attaches
            // (`sessionAttached`): a create that fails must not make the
            // pane close later as gone.
            entry.creating = folder
            sessions[session] = entry
            settle(session, lost: false)
            return .channel(link, create: folder)
        case .gone:
            logger
                .info("remote pane: session=\(session, privacy: .public) is gone on \(self.destination, privacy: .public), the pane closes")
            forget(session)
            return .ended
        }
    }

    /// The session of this pane attached: it ran on the host, so from now
    /// on a missing session is gone and closes the pane.
    func sessionAttached(_ session: String, pane: Pane?) {
        let folder = sessions[session]?.creating
        sessions[session]?.creating = nil
        // No try runs now. A slow first connect can mark the pane after the
        // attachment (`firstConnectIsSlow`).
        if sessions[session]?.lost == false, sessions[session]?.reconnecting == true {
            sessions[session]?.reconnecting = false
        }
        guard let pane, pane.hostSessionDirectory == nil, let folder = folder ?? RemoteHosts.Target(pane)?.directory else { return }
        pane.hostSessionDirectory = folder
    }

    /// The pane's connection stopped: its channel ended with no exit, or its
    /// plain ssh exited 255. The pane is lost and waits for `nextTry(for:)`.
    func lost(_ session: String, pane: Pane?) {
        logger.info("remote pane: session=\(session, privacy: .public) host=\(self.destination, privacy: .public) lost")
        lose(session, pane: pane)
        // The next connect checks the connection again. A link that is still
        // open stays: a later connect made it, or the roaming link still
        // runs (`decide` drops it when it does not answer).
        switch state {
        case let .ready(link) where !link.connection.isOpen:
            drop()
        case .plain:
            drop()
        default:
            break
        }
    }

    /// Waits for the next try of a lost pane: a trigger of the app after the
    /// host's backoff (false), or a key in a view of the pane (true: the
    /// connect may ask the user).
    func nextTry(for session: String) async throws -> Bool {
        let signal = tries[session] ?? AsyncSignal<Bool>()
        tries[session] = signal
        return try await signal.wait()
    }

    /// The views of the session that wait for its next try now.
    func waiterCount(for session: String) -> Int {
        tries[session]?.count ?? 0
    }

    /// A key in a pane that waits: connect at once, and the login may ask.
    /// Every view of the pane tries.
    func retry(_ session: String) {
        if sessions[session]?.lost == true, sessions[session]?.reconnecting == false {
            sessions[session]?.reconnecting = true
        }
        tries[session]?.fire(true)
        if opening?.prompts == false { open(prompts: true) }
    }

    /// The sweep of the app (a trigger: wake, a network change, activation,
    /// a project selection, a pane that became lost, a login, the host that
    /// answers again). After the host's backoff, its lost panes try again.
    /// Such a try never asks the user anything. `answered`: the host
    /// answers again, which clears the backoff.
    func reconnect(answered: Bool, now: Date) {
        let lost = sessions.filter { $0.value.lost && !$0.value.reconnecting }.map(\.key)
        guard !lost.isEmpty else { return }
        if answered { backoff.clear() }
        // A try runs now: its end decides.
        guard !state.isTrying, backoff.shouldAttempt(now: now) else { return }
        var woken = 0
        for session in lost {
            guard let signal = tries[session], !signal.isEmpty else { continue }
            sessions[session]?.reconnecting = true
            signal.fire(false)
            woken += 1
        }
        guard woken > 0 else { return }
        backoff.recordAttempt(now: now)
        logger.info("remote host \(self.destination, privacy: .public): \(woken, privacy: .public) lost pane(s) try again")
    }

    /// The first connect of a pane whose session ran on the host (a pane
    /// that came back after a restart) runs long: the badge says
    /// `Reconnecting` until the session attaches or the connect fails. A new
    /// pane shows nothing, because its first connect can wait for a login
    /// question. A host whose link is ready connects no more: another view
    /// of the pane (a second window) can show it live.
    func firstConnectIsSlow(_ session: String, pane: Pane) {
        guard pane.hostSessionDirectory != nil, !isLost(session), !isReconnecting(session), link == nil else { return }
        logger.info("remote pane: session=\(session, privacy: .public) first connect is slow")
        sessions[session, default: SessionState()].reconnecting = true
    }

    /// The pane closed for good.
    func forget(_ session: String) {
        sessions[session] = nil
        tries[session] = nil
    }

    /// `lost`: no try runs now, and the badge says `Connection Lost`. Not
    /// lost: the session attaches. Either way a try ended.
    private func settle(_ session: String, lost: Bool) {
        var entry = sessions[session] ?? SessionState()
        if entry.lost != lost {
            logger.info("remote pane: session=\(session, privacy: .public) isRemoteLinkLost=\(lost, privacy: .public)")
            entry.lost = lost
        }
        entry.reconnecting = false
        if sessions[session] != entry { sessions[session] = entry }
    }

    private func lose(_ session: String, pane: Pane?) {
        settle(session, lost: true)
        // A lost pane reads no tty mode: its last one is stale.
        pane?.lineMode = nil
        configuration.hostLost(destination)
    }

    /// Sets the link state of a session. For tests of what reads it.
    func setLinkState(of session: String, lost: Bool, reconnecting: Bool) {
        sessions[session, default: SessionState()].lost = lost
        sessions[session, default: SessionState()].reconnecting = reconnecting
    }

    // MARK: - The connect

    /// Log in, then check and install the server. The end wakes the panes
    /// that wait. With `prompts` false, nothing asks the user: no login
    /// question, no install, no plain shell.
    private func open(prompts: Bool) {
        let token = UUID()
        opening = (token, prompts)
        state = .loggingIn
        let destination = destination
        let step: @MainActor (Step) -> Void = { [weak self] step in
            self?.show(step, of: token)
        }
        let connect = configuration.open ?? { [weak self] destination, prompts, step in
            guard let self else { throw CancellationError() }
            return try await connectLive(destination, prompts: prompts, step: step)
        }
        Task { [weak self] in
            let result: Result<Opened, Error>
            do {
                result = try await .success(connect(destination, prompts, step))
            } catch {
                logger.info("remote host \(destination, privacy: .public): \(String(describing: error), privacy: .public)")
                result = .failure(error)
            }
            guard let self else {
                if case let .success(.link(link)) = result { link.close() }
                return
            }
            finish(token, result)
        }
    }

    /// A step of the connect `token`, when it is still the current one.
    private func show(_ step: Step, of token: UUID) {
        guard opening?.token == token else { return }
        state = step.state
    }

    private func connectLive(_ destination: String, prompts: Bool, step: @escaping @MainActor (Step) -> Void) async throws -> Opened {
        let route = try await owner.connections.connect(destination, prompts: prompts)
        step(.checking)
        do {
            let link = try await owner.servers.connect(
                destination, login: prompts, install: prompts && !owner.declined.contains(destination), step: step
            )
            return .link(link)
        } catch let failure as RemoteServers.Failure {
            // A quiet try leaves the choice of plain shells to the user.
            guard prompts else { throw failure }
            switch failure {
            case .declined:
                owner.decline(destination)
                return .plain(route)
            case .notInstalled,
                 .noWritableHome,
                 .unsupported,
                 .noBuild,
                 .notBundled:
                logger.info("remote host \(destination, privacy: .public): plain shells: \(failure.description, privacy: .public)")
                return .plain(route)
            default:
                // `.windowsHost` ends here on purpose: the plain-shell command is POSIX.
                throw failure
            }
        }
    }

    private func finish(_ token: UUID, _ result: Result<Opened, Error>) {
        guard opening?.token == token else {
            // A later connect replaced this one (a key, an install from
            // Settings). Its waiting panes wait for that one.
            if case let .success(.link(link)) = result { link.close() }
            return
        }
        opening = nil
        switch result {
        case let .success(.link(link)):
            listFailures = 0
            backoff.clear()
            state = .ready(link)
            // One login serves every pane of the host. The sweep owns when a
            // lost pane connects again, so this never loops.
            configuration.hostDidConnect(destination)
            configuration.linkReady(destination, link)
            adoptRoaming(over: link)
        case let .success(.plain(route)):
            backoff.clear()
            state = .plain(route)
            configuration.hostDidConnect(destination)
        case let .failure(error):
            backoff.tryFailed(now: Date())
            state = .unreachable(reason: String(describing: error))
        }
        opened.fire(())
    }

    /// Waits for a connect that may ask the user (a new project's folder
    /// check). The state after it says what came of it.
    func connectAsking() async {
        switch state {
        case .idle,
             .unreachable:
            open(prompts: true)
        case .loggingIn,
             .checking,
             .awaitingConsent,
             .installing:
            if opening?.prompts == false { open(prompts: true) }
        case .ready,
             .plain:
            return
        }
        // Another step (an install from Settings) can replace this connect:
        // wait for the one that is current.
        while opening != nil {
            do { try await opened.wait() } catch { return }
        }
    }

    /// Install the server on a host where the user declined it, after the
    /// user's click. New panes then get sessions; a plain shell stays plain.
    /// A second decline keeps the host plain.
    func installServer() async throws {
        owner.undecline(destination)
        while opening != nil {
            try await opened.wait()
        }
        drop()
        let token = UUID()
        opening = (token, true)
        state = .loggingIn
        var failure: Error?
        do {
            let route = try await owner.connections.connect(destination)
            if opening?.token == token { state = .checking }
            do {
                let link = try await owner.servers.connect(destination, step: { [weak self] step in
                    self?.show(step, of: token)
                })
                if opening?.token == token {
                    backoff.clear()
                    state = .ready(link)
                    configuration.linkReady(destination, link)
                    adoptRoaming(over: link)
                } else {
                    link.close()
                }
            } catch RemoteServers.Failure.declined {
                owner.decline(destination)
                if opening?.token == token { state = .plain(route) }
                failure = RemoteServers.Failure.declined
            }
        } catch {
            if opening?.token == token { state = .idle }
            failure = error
        }
        if opening?.token == token {
            opening = nil
            opened.fire(())
        }
        if let failure { throw failure }
    }

    /// Forget the host's link: the next pane checks the connection again.
    func drop() {
        switch state {
        case let .ready(link):
            link.close()
            state = .idle
            if link.isRoaming { endRoaming() }
        case .plain:
            state = .idle
        default:
            break
        }
    }

    // MARK: - The roaming link

    /// Opens a roaming link over the host's ssh link, in the background. If
    /// it works, it becomes the host's link: new attaches use it, and it
    /// survives sleep and a new network. The ssh link stays for the panes that
    /// attached over it. A host that cannot do it keeps the ssh link.
    private func adoptRoaming(over ssh: RemoteServers.Link) {
        let connections = owner.connections
        let enabled = configuration.roamingEnabled()
        roamingGeneration += 1
        let generation = roamingGeneration
        let destination = destination
        setQuiet(false)
        Task { [weak self] in
            let opened = await RoamingLink.open(
                destination: destination,
                over: ssh,
                connections: connections,
                enabled: enabled,
                events: .init(
                    dead: { [weak self] in
                        Task { @MainActor in self?.roamingEnded(generation: generation) }
                    },
                    quiet: { [weak self] in
                        Task { @MainActor in self?.roamingQuiet(generation: generation) }
                    },
                    answered: { [weak self] in
                        Task { @MainActor in self?.roamingAnswered(generation: generation) }
                    }
                )
            )
            guard let self, let opened else { return }
            // The host may have changed while the link opened.
            guard link === ssh, roamingGeneration == generation else {
                opened.link.close()
                opened.transport.stop()
                return
            }
            standby?.close()
            standby = ssh
            transport?.stop()
            transport = opened.transport
            state = .ready(opened.link)
            setQuiet(opened.transport.isQuiet)
        }
    }

    /// The roaming link of this generation stopped or started to hear the
    /// host. The state comes from the transport, not from the event, so
    /// events in a different order give the same result.
    private func roamingQuiet(generation: Int) {
        guard roamingGeneration == generation, let transport else { return }
        let quiet = transport.isQuiet
        logger.info("link: host=\(self.destination, privacy: .public) quiet=\(quiet, privacy: .public)")
        setQuiet(quiet)
    }

    /// The roaming link of this generation heard its host after a gap. A
    /// pane that went lost in the gap (on the ssh standby, or a try that
    /// failed on this link) has no other sign that the host is back.
    /// Without this, the backoff (up to 60 s) decides.
    private func roamingAnswered(generation: Int) {
        guard roamingGeneration == generation, transport != nil else { return }
        logger.info("link: host=\(self.destination, privacy: .public) answers again")
        configuration.hostAnswered(destination)
    }

    private func setQuiet(_ quiet: Bool) {
        if isQuiet != quiet { isQuiet = quiet }
    }

    /// The link ended by itself: no packet for a long time. The panes on it
    /// are lost, and the next connect uses ssh.
    private func roamingEnded(generation: Int) {
        guard roamingGeneration == generation, let link, link.isRoaming else { return }
        logger.info("link: host=\(self.destination, privacy: .public) ended")
        drop()
    }

    private func endRoaming() {
        roamingGeneration += 1
        setQuiet(false)
        transport?.stop()
        transport = nil
        standby?.close()
        standby = nil
    }

    /// The network changed or the Mac woke: the roaming link uses a new
    /// socket, so that its packets leave on the new path.
    func networkDidChange() {
        transport?.pathChanged()
    }
}

/// Wakes every task that waits, with one value. A waiting task that is
/// cancelled throws `CancellationError` at once.
@MainActor
final class AsyncSignal<Value: Sendable> {
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]

    var isEmpty: Bool {
        waiters.isEmpty
    }

    var count: Int {
        waiters.count
    }

    func wait() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func fire(_ value: Value) {
        let all = waiters
        waiters = [:]
        for continuation in all.values {
            continuation.resume(returning: value)
        }
    }
}
