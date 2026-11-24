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
    /// The app dropped output of a relayed channel that the pane did not
    /// take in time (`PaneChannel.Buffering.skipAhead`). The session's
    /// snapshot follows: the output up to it does not come.
    case skipped
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

/// A transport whose channels pause: a server's connection, which relays
/// them (`ServerLink`). A session's own socket does not pause: its reader
/// waits at the read-ahead limit, and the session holds the output.
protocol PausingChannelTransport: PaneChannelTransport {
    /// Stops or starts the output of the channel. The session's messages
    /// still come while it is paused, and a resume brings a snapshot
    /// (design/003 §6).
    func setPaused(_ paused: Bool, channel number: UInt32) async throws
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
/// What waits for the consumer has a limit (`Buffering`). On a session's
/// own socket the reader waits at the limit: the socket then fills, and the
/// session holds the output (design/001, Back-pressure). On a server's
/// connection one reader serves every channel and must never wait: over the
/// limit the channel drops its output and asks the session for a snapshot,
/// as the server's skip-ahead does (design/003 §6).
final class PaneChannel: @unchecked Sendable {
    /// What waits for the consumer of the events, and what the reader does
    /// at the limit.
    enum Buffering: Equatable {
        /// The reader waits while this many events are not taken.
        case readAhead(Int)
        /// The reader never waits. When more than `bytes` of output are not
        /// taken, it drops the output up to the next snapshot, sends
        /// `skipped`, and asks the session for a snapshot, again after each
        /// `askAgain` until the snapshot starts. The session's messages are
        /// not counted: they are small, and the session coalesces them.
        case skipAhead(bytes: Int, askAgain: DispatchTimeInterval = PaneChannel.snapshotWait)
    }

    /// The most output bytes of a relayed channel that wait for the pane:
    /// the cap of the server's skip-ahead for one channel
    /// (`relay.skip_bytes`).
    static let relayLimit = 1024 * 1024
    /// How long a skipped channel waits for its snapshot before it asks
    /// again: the server's `relay.skip_ms`. A session that is behind sends
    /// its snapshot when it catches up, and ignores the request before that.
    static let snapshotWait: DispatchTimeInterval = .seconds(1)

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
        fileprivate let skip: SkipAhead?
        private weak var transport: (any PaneChannelTransport)?
        private let number: UInt32
        /// The requests for a snapshot, off the reader's thread: a write can
        /// wait for the peer, and the reader must not. One queue for each
        /// channel, so that a stalled link holds only its own requests.
        private let requests = DispatchQueue(label: "PaneChannel.requests")

        fileprivate init(
            _ continuation: AsyncStream<PaneChannelEvent>.Continuation,
            credit: Credit?,
            skip: SkipAhead?,
            transport: any PaneChannelTransport,
            number: UInt32
        ) {
            self.continuation = continuation
            self.credit = credit
            self.skip = skip
            self.transport = transport
            self.number = number
        }

        /// With a read-ahead limit, waits while the limit is reached. With a
        /// skip-ahead limit, never waits.
        func deliver(_ frame: ProtocolFrame) {
            guard let event = PaneChannelEvent(frame) else {
                logger.error("pane channel: a frame could not be read, kind=\(frame.kind.rawValue, privacy: .public)")
                return
            }
            if let skip {
                switch skip.admit(event) {
                case .pass: break
                case .drop: return
                case let .skip(generation):
                    logger.info("pane channel \(self.number, privacy: .public): the pane fell behind, output dropped")
                    continuation.yield(.skipped)
                    askSnapshot(generation)
                    return
                }
            }
            guard credit?.take() ?? true else { return }
            continuation.yield(event)
        }

        func finish() {
            credit?.end()
            skip?.end()
            continuation.finish()
        }

        /// Asks the session for a snapshot (`refresh`), and again after each
        /// `askAgain` while the skip waits for it.
        private func askSnapshot(_ generation: Int) {
            requests.async { [weak self] in
                guard let self, let transport, let skip, skip.waits(generation) else { return }
                do {
                    try transport.send(frame: PaneChannel.frame(MactermProtocol.Refresh(), on: number))
                } catch {
                    // The channel ends with its link.
                    return
                }
                requests.asyncAfter(deadline: .now() + skip.askAgain) { [weak self] in
                    self?.askSnapshot(generation)
                }
            }
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

    /// The output bytes that the reader gave and the consumer did not take
    /// yet, and the skip that drops output up to the next snapshot. A
    /// snapshot is never cut: its bytes always pass, so the pane draws it
    /// whole.
    fileprivate final class SkipAhead: @unchecked Sendable {
        enum Verdict: Equatable {
            case pass
            case drop
            /// The limit is reached: a skip starts.
            case skip(generation: Int)
        }

        private let lock = NSLock()
        private let limit: Int
        let askAgain: DispatchTimeInterval
        private var waiting = 0
        private var inSnapshot = false
        private var skipping = false
        /// Tells a skip from the skips before it.
        private var generation = 0
        private var ended = false

        init(limit: Int, askAgain: DispatchTimeInterval) {
            self.limit = limit
            self.askAgain = askAgain
        }

        func admit(_ event: PaneChannelEvent) -> Verdict {
            lock.lock()
            defer { lock.unlock() }
            switch event {
            case .snapshotStart:
                inSnapshot = true
                skipping = false
            case .snapshotEnd:
                inSnapshot = false
            case let .output(data):
                if inSnapshot {
                    waiting += data.count
                } else if skipping {
                    return .drop
                } else if waiting + data.count > limit {
                    skipping = true
                    generation += 1
                    return .skip(generation: generation)
                } else {
                    waiting += data.count
                }
            default:
                break
            }
            return .pass
        }

        /// The consumer took `event`.
        func taken(_ event: PaneChannelEvent) {
            guard case let .output(data) = event else { return }
            lock.withLock { waiting -= data.count }
        }

        /// True while the skip `generation` waits for its snapshot.
        func waits(_ generation: Int) -> Bool {
            lock.withLock { skipping && self.generation == generation && !ended }
        }

        func end() {
            lock.withLock { ended = true }
        }
    }

    /// The events of the channel. Each event that the consumer takes gives
    /// the reader room for one more.
    struct Events: AsyncSequence {
        typealias Element = PaneChannelEvent
        fileprivate let stream: AsyncStream<PaneChannelEvent>
        fileprivate let credit: Credit?
        fileprivate let skip: SkipAhead?

        struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate var base: AsyncStream<PaneChannelEvent>.AsyncIterator
            fileprivate let credit: Credit?
            fileprivate let skip: SkipAhead?

            mutating func next() async -> PaneChannelEvent? {
                let event = await base.next()
                if let event {
                    credit?.taken()
                    skip?.taken(event)
                }
                return event
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator(), credit: credit, skip: skip)
        }
    }

    /// `buffering` is the limit of what waits for the consumer; nil for no
    /// limit.
    init(
        transport: any PaneChannelTransport,
        number: UInt32,
        epoch: UInt64? = nil,
        caps: [String] = [],
        buffering: Buffering? = nil
    ) {
        self.transport = transport
        self.number = number
        self.epoch = epoch
        self.caps = caps
        let (stream, continuation) = AsyncStream.makeStream(of: PaneChannelEvent.self, bufferingPolicy: .unbounded)
        var credit: Credit?
        var skip: SkipAhead?
        switch buffering {
        case let .readAhead(count): credit = Credit(limit: count)
        case let .skipAhead(bytes, askAgain): skip = SkipAhead(limit: bytes, askAgain: askAgain)
        case nil: break
        }
        events = Events(stream: stream, credit: credit, skip: skip)
        sink = Sink(continuation, credit: credit, skip: skip, transport: transport, number: number)
    }

    /// A frame of a pane message on channel `number`.
    fileprivate static func frame(_ message: some ProtocolMessage, on number: UInt32) -> ProtocolFrame {
        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(message).encode(to: &writer)
        return ProtocolFrame(channel: number, kind: .msg, body: writer.data)
    }

    /// Keys, pastes and terminal replies for the session. Never dropped.
    func sendInput(_ data: Data) throws {
        guard let transport else { throw ServerClientError.disconnected }
        try transport.send(frame: ProtocolFrame(channel: number, kind: .bytes, body: data))
    }

    /// A message of the pane (`attach`, `resize`, `claim`).
    func send(_ message: some ProtocolMessage) throws {
        guard let transport else { throw ServerClientError.disconnected }
        try transport.send(frame: Self.frame(message, on: number))
    }

    /// True when the channel can pause (`PausingChannelTransport`).
    var pauses: Bool {
        transport is any PausingChannelTransport
    }

    /// Stops the output of a pane that no window shows, or starts it again.
    /// The session's messages still come. A resume brings a snapshot
    /// (design/003 §6). A channel that cannot pause does nothing.
    func setPaused(_ paused: Bool) async throws {
        guard let transport else { throw ServerClientError.disconnected }
        guard let pausing = transport as? any PausingChannelTransport else { return }
        try await pausing.setPaused(paused, channel: number)
    }

    /// Ends the channel. The session keeps running.
    func close() async {
        await transport?.closeChannel(number)
    }
}
