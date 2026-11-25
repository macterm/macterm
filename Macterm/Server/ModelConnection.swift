import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ModelConnection")

/// The app's link to the model on the local server (design/010 §4): one
/// connection of its own, `state.subscribe`, the event batches, and the
/// requests that change the model.
///
/// **A request blocks the main actor until its reply** (`send`). The server
/// sends a request's batch before its reply, and the reader thread queues
/// each batch before it hands over the reply, so `send` applies the queued
/// batches to `mirror` before it returns. The caller then reads its own
/// change, as it read a change of v1's model in memory. The round trip on
/// the local socket is under 1 ms (issue 0223: `pane.split` p50 0.27 ms,
/// p99 0.61 ms). The batches of other clients (the CLI) come in a main-queue
/// turn of their own.
///
/// While there is no connection, a request fails at once with
/// `ModelRequestError.unavailable`, and the connection is made again in
/// the background.
@MainActor
final class ModelConnection {
    let mirror: ModelMirror
    private let server: LocalServer?
    private var connection: ServerConnection?
    private var connecting = false
    private let queue = BatchQueue()
    /// Counts the connections, so that a late subscribe of an old one does
    /// nothing.
    private var generation = 0
    /// How long `send` waits for a reply.
    static let requestTimeout: DispatchTimeInterval = .seconds(2)

    /// Called on the main actor after each `state.subscribe` is installed:
    /// the first one, and the one after each new connection.
    var onInstall: ((MactermProtocol.StateSubscribe.Result) -> Void)?

    init(server: LocalServer?, mirror: ModelMirror = ModelMirror()) {
        self.server = server
        self.mirror = mirror
    }

    /// The bundled server, with the model's folder (design/010 §2).
    static func bundled() -> ModelConnection {
        ModelConnection(server: LocalServer.bundled)
    }

    var isConnected: Bool {
        connection?.isOpen == true && mirror.data != nil
    }

    /// Connects and installs the server's state. Returns when the mirror
    /// has the model, or when the connect failed (then it tries again in
    /// the background).
    func connect() async {
        guard !connecting, connection?.isOpen != true else { return }
        guard let server else {
            logger.error("model: no bundled server")
            return
        }
        connecting = true
        defer { connecting = false }
        generation += 1
        let current = generation
        do {
            let link = try await Task.detached { try await server.connect() }.value
            let queue = queue
            link.setBatchHandler { batch in
                queue.append(batch)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in self?.drain() }
                }
            }
            let state = try await link.call(MactermProtocol.StateSubscribe.self, .init(), timeout: serverRequestTimeout)
            guard current == generation else {
                link.close()
                return
            }
            connection = link
            mirror.install(state)
            drain()
            if state.model == nil {
                logger.error("model: the server has no model")
            } else if state.readonly {
                logger.warning("model: the server's model is read-only")
            }
            onInstall?(state)
        } catch {
            logger.error("model: connect failed: \(String(describing: error), privacy: .public)")
            scheduleReconnect()
        }
    }

    /// Ends the connection (tests, quit).
    func close() {
        generation += 1
        connection?.close()
        connection = nil
    }

    /// Sends a request and returns its result after the mirror applied the
    /// request's batch.
    /// With `animated`, the request's batch animates a ratio change
    /// (`TerminalTab.animatedResizeGeneration`): only a batch with a
    /// `cause` is this connection's own.
    @discardableResult
    func send<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args, animated: Bool = false) throws -> M.Result {
        guard let connection, connection.isOpen else {
            scheduleReconnect()
            throw ModelRequestError.unavailable
        }
        do {
            let result = try connection.callBlocking(method, args, timeout: Self.requestTimeout)
            drain(animated: animated)
            return result
        } catch let ProtocolControlError.errorResponse(info) {
            drain()
            throw ModelRequestError.refused(code: info.errorCode, message: info.message)
        } catch {
            logger.error("model: \(M.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw ModelRequestError.unavailable
        }
    }

    /// Applies the batches that came, in order. A nil is the end of the
    /// connection.
    private func drain(animated: Bool = false) {
        for item in queue.takeAll() {
            if let batch = item {
                mirror.apply(batch, animated: animated && batch.cause != nil)
            } else {
                connectionEnded()
            }
        }
    }

    private func connectionEnded() {
        guard connection?.isOpen != true else { return }
        connection = nil
        logger.warning("model: the connection ended")
        scheduleReconnect()
    }

    private var reconnectTask: Task<Void, Never>?

    private func scheduleReconnect() {
        guard reconnectTask == nil, !connecting else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            reconnectTask = nil
            await connect()
        }
    }
}

/// Why a model request did not change the model.
enum ModelRequestError: Error, Equatable {
    /// No connection to the server, or no reply in time.
    case unavailable
    /// The server refused the request.
    case refused(code: MactermProtocol.ErrorCode, message: String)
}

/// The batches that the reader thread got and the main actor did not apply
/// yet. nil is the end of the connection.
private final class BatchQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ServerEventBatch?] = []

    func append(_ batch: ServerEventBatch?) {
        lock.withLock { items.append(batch) }
    }

    func takeAll() -> [ServerEventBatch?] {
        lock.withLock {
            defer { items = [] }
            return items
        }
    }
}
