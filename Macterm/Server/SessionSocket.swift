import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "SessionSocket")

/// The sockets of the local sessions, as a pane's view opens its channel
/// (design/001: "Locally, pane bytes go from the GUI to the session socket
/// directly"). Each channel is a connection of its own to the session's
/// socket in the runtime directory, so a server that crashes, exits or is
/// replaced does not touch typing. The server still makes, lists and ends
/// the sessions.
final class SessionSockets: PaneChannelOpener {
    /// The most events of one channel that wait for the pane. Then the
    /// reader stops, the socket fills, and the session holds the output.
    static let readAhead = 64

    private let directory: URL
    private let exitRead: @Sendable (String) -> Void

    /// `exitRead` gets the session's name when a channel got its exit
    /// status. The server ends a session whose status a client read
    /// (`registry.statusRead`), and it does not see this channel.
    init(directory: URL, exitRead: @escaping @Sendable (String) -> Void) {
        self.directory = directory
        self.exitRead = exitRead
    }

    /// Connects to the session's socket and greets it. Throws
    /// `SessionSocket.Gone` when no session listens there.
    func openChannel(session: String) async throws -> PaneChannel {
        let path = directory.appending(path: session).path
        let exitRead = exitRead
        // The connect and the handshake block: not on the pool of Swift's
        // tasks.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try SessionSocket.open(path: path) { exitRead(session) } })
            }
        }
    }
}

/// One connection to a session's own socket: one pane channel. A thread of
/// its own reads the socket. The session speaks the frames of the server's
/// relay: `hello` on channel 0, then the pane on channel 1.
final class SessionSocket: PaneChannelTransport, @unchecked Sendable {
    /// No session listens at the path: it ended, or it was never made.
    struct Gone: Error, Equatable {}

    /// The pane channel of a session's socket (`m.pane_channel`).
    static let paneChannel: UInt32 = 1
    /// How long the session may take to answer the handshake.
    static let handshakeTimeout: TimeInterval = 5

    private let fd: Int32
    private let fdLock = NSLock()
    private var fdIsOpen = true
    private var sink: PaneChannel.Sink?

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connects and greets: this blocks for up to `handshakeTimeout`.
    /// `exitRead` runs on the reader thread, once, when the channel gets the
    /// session's exit.
    static func open(path: String, exitRead: @escaping @Sendable () -> Void) throws -> PaneChannel {
        let fd: Int32
        do {
            fd = try ServerConnection.connectSocket(path: path)
        } catch where error.code == ENOENT || error.code == ECONNREFUSED {
            throw Gone()
        } catch {
            throw ServerClientError.noAnswer
        }
        var reader = FrameReader(fd: fd)
        let hello: MactermProtocol.Hello
        do {
            hello = try ServerConnection.greet(fd: fd, reader: &reader, timeout: handshakeTimeout)
        } catch {
            Darwin.close(fd)
            throw error
        }
        let socket = SessionSocket(fd: fd)
        let channel = PaneChannel(
            transport: socket,
            number: paneChannel,
            epoch: hello.epoch,
            buffering: .readAhead(SessionSockets.readAhead)
        )
        socket.startReading(reader, into: channel.sink, exitRead: exitRead)
        return channel
    }

    func send(frame: ProtocolFrame) throws {
        let data = try frame.encoded()
        fdLock.lock()
        defer { fdLock.unlock() }
        guard fdIsOpen else { throw ServerClientError.disconnected }
        try ServerConnection.writeAll(fd, data)
    }

    /// Ends the connection and the events. The reader closes the fd: it
    /// wakes also when it waits for the pane to take events.
    func closeChannel(_: UInt32) async {
        let sink = fdLock.withLock {
            if fdIsOpen { Darwin.shutdown(fd, SHUT_RDWR) }
            return self.sink
        }
        sink?.finish()
    }

    private func startReading(_ reader: FrameReader, into sink: PaneChannel.Sink, exitRead: @escaping @Sendable () -> Void) {
        fdLock.withLock { self.sink = sink }
        let thread = Thread { [self] in
            var reader = reader
            var exited = false
            while true {
                do {
                    let frame = try reader.next()
                    if frame.channel == ProtocolFrame.controlChannel {
                        // The session has no requests and no events. A
                        // `refuse` ends the link.
                        if case .refuse = try ProtocolControl.decode(frame.body) { break }
                        continue
                    }
                    guard frame.channel == Self.paneChannel else { continue }
                    if !exited, Self.isExit(frame) {
                        exited = true
                        exitRead()
                    }
                    sink.deliver(frame)
                } catch {
                    if case ServerClientError.disconnected = error {} else {
                        logger.error("session socket: \(String(describing: error), privacy: .public)")
                    }
                    break
                }
            }
            sink.finish()
            fdLock.lock()
            fdIsOpen = false
            Darwin.close(fd)
            fdLock.unlock()
        }
        thread.name = "SessionSocket"
        thread.start()
    }

    private static func isExit(_ frame: ProtocolFrame) -> Bool {
        guard frame.kind == .msg,
              let message = try? MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: frame.body)
        else { return false }
        if case .exit = try? message.decoded() { return true }
        return false
    }
}
