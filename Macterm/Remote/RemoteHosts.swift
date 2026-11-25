import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteHosts")

/// The remote hosts (0057, 0264): one `RemoteHost` for each ssh destination,
/// which owns that host's state, and the work on a host that is not a pane's:
/// the folder check of a new project, background reads, the end of a
/// session, the install from Settings.
///
/// - **Lost.** A pane whose link stopped, or whose connect failed, is lost
///   (`Pane.isRemoteLinkLost`, from its host's session table): its cursor
///   says disabled, and its badge says `Reconnecting` while a try runs
///   (`Pane.isRemoteReconnecting`), else `Connection Lost`. A pane that came
///   back after a restart says `Reconnecting` while a slow first connect
///   runs (`RemoteHost.firstConnectIsSlow`). It connects again by itself
///   (`AppState.reconnectDroppedRemotePanes` → `reconnect`, with the host's
///   backoff): such a try never asks the user anything. A key in the pane
///   connects at once, and may ask for the login. The attach replays the
///   session's screen.
/// - **Gone.** A pane whose session ran on the host
///   (`Pane.hostSessionDirectory`) and is gone there (a host restart) closes:
///   the pane exists only while its session exists. A server is never
///   started empty in silence for a pane that expects a session. A pane from
///   before v2 has no such folder: its first session starts with no
///   question, as local panes did at the cut-over.
/// - **No server.** When the user declined the install, or the host has no
///   build, each pane is a plain ssh shell. The decline is kept (`declined`);
///   Settings → Projects offers the install again.
/// - v1 sessions on a host keep running: nothing here ends one.
@MainActor @Observable
final class RemoteHosts {
    struct Configuration {
        /// The build key of the bundled server.
        var key: String?
        /// A host's link came back: the reconnect sweep, with its backoff
        /// and its setting, lets the other lost panes of the host attach.
        var hostDidConnect: @MainActor (String) -> Void = {
            NotificationCenter.default.post(name: .remoteHostDidConnect, object: $0)
        }

        /// The roaming link hears its host after a gap of more than one
        /// keepalive (`LinkTransport.answersAfter`): the host answers again.
        /// The reconnect sweep tries the host's lost panes now, with no
        /// backoff.
        var hostAnswered: @MainActor (String) -> Void = {
            NotificationCenter.default.post(name: .remoteHostDidAnswer, object: $0)
        }

        /// A pane of the host became lost: its link stopped, or a try
        /// failed. The reconnect sweep runs now, so a try starts at once or
        /// is planned, after the host's backoff.
        /// The post goes on the next turn of the main queue: the pane then
        /// waits for its try.
        var hostLost: @MainActor (String) -> Void = { destination in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .remoteLinkDidStop, object: destination)
            }
        }

        /// Logs in and connects to the host's server. nil: the live way, over
        /// `SSHConnections` and `RemoteServers`. Tests give a fake link.
        var open: (@MainActor (
            _ destination: String,
            _ prompts: Bool,
            _ step: @escaping @MainActor (RemoteHost.Step) -> Void
        ) async throws -> RemoteHost.Opened)?

        var declines: DeclineStore
        /// How long a session that the app told a client to make counts as
        /// made (`RemoteHost.SessionState.created`).
        var creationGrace: TimeInterval = 30
        /// A host's link to its server is up: its background work starts
        /// over it (the terminfo install).
        var linkReady: @MainActor (String, RemoteServers.Link) -> Void = { _, _ in }
        /// Whether to open a roaming link (design/009) after a connect. Off
        /// by default, so that a test never opens a UDP port.
        var roamingEnabled: @MainActor () -> Bool = { false }
        /// The host scripts: the plain shell of a host with no server.
        var scripts: HostCommands.Scripts? = .bundled

        static var live: Configuration {
            Configuration(
                key: ServerBuilds.bundledKey,
                declines: .preferences,
                linkReady: { RemoteTerminfoInstaller.shared.ensureInstalled(destination: $0, over: $1) },
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

    let connections: SSHConnections
    let servers: RemoteServers
    var configuration: Configuration

    /// One host for each destination. A host stays for the run of the app.
    private(set) var hosts: [String: RemoteHost] = [:]

    /// The remote pane that shows a session (`AppState.remotePane`), set
    /// when the app starts: a pane's driver asks with it, so the host and
    /// the folder come from the user's own pane.
    @ObservationIgnored var pane: (@MainActor (String) -> Pane?)? {
        didSet { if pane != nil { paneInstalled.fire(()) } }
    }

    @ObservationIgnored private let paneInstalled = AsyncSignal<Void>()

    /// The destinations whose panes are plain ssh shells: the user declined
    /// the server, or the host has no build (`RemoteHost.isPlain`). The
    /// sidebar's project row shows it, so the pane prints no line.
    var plainDestinations: Set<String> {
        Set(hosts.values.filter(\.isPlain).map(\.destination))
    }

    /// The destinations whose roaming link hears nothing from the host now
    /// (`RemoteHost.isQuiet`). The sidebar's project row shows the host as
    /// lost.
    var quietDestinations: Set<String> {
        Set(hosts.values.filter(\.isQuiet).map(\.destination))
    }

    init(connections: SSHConnections, servers: RemoteServers, configuration: Configuration) {
        self.connections = connections
        self.servers = servers
        self.configuration = configuration
        declined = Set(configuration.declines.read())
    }

    /// The host of `destination`. It is made at the first ask.
    func host(_ destination: String) -> RemoteHost {
        if let host = hosts[destination] { return host }
        let host = RemoteHost(destination: destination, owner: self)
        hosts[destination] = host
        return host
    }

    /// The host of a remote pane, which the pane then reads its state from.
    /// nil for a local pane, or one whose host is not a valid destination.
    func host(of pane: Pane) -> RemoteHost? {
        guard let target = Target(pane) else { return nil }
        let host = host(target.destination)
        if pane.linkHost !== host { pane.linkHost = host }
        return host
    }

    /// The pane that shows `session`. A pane that restores before the app
    /// has installed its state waits for it. nil: the pane closed.
    func pane(for session: String) async throws -> Pane? {
        while pane == nil {
            try await paneInstalled.wait()
        }
        return pane?(session)
    }

    /// The sweep of the app: these hosts let their lost panes try again,
    /// after each host's backoff. `answered`: the hosts answer again, which
    /// clears their backoff.
    func reconnect(_ destinations: Set<String>, answered: Bool = false) {
        let now = Date()
        for destination in destinations {
            hosts[destination]?.reconnect(answered: answered, now: now)
        }
    }

    /// The network changed or the Mac woke: each roaming link uses a new
    /// socket, so that its packets leave on the new path.
    func networkDidChange() {
        for host in hosts.values {
            host.networkDidChange()
        }
    }

    /// End a session on its host, when its pane closed for good. It uses
    /// only a connection that is up: a close never asks for a login. With no
    /// connection, the session stays.
    func endSession(_ session: String, destination: String) async {
        let host = hosts[destination]
        host?.forget(session)
        if let link = host?.link {
            await link.kill(session)
            return
        }
        if case .plain = host?.state { return }
        do {
            let link = try await servers.connect(destination, login: false, install: false)
            await link.kill(session)
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
        let host = hosts[destination]
        if let link = host?.link { return await link.run(argv, timeout: timeout) }
        if case .plain = host?.state { return nil }
        do {
            let link = try await servers.connect(destination, login: false, install: false)
            defer { link.close() }
            return await link.run(argv, timeout: timeout)
        } catch {
            logger.info("remote command on \(destination, privacy: .public) not run: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The answer of `checkFolder`.
    enum FolderCheck: Equatable {
        case exists
        case missing
        /// The path is there and is a file.
        case notDirectory
        /// No connection, or the check did not run to its end.
        case unreachable
    }

    /// Whether `directory` is on the host, before a remote project for it is
    /// added (0358). A host with a link: its server runs
    /// `HostCommands.folderCheckScript` (`command.run`). Any other host: the
    /// same script runs over the ssh connection first, so the login may ask,
    /// and a missing folder is told before the install question (0384). Then,
    /// for a folder that is there, the host connects as a new pane does: the
    /// server install may ask, and the connection stays for the project's
    /// panes. Fail closed: anything other than the script's own answer is
    /// `unreachable`, and the log says why.
    func checkFolder(_ directory: String, destination: String) async -> FolderCheck {
        guard SSHConnections.isValidDestination(destination) else {
            logger.info("folder check: \(destination, privacy: .public) is not a valid host")
            return .unreachable
        }
        if let link = hosts[destination]?.link, let answer = await checkFolder(directory, destination: destination, over: link) {
            return answer
        }
        guard let command = HostCommands.folderCheckCommand(directory: directory) else {
            logger.info("folder check: \(destination, privacy: .public): the folder is too long")
            return .unreachable
        }
        let found: FolderCheck
        do {
            let outcome = try await connections.run(destination, command, timeout: .seconds(20))
            found = answer(status: outcome.status, destination: destination)
        } catch {
            logger.info("folder check: \(destination, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unreachable
        }
        guard found == .exists else { return found }
        // A check that the palette cancelled adds nothing: no install
        // question for it.
        guard !Task.isCancelled else { return .unreachable }
        let host = host(destination)
        await host.connectAsking()
        switch host.state {
        case .ready,
             .plain:
            return .exists
        default:
            // The host logged the reason.
            logger.info("folder check: \(destination, privacy: .public): no connection after the check")
            return .unreachable
        }
    }

    /// The check by the host's server. nil when the link closed: it is
    /// dropped, and the check goes over ssh.
    private func checkFolder(_ directory: String, destination: String, over link: RemoteServers.Link) async -> FolderCheck? {
        // 8 s: the request itself gives up at 10 s (`serverRequestTimeout`).
        let argv = HostCommands.folderCheckArgv(directory: directory)
        if let result = await link.run(argv, timeout: .seconds(8)) {
            return answer(status: result.signal == nil ? result.code.map(Int32.init) : nil, destination: destination)
        }
        // Only a closed connection is dropped: a slow folder (a network
        // mount) on a good link must not end its panes.
        guard !link.connection.isOpen else {
            logger.info("folder check: \(destination, privacy: .public): the server did not answer")
            return .unreachable
        }
        if let host = hosts[destination], host.link === link { host.drop() }
        return nil
    }

    /// The folders in `directory` on the host, for the path completion of
    /// a remote folder field (0614, `HostCommands.folderListScript`). Over
    /// the host's ssh connection, only one that is up: a keystroke never
    /// asks for a login. nil when no connection is up, the folder is not
    /// there, or no answer came in `timeout`; the field then shows no rows.
    func listFolders(_ directory: String, destination: String, timeout: Duration = .seconds(2)) async -> FolderListing? {
        guard SSHConnections.isValidDestination(destination),
              let command = HostCommands.folderListCommand(directory: directory),
              let outcome = try? await connections.run(destination, command, login: false, timeout: timeout),
              let list = HostCommands.folderList(status: outcome.status, output: outcome.stdout)
        else { return nil }
        return FolderListing(path: list.path, names: list.names)
    }

    /// What `directory` is on the host, for a remote folder field as the
    /// user types (`HostFolderLister.check`). Over the host's ssh
    /// connection, only one that is up, as `listFolders`: a keystroke never
    /// asks for a login and never connects. nil when no connection is up or
    /// no answer came in `timeout`.
    func probeFolder(_ directory: String, destination: String, timeout: Duration = .seconds(2)) async -> FolderCheck? {
        guard SSHConnections.isValidDestination(destination),
              let command = HostCommands.folderCheckCommand(directory: directory),
              let outcome = try? await connections.run(destination, command, login: false, timeout: timeout)
        else { return nil }
        let answer = Self.folderCheck(status: outcome.status)
        return answer == .unreachable ? nil : answer
    }

    /// `checkFolder` for the scp-style path of a new remote project in the
    /// GUI (New Remote Project in the palette, Create Project of a layout file in
    /// Settings): nil when the folder is there, else the
    /// line that says why nothing is added. A path that is not a folder has
    /// the notice of a local path (`PathProblem`), with the folder as typed.
    func refusal(forNewProjectPath path: String) async -> String? {
        guard case let .remote(user, host, directory) = ProjectPath.parse(path) else { return nil }
        let destination = HostCommands.destination(user: user, host: host)
        return await Self.refusal(checkFolder(directory, destination: destination), directory: directory, destination: destination)
    }

    /// The line for an answer of `checkFolder`, nil when the folder is
    /// there. Pure.
    nonisolated static func refusal(_ check: FolderCheck, directory: String, destination: String) -> String? {
        switch check {
        case .exists: nil
        case .missing: PathProblem.missing.notice(for: directory)
        case .notDirectory: PathProblem.notDirectory.notice(for: directory)
        case .unreachable: String(localized: "Macterm cannot connect to \(destination).")
        }
    }

    /// The answer for the exit status of the folder check. Pure.
    nonisolated static func folderCheck(status: Int32?) -> FolderCheck {
        switch status {
        case 0: .exists
        case 3: .missing
        case 4: .notDirectory
        default: .unreachable
        }
    }

    private func answer(status: Int32?, destination: String) -> FolderCheck {
        let answer = Self.folderCheck(status: status)
        if answer == .unreachable {
            let end = status.map(String.init) ?? "a signal"
            logger.info("folder check: \(destination, privacy: .public): the check ended with \(end, privacy: .public)")
        }
        return answer
    }

    /// Install the server on a host where the user declined it, after the
    /// user's click. New panes then get sessions; a plain shell stays plain.
    /// A second decline keeps the host plain, so its sidebar mark stays.
    func installServer(_ destination: String) async throws {
        try await host(destination).installServer()
    }

    /// What a pane needs from its project path.
    struct Target {
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

    func decline(_ destination: String) {
        declined.insert(destination)
        configuration.declines.write(declined.sorted())
    }

    func undecline(_ destination: String) {
        guard declined.remove(destination) != nil else { return }
        configuration.declines.write(declined.sorted())
    }

    /// What a new session on a host runs in: the folder, and the host's
    /// environment settled for a terminal. The line is Macterm's note for the
    /// pane when the folder was not there. nil when the host did not answer.
    func createLaunch(link: RemoteServers.Link, directory: String) async -> (launch: PaneSession.Launch, note: String?)? {
        guard let result = await link.run(HostCommands.createProbeArgv(directory: directory), timeout: .seconds(10)),
              result.code == 0
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
}

/// The lines that a remote pane shows (0057). They stay English, as all
/// text that Macterm writes into a pane. A failed connect writes no line:
/// the pane's badge shows it. Pure.
enum RemotePaneText {
    /// The bundle has no host scripts, or the folder is too long for one
    /// argument.
    static let noPlainShell = "Macterm cannot start a shell in this folder."
}
