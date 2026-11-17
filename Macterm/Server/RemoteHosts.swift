import Foundation
import notify
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteHosts")

/// What a remote pane's client asks (`macterm remote-pane`, 0057).
enum RemotePaneEvent: String, Codable {
    /// What now: at the start, and after the app woke the client.
    case ask
    /// The pane's ssh exited 255: the connection stopped.
    case lost
    /// The user pressed a key in a pane that waits: connect now.
    case retry
}

/// The app's answer to a remote pane's driver (`RemotePaneDriver`).
enum RemotePaneAnswer {
    /// Wait for the wake notification or a key. `message` goes into the pane
    /// first.
    case wait(message: String?)
    /// Open a channel to the session on the host's link. `create`: the
    /// session does not run: make it in this folder first.
    case attach(link: RemoteServers.Link, create: String?)
    /// No server on the host: a plain ssh shell over the master (`ssh`
    /// arguments), after `message`.
    case plain(arguments: [String], message: String?)
    /// The pane ends: no pane has the session any more, or the session is
    /// gone from the host.
    case close
}

/// Each remote pane is a session of the host's server, reached over the
/// host's one ssh connection (0057). This type keeps, for each host, the
/// route of that connection and one link to the server (`RemoteServers.Link`),
/// and answers each pane's client (`macterm remote-pane`).
///
/// - **The interim shape.** The client runs on the pane's pty, as
///   `macterm attach` does for a local pane, until the GUI feeds a surface
///   from a channel (m3). It runs `ssh -S <master> -t <host> 'macterm-<key>
///   connect <name>'`: each pane is one ssh channel over the one connection,
///   so one login serves every pane. The link to the server lists and ends
///   sessions.
/// - **One request is short.** A login or an install can wait minutes for the
///   user, and the control socket has 16 connections. So `answer` never waits
///   for them: it starts the work and says `wait`; when the work ends, the
///   app posts the pane's Darwin notification (`wakeName`), and the client
///   asks again.
/// - **Lost.** A pane whose link stopped reports `lost`. The pane dims
///   (`Pane.isRemoteLinkLost`) under one line of Macterm's
///   (`RemotePaneText.linkStopped`) and waits for a trigger (wake, a network
///   change, activation, the project's selection; `AppState.
///   reconnectDroppedRemotePanes` with `RemoteReconnectPolicy`) or a key in
///   the pane. The attach after it replays the session's screen.
/// - **Gone.** A pane whose session ran on the host
///   (`Pane.hostSessionDirectory`) and is gone there (a host restart) closes:
///   the pane exists only while its session exists (Ethan, 2026-11-16). A
///   server is never started empty in silence for a pane that expects a
///   session. A pane from before v2 has no such folder: its first session
///   starts with no question, as local panes did at the cut-over.
/// - **No server.** When the user declined the install, or the host has no
///   build, each pane is a plain ssh shell, with one line that says so. The
///   decline is kept (`declined`); Settings → Projects offers the install
///   again.
/// - v1 sessions on a host keep running: nothing here ends one.
@MainActor @Observable
final class RemoteHosts {
    struct Configuration {
        /// The build key of the bundled server.
        var key: String?
        /// Posts a Darwin notification.
        var post: (String) -> Void = { notify_post($0) }
        /// A host's link came back: the reconnect sweep, with its backoff
        /// and its setting, lets the other lost panes of the host attach.
        var hostDidConnect: @MainActor (String) -> Void = {
            NotificationCenter.default.post(name: .remoteHostDidConnect, object: $0)
        }

        var declines: DeclineStore
        /// How long a session that the app told a client to make counts as
        /// made (`created`).
        var creationGrace: TimeInterval = 30
        /// A host's link to its server is up: its background work starts
        /// (the terminfo install).
        var linkReady: @MainActor (String) -> Void = { _ in }
        /// Whether to open a roaming link (design/009) after a connect. Off
        /// by default, so that a test never opens a UDP port.
        var roamingEnabled: @MainActor () -> Bool = { false }
        /// The host scripts: the plain shell of a host with no server.
        var scripts: HostCommands.Scripts? = .bundled

        static var live: Configuration {
            Configuration(
                key: ServerBuilds.bundledKey,
                declines: .preferences,
                linkReady: { RemoteTerminfoInstaller.shared.ensureInstalled(destination: $0) },
                roamingEnabled: { Preferences.shared.remoteRoamingLink }
            )
        }
    }

    /// The destinations whose server install the user declined.
    struct DeclineStore {
        var read: @MainActor () -> [String]
        var write: @MainActor ([String]) -> Void

        static var preferences: DeclineStore {
            DeclineStore(
                read: { Preferences.shared.remoteServerDeclines },
                write: { Preferences.shared.remoteServerDeclines = $0 }
            )
        }
    }

    static let shared = RemoteHosts(connections: .shared, servers: .shared, configuration: .live)

    /// The destinations whose panes are plain ssh shells, because the user
    /// declined the install of the server there.
    private(set) var declined: Set<String>

    private let connections: SSHConnections
    private let servers: RemoteServers
    private let configuration: Configuration

    private enum Host {
        /// A login and a check run. The token tells this prepare from a
        /// later one.
        case preparing(UUID, Task<Void, Never>)
        case ready(RemoteServers.Link)
        /// No server: plain shells.
        case plain(SSHConnections.Route)
    }

    /// The remote panes that show a session (`AppState.remotePanes`), set
    /// when the app starts: a pane's driver asks with them, so the host and
    /// the folder come from the user's own panes.
    @ObservationIgnored var panes: (@MainActor (String) -> [Pane])?

    @ObservationIgnored private var hosts: [String: Host] = [:]
    /// The roaming link of a host (design/009), and the ssh link that it
    /// replaced as the host's link. Panes that attached over the ssh link
    /// stay on it until it ends.
    @ObservationIgnored private var transports: [String: LinkTransport] = [:]
    @ObservationIgnored private var standby: [String: RemoteServers.Link] = [:]
    /// Tells a late `onDead` of an older link from the current one.
    @ObservationIgnored private var roamingGeneration: [String: Int] = [:]
    /// The sessions that wait for their host to be ready.
    @ObservationIgnored private var waiting: [String: Set<String>] = [:]
    /// Sessions whose connection stopped: they wait for a trigger or a key.
    @ObservationIgnored private var lost: Set<String> = []
    /// A line for a session's pane, given with the next answer.
    @ObservationIgnored private var messages: [String: String] = [:]
    /// Lists that failed on the current link of a host, in a row.
    @ObservationIgnored private var listFailures: [String: Int] = [:]
    /// When the app last told a session's client to make it. A second client
    /// (a mirror) can ask before the host lists the new session, and a
    /// channel can drop before the session starts: in this time a missing
    /// session is made, not reported as gone.
    @ObservationIgnored private var created: [String: Date] = [:]

    init(connections: SSHConnections, servers: RemoteServers, configuration: Configuration) {
        self.connections = connections
        self.servers = servers
        self.configuration = configuration
        declined = Set(configuration.declines.read())
    }

    /// The Darwin notification that wakes the client of `session`.
    nonisolated static func wakeName(for session: String) -> String {
        "\(appBundleID).remote-pane.\(session)"
    }

    // MARK: - A pane's client

    /// The answer to `event` from the client of `session`. `panes` are the
    /// panes that show the session (a mirror shows it too); none means the
    /// pane closed.
    func answer(_ event: RemotePaneEvent, session: String, panes: [Pane]) async -> RemotePaneAnswer {
        guard let pane = panes.first, let target = Target(pane) else { return .close }
        switch event {
        case .ask:
            if lost.contains(session) {
                mark(panes, lost: true)
                return .wait(message: messages.removeValue(forKey: session))
            }
        case .lost:
            logger.info("remote pane: session=\(session, privacy: .public) host=\(target.destination, privacy: .public) lost")
            lost.insert(session)
            for pane in panes {
                pane.remoteLinkDidStop()
            }
            mark(panes, lost: true)
            // The next connect checks the connection again. A roaming link
            // stays: the host may still hold it, and the next attach asks it
            // (`decide` drops it when it does not answer).
            if !isRoamingLink(target.destination) {
                drop(target.destination)
            }
            return .wait(message: RemotePaneText.linkStopped(host: target.host))
        case .retry:
            lost.remove(session)
        }
        return await resolve(session, panes: panes, target: target)
    }

    /// A trigger lets these lost panes connect again. The caller applies
    /// the backoff.
    func reconnect(_ sessions: Set<String>) {
        for session in sessions where lost.remove(session) != nil {
            configuration.post(Self.wakeName(for: session))
        }
    }

    /// End a session on its host, when its pane closed for good. It uses
    /// only a connection that is up: a close never asks for a login. With no
    /// connection, the session stays.
    func endSession(_ session: String, destination: String) async {
        forget(session)
        switch hosts[destination] {
        case let .ready(link):
            await Self.kill(session, over: link)
            return
        case .plain:
            return
        case .preparing,
             nil:
            break
        }
        do {
            let link = try await servers.connect(destination, login: false, install: false)
            await Self.kill(session, over: link)
            link.close()
        } catch {
            logger.info("remote session \(session, privacy: .public) stays: \(String(describing: error), privacy: .public)")
        }
    }

    /// Run a command on a host to its end, over the host's server
    /// (`command.run`), for a background read: Project Insights' Git state,
    /// the terminfo install. It uses only a connection that is up, as
    /// `endSession`: a background read never asks for a login and never
    /// opens a connection of its own (design/005). nil when no connection or
    /// no server is up, or when the command did not end in time.
    func run(
        _ argv: [String],
        destination: String,
        timeout: Duration
    ) async -> MactermProtocol.CommandRun.Result? {
        switch hosts[destination] {
        case let .ready(link):
            return await Self.run(argv, timeout: timeout, over: link)
        case .plain:
            return nil
        case .preparing,
             nil:
            break
        }
        do {
            let link = try await servers.connect(destination, login: false, install: false)
            defer { link.close() }
            return await Self.run(argv, timeout: timeout, over: link)
        } catch {
            logger.info("remote command on \(destination, privacy: .public) not run: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Install the server on a host where the user declined it, after the
    /// user's click. New panes then get sessions; a plain shell stays plain.
    func installServer(_ destination: String) async throws {
        undecline(destination)
        if case let .preparing(_, task) = hosts[destination] { await task.value }
        drop(destination)
        _ = try await connections.connect(destination)
        do {
            let link = try await servers.connect(destination)
            if case let .ready(old) = hosts[destination] { old.close() }
            hosts[destination] = .ready(link)
            configuration.linkReady(destination)
            adoptRoaming(destination, over: link)
        } catch RemoteServers.Failure.declined {
            decline(destination)
            throw RemoteServers.Failure.declined
        }
    }

    // MARK: - Steps

    /// What a pane needs from its project path.
    private struct Target {
        var destination: String
        var host: String
        var directory: String

        init?(_ pane: Pane) {
            guard case let .remote(_, host, directory) = pane.remoteSpec, let destination = pane.remoteDestination else { return nil }
            guard SSHConnections.isValidDestination(destination) else { return nil }
            self.destination = destination
            self.host = host
            self.directory = directory
        }
    }

    private func resolve(_ session: String, panes: [Pane], target: Target) async -> RemotePaneAnswer {
        let destination = target.destination
        switch hosts[destination] {
        case nil:
            prepare(destination, host: target.host)
            waiting[destination, default: []].insert(session)
            return .wait(message: nil)
        case .preparing:
            waiting[destination, default: []].insert(session)
            return .wait(message: nil)
        case let .plain(route):
            mark(panes, lost: false)
            guard let command = configuration.scripts?.plainCommand(directory: target.directory) else {
                return .wait(message: RemotePaneText.noPlainShell)
            }
            return .plain(
                arguments: connections.ttyArguments(route, destination, command),
                message: RemotePaneText.plainShell(host: target.host)
            )
        case let .ready(link):
            return await decide(session, panes: panes, target: target, link: link)
        }
    }

    private func decide(
        _ session: String,
        panes: [Pane],
        target: Target,
        link: RemoteServers.Link
    ) async -> RemotePaneAnswer {
        let destination = target.destination
        guard configuration.key != nil else { return .close }
        guard let sessions = await Self.list(over: link) else {
            // A roaming link whose transport still runs is waiting for the
            // network: the next trigger asks again. Only a dead transport
            // drops it (`roamingEnded`).
            if link.isRoaming, link.connection.isOpen, case let .ready(current) = hosts[destination], current === link {
                lost.insert(session)
                mark(panes, lost: true)
                return .wait(message: nil)
            }
            // The link broke. Only a failure on the host's current link
            // counts, and drops it: another request may have made a new one
            // meanwhile. Two failures in a row are the host's answer.
            guard case let .ready(current) = hosts[destination], current === link else {
                return await resolve(session, panes: panes, target: target)
            }
            drop(destination)
            let failures = listFailures[destination, default: 0] + 1
            listFailures[destination] = failures
            guard failures < 2 else {
                listFailures[destination] = nil
                lost.insert(session)
                mark(panes, lost: true)
                return .wait(message: RemotePaneText.withRetry(RemotePaneText.serverSilent(host: target.host)))
            }
            return await resolve(session, panes: panes, target: target)
        }
        listFailures[destination] = nil
        let found = sessions.first { $0.name == session }
        if let found, !found.isRunning {
            // The shell exited while no pane showed it.
            await Self.kill(session, over: link)
        }
        // A folder that the host reported must be a plain path.
        let known = panes.lazy.compactMap(\.hostSessionDirectory).first
            .map { HostCommands.isSafeHostFolder($0) ? $0 : target.directory }
        let justCreated = created[session].map { Date().timeIntervalSince($0) < configuration.creationGrace } ?? false
        if found?.isRunning == true { created[session] = nil }
        let step = Self.step(
            running: found?.isRunning == true,
            sessionDirectory: known,
            justCreated: justCreated,
            projectDirectory: target.directory
        )
        switch step {
        case .attach:
            mark(panes, lost: false)
            for pane in panes where pane.hostSessionDirectory == nil {
                pane.hostSessionDirectory = target.directory
            }
            return .attach(link: link, create: nil)
        case let .create(directory):
            mark(panes, lost: false)
            created[session] = Date()
            for pane in panes {
                pane.hostSessionDirectory = directory
            }
            if panes.count > 1 {
                configuration.post(Self.wakeName(for: session))
            }
            return .attach(link: link, create: directory)
        case .gone:
            logger.info("remote pane: session=\(session, privacy: .public) is gone on \(destination, privacy: .public), the pane closes")
            forget(session)
            return .close
        }
    }

    enum Step: Equatable {
        case attach
        case create(directory: String)
        case gone
    }

    /// What a pane does with its session. A running session attaches. A
    /// missing one starts in the pane's folder when the app made it in the
    /// grace time, or when the pane never had a session on the host (a new
    /// pane, or one from before v2). Otherwise it is gone: the pane closes.
    /// Pure.
    nonisolated static func step(
        running: Bool,
        sessionDirectory: String?,
        justCreated: Bool,
        projectDirectory: String
    ) -> Step {
        if running { return .attach }
        if justCreated { return .create(directory: sessionDirectory ?? projectDirectory) }
        guard sessionDirectory != nil else { return .create(directory: projectDirectory) }
        return .gone
    }

    /// Log in, then check and install the server, for the sessions that
    /// wait. The end wakes them.
    private func prepare(_ destination: String, host: String) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let result: Result<Host, PrepareFailure>
            do {
                result = try await .success(open(destination))
            } catch {
                logger.info("remote host \(destination, privacy: .public): \(String(describing: error), privacy: .public)")
                result = .failure(PrepareFailure(message: RemotePaneText.connectFailure(error, host: host)))
            }
            finish(destination, token: token, result)
        }
        hosts[destination] = .preparing(token, task)
    }

    private struct PrepareFailure: Error {
        var message: String
    }

    private func open(_ destination: String) async throws -> Host {
        let route = try await connections.connect(destination)
        do {
            let link = try await servers.connect(destination, install: !declined.contains(destination))
            return .ready(link)
        } catch let failure as RemoteServers.Failure {
            switch failure {
            case .declined:
                decline(destination)
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

    private func finish(_ destination: String, token: UUID, _ result: Result<Host, PrepareFailure>) {
        let sessions = waiting.removeValue(forKey: destination) ?? []
        guard case let .preparing(current, _) = hosts[destination], current == token else {
            // Another step replaced this prepare (an install from Settings).
            // Its waiting panes ask again and find that step's state.
            if case let .success(.ready(link)) = result { link.close() }
            for session in sessions {
                configuration.post(Self.wakeName(for: session))
            }
            return
        }
        switch result {
        case let .success(host):
            hosts[destination] = host
            // One login serves every pane of the host. The sweep owns when a
            // lost pane connects again, so this never loops.
            configuration.hostDidConnect(destination)
            if case let .ready(link) = host {
                configuration.linkReady(destination)
                adoptRoaming(destination, over: link)
            }
        case let .failure(failure):
            hosts[destination] = nil
            for session in sessions {
                lost.insert(session)
                messages[session] = RemotePaneText.withRetry(failure.message)
            }
        }
        for session in sessions {
            configuration.post(Self.wakeName(for: session))
        }
    }

    // MARK: - The roaming link

    /// Opens a roaming link over the host's ssh link, in the background. If
    /// it works, it becomes the host's link: new attaches use it, and it
    /// survives sleep and a new network. The ssh link stays for the panes that
    /// attached over it. A host that cannot do it keeps the ssh link.
    private func adoptRoaming(_ destination: String, over ssh: RemoteServers.Link) {
        let connections = connections
        let enabled = configuration.roamingEnabled()
        let generation = roamingGeneration[destination, default: 0] + 1
        roamingGeneration[destination] = generation
        Task { [weak self] in
            let opened = await RoamingLink.open(
                destination: destination,
                over: ssh,
                connections: connections,
                enabled: enabled,
                onDead: { [weak self] in
                    Task { @MainActor in self?.roamingEnded(destination, generation: generation) }
                }
            )
            guard let self, let opened else { return }
            // The host may have changed while the link opened.
            guard case let .ready(current) = hosts[destination], current === ssh else {
                opened.link.close()
                opened.transport.stop()
                return
            }
            guard roamingGeneration[destination] == generation else {
                opened.link.close()
                opened.transport.stop()
                return
            }
            standby[destination]?.close()
            standby[destination] = ssh
            transports[destination]?.stop()
            transports[destination] = opened.transport
            hosts[destination] = .ready(opened.link)
        }
    }

    /// The link ended by itself: no packet for a long time. The panes on it
    /// are lost, and the next connect uses ssh.
    private func roamingEnded(_ destination: String, generation: Int) {
        guard roamingGeneration[destination] == generation,
              case let .ready(link) = hosts[destination], link.isRoaming
        else { return }
        logger.info("link: host=\(destination, privacy: .public) ended")
        drop(destination)
    }

    private func isRoamingLink(_ destination: String) -> Bool {
        if case let .ready(link) = hosts[destination] { return link.isRoaming }
        return false
    }

    private func endRoaming(_ destination: String) {
        roamingGeneration[destination, default: 0] += 1
        transports.removeValue(forKey: destination)?.stop()
        standby.removeValue(forKey: destination)?.close()
    }

    /// The network changed or the Mac woke: each roaming link uses a new
    /// socket, so that its packets leave on the new path.
    func networkDidChange() {
        for transport in transports.values {
            transport.pathChanged()
        }
    }

    /// Forget a host's link: the next pane checks the connection again.
    private func drop(_ destination: String) {
        switch hosts[destination] {
        case let .ready(link):
            link.close()
            hosts[destination] = nil
            if link.isRoaming { endRoaming(destination) }
        case .plain:
            hosts[destination] = nil
        case .preparing,
             nil:
            break
        }
    }

    private func forget(_ session: String) {
        created[session] = nil
        lost.remove(session)
        messages[session] = nil
        for destination in waiting.keys {
            waiting[destination]?.remove(session)
        }
    }

    private func mark(_ panes: [Pane], lost: Bool) {
        for pane in panes where pane.isRemoteLinkLost != lost {
            logger.info("remote pane: session=\(pane.sessionName, privacy: .public) isRemoteLinkLost=\(lost, privacy: .public)")
            pane.isRemoteLinkLost = lost
        }
    }

    private func decline(_ destination: String) {
        declined.insert(destination)
        configuration.declines.write(declined.sorted())
    }

    private func undecline(_ destination: String) {
        guard declined.remove(destination) != nil else { return }
        configuration.declines.write(declined.sorted())
    }

    /// What a new session on a host runs in: the folder, and the host's
    /// environment settled for a terminal. The line is Macterm's note for the
    /// pane when the folder was not there. nil when the host did not answer.
    func createLaunch(link: RemoteServers.Link, directory: String) async -> (launch: PaneSession.Launch, note: String?)? {
        guard let result = await Self.run(
            HostCommands.createProbeArgv(directory: directory),
            timeout: .seconds(10), over: link
        ), result.code == 0
        else { return nil }
        return Self.parseCreateProbe(String(decoding: result.output.bytes, as: UTF8.self), directory: directory)
    }

    /// Pure. The lines of `HostCommands.createProbeScript`'s output.
    nonisolated static func parseCreateProbe(_ output: String, directory: String) -> (launch: PaneSession.Launch, note: String?)? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[1].hasPrefix("/") else { return nil }
        let found = lines[0] == "ok"
        let cwd = lines[1]
        lines.removeFirst(2)
        let env = lines.filter { line in
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { return false }
            let name = line[..<equals]
            // The server's environment is the one of the pane that started
            // it: the login of that ssh does not belong to a new session.
            guard !name.hasPrefix("SSH_") else { return false }
            return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        let launch = PaneSession.Launch(cwd: cwd, argv: nil, env: env)
        return (launch, found ? nil : "macterm: cannot cd to \(directory)")
    }

    // MARK: - The link

    private static func list(over link: RemoteServers.Link) async -> [LocalSession]? {
        let connection = link.connection
        do {
            return try await LocalSessions.bounded {
                try await connection.call(MactermProtocol.SessionList.self, .init()).sessions
            }.map(LocalSession.init)
        } catch {
            logger.warning("remote session list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func run(
        _ argv: [String],
        timeout: Duration,
        over link: RemoteServers.Link
    ) async -> MactermProtocol.CommandRun.Result? {
        let connection = link.connection
        let args = MactermProtocol.CommandRun.Args(
            argv: argv.map { ProtocolBin(Data($0.utf8)) },
            cwd: nil,
            timeoutMs: UInt32(timeout.components.seconds * 1000)
        )
        do {
            return try await LocalSessions.bounded {
                try await connection.call(MactermProtocol.CommandRun.self, args)
            }
        } catch {
            logger.warning("remote command failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func kill(_ session: String, over link: RemoteServers.Link) async {
        let connection = link.connection
        do {
            _ = try await LocalSessions.bounded {
                try await connection.call(MactermProtocol.SessionKill.self, .init(id: session))
            }
        } catch let ProtocolControlError.errorResponse(info) where info.errorCode == .notFound {
            return
        } catch {
            logger.warning("remote session kill \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The lines that a remote pane shows (0057). They stay English, as all
/// text that Macterm writes into a pane. Pure.
enum RemotePaneText {
    /// A failed connect, in Macterm's words for ssh's three common errors,
    /// else ssh's last line, cleaned (Ethan, 2026-11-09).
    static func connectFailure(_ error: Error, host: String) -> String {
        switch error {
        case let failure as SSHConnections.Failure:
            switch failure {
            case let .loginFailed(line): loginFailure(line, host: host)
            case .cancelled: "You cancelled the login to \(host)."
            case let .configUnreadable(line): "ssh cannot read its configuration: \(HostCheck.clean(line))"
            default: "Macterm cannot connect to \(host): \(failure.description)."
            }
        case RemoteServers.Failure.windowsHost:
            "\(host) runs Windows. Macterm does not support Windows hosts."
        case let failure as RemoteServers.Failure:
            "Macterm cannot start its server on \(host): \(failure.description)."
        default:
            "Macterm cannot connect to \(host)."
        }
    }

    static func loginFailure(_ line: String, host: String) -> String {
        if line.contains("Could not resolve hostname") { return "No host is named \(host)." }
        if line.contains("Operation timed out") || line.contains("Connection timed out") { return "\(host) does not answer." }
        if line.contains("Connection refused") { return "\(host) refuses the connection." }
        let cleaned = HostCheck.clean(line)
        return cleaned.isEmpty ? "The login to \(host) failed." : cleaned
    }

    static func withRetry(_ line: String) -> String {
        "\(line)\nPress a key to try again."
    }

    static func serverSilent(host: String) -> String {
        "The server on \(host) does not answer."
    }

    /// The bundle has no host scripts, or the folder is too long for one
    /// argument.
    static let noPlainShell = "Macterm cannot start a shell in this folder."

    static func plainShell(host: String) -> String {
        "Macterm has no server on \(host). This shell stops when the connection stops."
    }

    static func linkStopped(host: String) -> String {
        "The connection to \(host) stopped. Press a key to connect again."
    }
}
