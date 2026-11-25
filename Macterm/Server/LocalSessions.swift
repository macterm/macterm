import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LocalSessions")

/// The app's one connection to the local server, for the sessions of its
/// local panes: the local `ServerEndpoint`. It makes, lists and ends the
/// sessions. A local pane's `PaneSession` opens its channel on the
/// session's own socket (`paneChannels`), not on this connection.
///
/// It connects at the first use, and again after the connection ends (the
/// server exits when it has no session and no client). The server ends a
/// session whose shell exited when a client read the status, so nothing
/// here ends one.
actor LocalSessions: ServerEndpoint {
    static let shared = LocalSessions(server: LocalServer.bundled)

    private let server: LocalServer?
    private var connection: ServerConnection?
    private var connecting: Task<ServerConnection, Error>?

    /// A pane's connect tries this many times, `connectWait` apart, before
    /// the pane is gone: a server that an update replaced, or one that
    /// exited while idle, is back within this time.
    private static let connectTries = 12
    private static let connectWait: Duration = .milliseconds(500)

    init(server: LocalServer?) {
        self.server = server
    }

    /// Every session, or nil when the server cannot be reached.
    func list() async -> [SessionInfo]? {
        do {
            let sessions = try await call(MactermProtocol.SessionList.self, .init()).sessions
            return sessions.map(SessionInfo.init)
        } catch {
            logger.warning("session list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Ends a session and takes its exit status. A session that is not
    /// there is no error.
    func kill(_ name: String) async {
        do {
            _ = try await call(MactermProtocol.SessionKill.self, .init(id: name))
        } catch let ProtocolControlError.errorResponse(info) where info.errorCode == .notFound {
            return
        } catch {
            logger.warning("session kill \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Connects now, so that the first pane does not wait for it.
    func prepare() async {
        _ = try? await connected()
    }

    private func call<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args) async throws -> M.Result {
        let connection = try await connected()
        do {
            return try await connection.call(method, args, timeout: serverRequestTimeout)
        } catch ServerClientError.disconnected {
            // The server exited while idle: one new connection.
            drop(connection)
            let next = try await connected()
            return try await next.call(method, args, timeout: serverRequestTimeout)
        }
    }

    /// The sessions' own sockets: a local pane's bytes never pass through
    /// the server (design/001). Throws when there is no bundled server.
    nonisolated func paneChannels() async throws -> any PaneChannelOpener {
        guard let server else { throw ServerClientError.noAnswer }
        return SessionSockets(directory: server.directory) { [weak self] session in
            Task { await self?.exitRead(session) }
        }
    }

    /// A pane's channel read the exit of `session` on the session's own
    /// socket. `session.info` tells the server: the server ends a session
    /// when a reply shows the status that it read (`registry.statusRead`).
    /// The server hears the exit on its own connection to the session, which
    /// can come after this request: while the reply says `running`, it asks
    /// again. A server that is down is started again by the request.
    private func exitRead(_ session: String) async {
        for _ in 0 ..< Self.exitReadTries {
            do {
                let info = try await call(MactermProtocol.SessionInfo.self, .init(id: session))
                if info.session.state != .running { return }
            } catch let ProtocolControlError.errorResponse(info) where info.errorCode == .notFound {
                return
            } catch {
                logger.info("session info \(session, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            try? await Task.sleep(for: Self.exitReadWait)
        }
        logger.warning("session \(session, privacy: .public): the server did not see its exit")
    }

    /// `exitRead` asks this many times, this far apart.
    private static let exitReadTries = 40
    private static let exitReadWait: Duration = .milliseconds(50)

    /// The connection to the server, made when there is none or when the
    /// last one ended. A pane opens its channel on it. It tries again for a
    /// few seconds before it gives up.
    func connection() async throws -> any ServerLink {
        var tries = 0
        while true {
            do {
                return try await connected()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                tries += 1
                guard tries < Self.connectTries else { throw error }
                logger.info("connect failed, try \(tries, privacy: .public): \(String(describing: error), privacy: .public)")
                try await Task.sleep(for: Self.connectWait)
            }
        }
    }

    private func connected() async throws -> ServerConnection {
        if let connection, connection.isOpen { return connection }
        if let connection { drop(connection) }
        if let connecting { return try await connecting.value }
        guard let server else { throw ServerClientError.noAnswer }
        let task = Task { try await server.connect() }
        connecting = task
        defer { connecting = nil }
        let connection = try await task.value
        self.connection = connection
        watch(connection)
        return connection
    }

    private func drop(_ old: ServerConnection) {
        guard connection === old else { return }
        old.close()
        connection = nil
    }

    /// The model has a connection of its own (`ModelConnection`): this one
    /// only follows the end of the connection.
    private func watch(_ connection: ServerConnection) {
        Task { [weak self] in
            for await _ in connection.events {}
            await self?.drop(connection)
        }
    }
}
