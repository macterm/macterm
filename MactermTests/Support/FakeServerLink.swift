import Foundation
@testable import Macterm

/// A server link in memory that speaks frames (F11). A request goes to
/// `answer`; a pane channel is a `PaneChannel` whose frames the test
/// writes with `deliver`, and whose frames from the client it reads in
/// `sent`. No socket, no thread, no server.
final class FakeServerLink: ServerLink, @unchecked Sendable {
    /// Answers a request by its method name and arguments. Throw to fail
    /// it. The value must be the method's `Result`.
    typealias Answer = @Sendable (_ method: String, _ args: Any) throws -> Any

    private let lock = NSLock()
    private var open = true
    private var nextChannel: UInt32 = 1
    private var channels: [UInt32: PaneChannel] = [:]
    private var sessions: [String: UInt32] = [:]
    private var frames: [ProtocolFrame] = []
    private var methods: [String] = []
    private let answer: Answer
    /// The session epoch that `channel.open` gives. Nil is a server that
    /// gives none.
    private let epoch: UInt64?

    init(epoch: UInt64? = nil, answer: @escaping Answer = FakeServerLink.standard) {
        self.epoch = epoch
        self.answer = answer
    }

    /// Answers `session.create`, `session.kill`, `channel.close` and
    /// `command.run` with an empty success. `channel.open` is the link's own.
    static let standard: Answer = { method, args in
        switch method {
        case MactermProtocol.SessionCreate.name:
            let id = (args as? MactermProtocol.SessionCreate.Args)?.id ?? ""
            return MactermProtocol.SessionCreate.Result(session: .init(
                id: id,
                state: .running,
                build: "fake",
                level: MactermProtocol.level
            ))
        case MactermProtocol.SessionKill.name: return MactermProtocol.SessionKill.Result()
        case MactermProtocol.ChannelClose.name: return MactermProtocol.ChannelClose.Result()
        case MactermProtocol.SessionList.name: return MactermProtocol.SessionList.Result(sessions: [])
        default: throw ServerClientError.protocolError
        }
    }

    var isOpen: Bool {
        lock.withLock { open }
    }

    /// The method names of every request, in order.
    var calls: [String] {
        lock.withLock { methods }
    }

    /// Every pane message that the client sent on `session`'s channel, by
    /// its type name, in order. Input bytes are `"bytes"`.
    func sent(on session: String) -> [String] {
        lock.withLock {
            guard let number = sessions[session] else { return [] }
            return frames.filter { $0.channel == number }.map { frame in
                guard frame.kind == .msg else { return "bytes" }
                return (try? MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: frame.body))?.t ?? "?"
            }
        }
    }

    /// Each `attach` that the client sent on `session`'s channel, in order.
    func attaches(on session: String) -> [MactermProtocol.Attach] {
        lock.withLock {
            guard let number = sessions[session] else { return [] }
            return frames.filter { $0.channel == number && $0.kind == .msg }.compactMap { frame in
                guard let message = try? MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: frame.body),
                      case let .attach(attach) = try? message.decoded()
                else { return nil }
                return attach
            }
        }
    }

    /// The input bytes that the client sent on `session`'s channel.
    func input(on session: String) -> Data {
        lock.withLock {
            guard let number = sessions[session] else { return Data() }
            return frames.filter { $0.channel == number && $0.kind == .bytes }.reduce(into: Data()) { $0.append($1.body) }
        }
    }

    func call<M: ProtocolMethod>(_ method: M.Type, _ args: M.Args, timeout _: Duration?) async throws -> M.Result {
        guard isOpen else { throw ServerClientError.disconnected }
        lock.withLock { methods.append(M.name) }
        guard let result = try answer(M.name, args) as? M.Result else { throw ServerClientError.protocolError }
        return result
    }

    func openChannel(session: String) async throws -> PaneChannel {
        try lock.withLock {
            guard open else { throw ServerClientError.disconnected }
            methods.append(MactermProtocol.ChannelOpen.name)
            let number = nextChannel
            nextChannel += 1
            let channel = PaneChannel(connection: self, number: number, epoch: epoch)
            channels[number] = channel
            sessions[session] = number
            return channel
        }
    }

    func send(frame: ProtocolFrame) throws {
        try lock.withLock {
            guard open else { throw ServerClientError.disconnected }
            frames.append(frame)
        }
    }

    func releaseChannel(_ number: UInt32) {
        let channel = lock.withLock { channels.removeValue(forKey: number) }
        channel?.sink.finish()
    }

    /// Ends the link: every channel ends with no exit.
    func close() {
        let ended = lock.withLock {
            open = false
            defer { channels = [:] }
            return Array(channels.values)
        }
        for channel in ended {
            channel.sink.finish()
        }
    }

    // MARK: - What the server sends

    /// Output bytes on `session`'s channel.
    func deliver(output: String, to session: String) {
        deliver(ProtocolFrame(channel: 0, kind: .bytes, body: Data(output.utf8)), to: session)
    }

    /// A pane message on `session`'s channel.
    func deliver(_ message: some ProtocolMessage, to session: String) {
        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(message).encode(to: &writer)
        deliver(ProtocolFrame(channel: 0, kind: .msg, body: writer.data), to: session)
    }

    private func deliver(_ frame: ProtocolFrame, to session: String) {
        let channel: PaneChannel? = lock.withLock {
            guard let number = sessions[session] else { return nil }
            return channels[number]
        }
        guard let channel else { return }
        channel.sink.deliver(ProtocolFrame(channel: channel.number, kind: frame.kind, body: frame.body))
    }
}

/// An endpoint that gives the links of a list, one for each connect, and
/// then fails: the test decides each connection.
final class FakeEndpoint: ServerEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [FakeServerLink]
    private var given: [FakeServerLink] = []

    init(_ links: [FakeServerLink]) {
        self.links = links
    }

    /// The links that the endpoint gave, in order.
    var connected: [FakeServerLink] {
        lock.withLock { given }
    }

    func connection() async throws -> any ServerLink {
        try lock.withLock {
            guard !links.isEmpty else { throw ServerClientError.noAnswer }
            let link = links.removeFirst()
            given.append(link)
            return link
        }
    }
}

/// The local endpoint of a test: a connection to the test's own server for
/// each connect. With `once`, it gives one connection only, as a host's link
/// does.
final class TestServerEndpoint: ServerEndpoint, @unchecked Sendable {
    private let server: LocalServer
    private let once: Bool
    private let lock = NSLock()
    private var stored: ServerConnection?
    private var count = 0

    init(_ server: LocalServer, once: Bool = false) {
        self.server = server
        self.once = once
    }

    /// The last connection that the endpoint gave.
    var current: ServerConnection? {
        lock.withLock { stored }
    }

    func connection() async throws -> any ServerLink {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        guard first || !once else { throw ServerClientError.disconnected }
        let connection = try await server.connect()
        lock.withLock { stored = connection }
        return connection
    }
}
