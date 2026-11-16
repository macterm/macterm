import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaneChannel")

/// What a pane channel delivers (design/003 §1): the session's output as raw
/// bytes, and its own messages. A message that this build does not know, or
/// cannot read, is `other`.
enum PaneChannelEvent: Equatable {
    /// Output of the pane, or the bytes of a snapshot between `snapshotStart`
    /// and `snapshotEnd`.
    case output(Data)
    case state(MactermProtocol.State)
    case lead(Bool)
    case snapshotStart(MactermProtocol.SnapshotStart)
    case snapshotEnd
    case resumed(MactermProtocol.Resumed)
    case exit(MactermProtocol.Exit)
    case title(Data)
    case foreground(MactermProtocol.Foreground)
    case ttyMode(MactermProtocol.TtyMode)
    case other(String)

    init?(_ frame: ProtocolFrame) {
        switch frame.kind {
        case .bytes:
            self = .output(frame.body)
        case .msg:
            guard let message = try? MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: frame.body) else {
                return nil
            }
            do {
                self = try Self.event(message.decoded(), name: message.t)
            } catch {
                // A known type that does not read is as bad as a lost frame.
                logger.error("pane channel: message \(message.t, privacy: .public) could not be read")
                self = .other(message.t)
            }
        default:
            return nil
        }
    }

    private static func event(_ kind: MactermProtocol.PaneMessageKind, name: String) -> PaneChannelEvent {
        switch kind {
        case let .state(state): .state(state)
        case let .lead(lead): .lead(lead.leader)
        case let .snapshotStart(start): .snapshotStart(start)
        case .snapshotEnd: .snapshotEnd
        case let .resumed(resumed): .resumed(resumed)
        case let .exit(exit): .exit(exit)
        case let .title(title): .title(title.title.bytes)
        case let .foreground(foreground): .foreground(foreground)
        case let .ttyMode(mode): .ttyMode(mode)
        default: .other(name)
        }
    }
}

/// One pane's channel on a `ServerConnection`: the surface's view of its
/// session. Output and the session's messages come through `events`, in
/// order, and end when the channel or the connection ends. A caller writes
/// input from a queue of its own: a write that the server does not take fails
/// after 10 s. Call `close()` when done:
/// the events buffer without a limit until then.
final class PaneChannel: @unchecked Sendable {
    let number: UInt32
    let events: AsyncStream<PaneChannelEvent>

    private weak var connection: ServerConnection?
    let sink: Sink

    /// The reader thread's side: turns frames into events.
    final class Sink: @unchecked Sendable {
        private let continuation: AsyncStream<PaneChannelEvent>.Continuation

        init(_ continuation: AsyncStream<PaneChannelEvent>.Continuation) {
            self.continuation = continuation
        }

        func deliver(_ frame: ProtocolFrame) {
            if let event = PaneChannelEvent(frame) {
                continuation.yield(event)
            } else {
                logger.error("pane channel: a frame could not be read, kind=\(frame.kind.rawValue, privacy: .public)")
            }
        }

        func finish() {
            continuation.finish()
        }
    }

    init(connection: ServerConnection, number: UInt32) {
        self.connection = connection
        self.number = number
        let (events, continuation) = AsyncStream.makeStream(of: PaneChannelEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        sink = Sink(continuation)
    }

    /// Keys, pastes and terminal replies for the session. Never dropped.
    func sendInput(_ data: Data) throws {
        guard let connection else { throw ServerClientError.disconnected }
        try connection.send(frame: ProtocolFrame(channel: number, kind: .bytes, body: data))
    }

    /// A message of the pane (`attach`, `resize`, `claim`).
    func send(_ message: some ProtocolMessage) throws {
        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(message).encode(to: &writer)
        guard let connection else { throw ServerClientError.disconnected }
        try connection.send(frame: ProtocolFrame(channel: number, kind: .msg, body: writer.data))
    }

    /// Stops the output of a pane that no one sees. The session's messages
    /// still come. `resume` brings a snapshot first (design/003 §6).
    func pause() async throws {
        guard let connection else { throw ServerClientError.disconnected }
        _ = try await connection.call(MactermProtocol.ChannelPause.self, .init(channel: number))
    }

    func resume() async throws {
        guard let connection else { throw ServerClientError.disconnected }
        _ = try await connection.call(MactermProtocol.ChannelResume.self, .init(channel: number))
    }

    /// Ends the channel. The session keeps running.
    func close() async {
        _ = try? await connection?.call(MactermProtocol.ChannelClose.self, .init(channel: number))
        connection?.releaseChannel(number)
    }
}
