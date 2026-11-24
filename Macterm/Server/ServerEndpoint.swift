import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ServerEndpoint")

/// One connection to a server, as a pane and a session list use it.
/// `ServerConnection` is the connection that the app runs. The unit tests
/// use an in-memory link that speaks frames (`FakeServerLink`).
protocol ServerLink: PaneChannelOpener, PaneChannelTransport {
    /// False once the connection ended.
    var isOpen: Bool { get }
    /// Sends one request and waits for its response. A response with `err`
    /// throws `ProtocolControlError.errorResponse`. With a `timeout`, a
    /// response that does not come in time throws
    /// `ServerClientError.noAnswer`. A cancelled or timed-out request removes
    /// its waiting entry: a late response is dropped.
    func call<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args, timeout: Duration?) async throws -> M.Result
    /// Opens a pane channel to `session` (design/003 §1).
    func openChannel(session: String) async throws -> PaneChannel
    /// Sends a frame on a pane channel. Throws `disconnected` when the
    /// connection ended.
    func send(frame: ProtocolFrame) throws
    /// Forgets a channel. Frames that still come for it are dropped.
    func releaseChannel(_ number: UInt32)
    /// Ends the connection. Requests that wait fail with `disconnected`.
    func close()
}

extension ServerConnection: ServerLink {}

extension ServerLink {
    /// Asks the server to end the channel, then forgets it.
    func closeChannel(_ number: UInt32) async {
        _ = try? await call(MactermProtocol.ChannelClose.self, .init(channel: number))
        releaseChannel(number)
    }
}

/// The longest wait for one reply. A kill waits for the session to end:
/// the server gives it 3 s before SIGKILL.
let serverRequestTimeout: Duration = .seconds(10)

extension ServerLink {
    /// A request with no time limit.
    func call<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args) async throws -> M.Result {
        try await call(method, args, timeout: nil)
    }
}

/// A session as a server lists it, local or on a host.
struct SessionInfo: Equatable {
    var name: String
    /// The session process (`__session`), the responsible process of every
    /// program in the session (server/AGENTS.md, "Session daemons and
    /// macOS attribution").
    var pid: pid_t?
    /// The session's shell, the leader of its pty.
    var shellPID: pid_t?
    /// False after the shell exited: the session keeps the status until a
    /// client reads it.
    var isRunning: Bool
    /// The clients that show the session. nil when the session did not say.
    var clients: Int?
    /// The build key of the build that started the session, which an update
    /// never changes. nil when the session did not say.
    var buildKey: String?

    init(
        name: String,
        pid: pid_t? = nil,
        shellPID: pid_t? = nil,
        isRunning: Bool = true,
        clients: Int? = 0,
        buildKey: String? = nil
    ) {
        self.name = name
        self.pid = pid
        self.shellPID = shellPID
        self.isRunning = isRunning
        self.clients = clients
        self.buildKey = buildKey
    }

    init(_ session: MactermProtocol.Session) {
        self.init(
            name: session.id,
            pid: session.pid.flatMap { pid_t(exactly: $0) },
            shellPID: session.shellPid.flatMap { pid_t(exactly: $0) },
            isRunning: session.state == .running,
            clients: session.clients.map(Int.init),
            buildKey: session.buildKey
        )
    }
}

/// Where a pane's session lives: the local server (`LocalSessions`), or the
/// server of one host, through one link to it (`RemoteServers.Link`).
///
/// `PaneSession` asks the endpoint for a connection at each attach, so the
/// endpoint decides if a pane gets a next connection. The local endpoint
/// starts the server and tries for a few seconds. A remote pane gets its
/// host's link for one attach (`RemotePaneDriver.OneAttach`): after it, the
/// pane's `RemoteHost` connects again with its backoff.
protocol ServerEndpoint: AnyObject, Sendable {
    /// A connection that is up. Throws when the endpoint has none to give:
    /// the pane is then gone from this endpoint.
    func connection() async throws -> any ServerLink
    /// What a pane's view opens its channel with. Throws when the endpoint
    /// has none to give: the pane is then gone from this endpoint. The
    /// default is `connection()`, which relays the channel. The local
    /// endpoint gives the sessions' own sockets (`SessionSockets`).
    func paneChannels() async throws -> any PaneChannelOpener
    /// Every session, or nil when the server cannot be reached.
    func list() async -> [SessionInfo]?
    /// Ends a session and takes its exit status. A session that is not there
    /// is no error.
    func kill(_ session: String) async
    /// Runs a command to its end (`command.run`). nil when the server did not
    /// answer in time.
    func run(_ argv: [String], timeout: Duration) async -> MactermProtocol.CommandRun.Result?
}

extension ServerEndpoint {
    func paneChannels() async throws -> any PaneChannelOpener {
        try await connection()
    }

    func list() async -> [SessionInfo]? {
        do {
            let link = try await connection()
            return try await link.call(MactermProtocol.SessionList.self, .init(), timeout: serverRequestTimeout)
                .sessions.map(SessionInfo.init)
        } catch {
            logger.warning("session list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func kill(_ session: String) async {
        do {
            let link = try await connection()
            _ = try await link.call(MactermProtocol.SessionKill.self, .init(id: session), timeout: serverRequestTimeout)
        } catch let ProtocolControlError.errorResponse(info) where info.errorCode == .notFound {
            return
        } catch {
            logger.warning("session kill \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    func run(_ argv: [String], timeout: Duration) async -> MactermProtocol.CommandRun.Result? {
        let args = MactermProtocol.CommandRun.Args(
            argv: argv.map { ProtocolBin(Data($0.utf8)) },
            cwd: nil,
            timeoutMs: UInt32(timeout.components.seconds * 1000)
        )
        do {
            let link = try await connection()
            return try await link.call(MactermProtocol.CommandRun.self, args, timeout: serverRequestTimeout)
        } catch {
            logger.warning("command failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
