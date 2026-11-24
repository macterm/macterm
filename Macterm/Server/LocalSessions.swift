import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LocalSessions")

/// The app's one connection to the local server, for the sessions of its
/// local panes: the local `ServerEndpoint`. Each local pane's `PaneSession`
/// opens its channel on it, and it lists and ends the sessions.
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
    /// Where the model's batches go (`ModelShadow`), nil when nothing reads
    /// them.
    private var modelFeed: (@MainActor (ModelFeed) -> Void)?

    /// What `setModelFeed`'s reader gets, in the order of the connection.
    enum ModelFeed {
        /// A new connection, maybe to a new server: subscribe again.
        case connected
        case batch(ServerEventBatch)
    }

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

    /// Sends each batch of model events to `feed`, and `.connected` at each
    /// new connection, the current one included.
    func setModelFeed(_ feed: @escaping @MainActor (ModelFeed) -> Void) async {
        modelFeed = feed
        if let connection, connection.isOpen { await feed(.connected) }
    }

    /// The server's state and this connection's place in its batches.
    func subscribe() async throws -> MactermProtocol.StateSubscribe.Result {
        try await call(MactermProtocol.StateSubscribe.self, .init())
    }

    /// Puts `model` in place of the server's model (the shadow stage,
    /// design/010 §9 step 3).
    func replaceModel(_ model: MactermProtocol.ModelData) async throws {
        _ = try await call(MactermProtocol.ModelReplace.self, .init(model: model))
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

    private func feedModel(_ item: ModelFeed) async {
        guard let modelFeed else { return }
        await modelFeed(item)
    }

    private func drop(_ old: ServerConnection) {
        guard connection === old else { return }
        old.close()
        connection = nil
    }

    private func watch(_ connection: ServerConnection) {
        Task { [weak self] in
            await self?.feedModel(.connected)
            for await batch in connection.events where batch.events.contains(where: \.isModel) {
                await self?.feedModel(.batch(batch))
            }
            await self?.drop(connection)
        }
    }
}
