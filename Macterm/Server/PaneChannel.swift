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
    /// The shell's folder as an OSC 7 URL.
    case cwd(Data)
    case foreground(MactermProtocol.Foreground)
    case ttyMode(MactermProtocol.TtyMode)
    case attention(MactermProtocol.Attention)
    /// An OSC 133 mark of the shell, which the session parsed. A client that
    /// greets while the shell is at its prompt gets a `prompt` mark too.
    case mark(MactermProtocol.Mark)
    /// The run state of the pane. The session sends it only when it changes,
    /// and to a client that greets while it is not `idle`.
    case status(MactermProtocol.Status)
    /// A desktop notification that a program asked for (OSC 9, OSC 777).
    case notification(title: Data, body: Data)
    /// The program rang the bell (BEL).
    case bell
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
        case let .cwd(cwd): .cwd(cwd.url.bytes)
        case let .foreground(foreground): .foreground(foreground)
        case let .ttyMode(mode): .ttyMode(mode)
        case let .attention(flags): .attention(flags)
        case let .mark(mark): .mark(mark)
        case let .status(status): .status(status)
        case let .desktopNotification(note): .notification(title: note.title.bytes, body: note.body.bytes)
        case .bell: .bell
        default: .other(name)
        }
    }
}

/// What carries one pane channel: a server's connection, which relays it
/// (`ServerLink`), or a session's own socket (`SessionSocket`).
protocol PaneChannelTransport: AnyObject, Sendable {
    /// Sends a frame on the channel. Throws `disconnected` when the link
    /// ended.
    func send(frame: ProtocolFrame) throws
    /// Ends the channel. Its events end. The session keeps running.
    func closeChannel(_ number: UInt32) async
}

/// What a pane's session opens its view channels with: a server's
/// connection (`ServerLink`), or the sockets of the local sessions
/// (`SessionSockets`).
protocol PaneChannelOpener: AnyObject, Sendable {
    /// Opens a pane channel to `session` (design/003 §1).
    func openChannel(session: String) async throws -> PaneChannel
}

/// One pane's channel: the surface's view of its session. Output and the
/// session's messages come through `events`, in order, and end when the
/// channel or its link ends. A caller writes input from a queue of its own:
/// a write that the peer does not take fails after 10 s. Call `close()`
/// when done.
///
/// On a server's connection the events buffer without a limit, because one
/// reader serves every channel and must never wait. On a session's own
/// socket (`readAhead`) the reader waits while that many events are not
/// taken: the socket then fills, and the session holds the output
/// (design/001, Back-pressure).
final class PaneChannel: @unchecked Sendable {
    let number: UInt32
    /// The `epoch` of the session's `hello`. Nil from a server that does
    /// not give it: the channel cannot resume.
    let epoch: UInt64?
    /// The `caps` of the session's `hello`: what the session sends. Empty
    /// from a server or a session of an older build.
    let caps: [String]
    let events: Events

    private weak var transport: (any PaneChannelTransport)?
    let sink: Sink

    /// The reader's side: turns frames into events.
    final class Sink: @unchecked Sendable {
        private let continuation: AsyncStream<PaneChannelEvent>.Continuation
        fileprivate let credit: Credit?

        fileprivate init(_ continuation: AsyncStream<PaneChannelEvent>.Continuation, credit: Credit?) {
            self.continuation = continuation
            self.credit = credit
        }

        /// With a read-ahead limit, waits while the limit is reached.
        func deliver(_ frame: ProtocolFrame) {
            guard let event = PaneChannelEvent(frame) else {
                logger.error("pane channel: a frame could not be read, kind=\(frame.kind.rawValue, privacy: .public)")
                return
            }
            guard credit?.take() ?? true else { return }
            continuation.yield(event)
        }

        func finish() {
            credit?.end()
            continuation.finish()
        }
    }

    /// The count of events that the reader gave and the consumer did not
    /// take yet.
    fileprivate final class Credit: @unchecked Sendable {
        private let condition = NSCondition()
        private let limit: Int
        private var given = 0
        private var ended = false

        init(limit: Int) {
            self.limit = limit
        }

        /// Waits for room. False once the channel ended.
        func take() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            while given >= limit, !ended {
                condition.wait()
            }
            guard !ended else { return false }
            given += 1
            return true
        }

        func taken() {
            condition.lock()
            given -= 1
            condition.signal()
            condition.unlock()
        }

        func end() {
            condition.lock()
            ended = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The events of the channel. Each event that the consumer takes gives
    /// the reader room for one more.
    struct Events: AsyncSequence {
        typealias Element = PaneChannelEvent
        fileprivate let stream: AsyncStream<PaneChannelEvent>
        fileprivate let credit: Credit?

        struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate var base: AsyncStream<PaneChannelEvent>.AsyncIterator
            fileprivate let credit: Credit?

            mutating func next() async -> PaneChannelEvent? {
                let event = await base.next()
                if event != nil { credit?.taken() }
                return event
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator(), credit: credit)
        }
    }

    /// `readAhead` is the most events that wait for the consumer; nil for
    /// no limit.
    init(
        transport: any PaneChannelTransport,
        number: UInt32,
        epoch: UInt64? = nil,
        caps: [String] = [],
        readAhead: Int? = nil
    ) {
        self.transport = transport
        self.number = number
        self.epoch = epoch
        self.caps = caps
        let (stream, continuation) = AsyncStream.makeStream(of: PaneChannelEvent.self, bufferingPolicy: .unbounded)
        let credit = readAhead.map(Credit.init(limit:))
        events = Events(stream: stream, credit: credit)
        sink = Sink(continuation, credit: credit)
    }

    /// Keys, pastes and terminal replies for the session. Never dropped.
    func sendInput(_ data: Data) throws {
        guard let transport else { throw ServerClientError.disconnected }
        try transport.send(frame: ProtocolFrame(channel: number, kind: .bytes, body: data))
    }

    /// A message of the pane (`attach`, `resize`, `claim`).
    func send(_ message: some ProtocolMessage) throws {
        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(message).encode(to: &writer)
        guard let transport else { throw ServerClientError.disconnected }
        try transport.send(frame: ProtocolFrame(channel: number, kind: .msg, body: writer.data))
    }

    /// Ends the channel. The session keeps running.
    func close() async {
        await transport?.closeChannel(number)
    }
}
