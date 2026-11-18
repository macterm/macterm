import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "LinkTransport")

/// The client end of the roaming link (design/009): UDP to a host's server,
/// seen from the rest of the app as one connected stream socket.
///
/// `connectionFD` is one end of a socket pair. `ServerConnection.handshake`
/// takes it, and every pane channel, request and event works over it as over
/// any other connection. A thread joins the other end to UDP: bytes from the
/// socket go into a `LinkStream`, and `LinkPacketCodec` seals each packet.
///
/// The transport never stops sending keepalives, so the host learns the new
/// address after a network change, and a link that the host kept comes back
/// on its own. `pathChanged` opens a new UDP socket, which has a new local
/// port on the new network. A link that hears nothing for `deadAfter` (awake
/// time: the clock stops while the Mac sleeps) closes the socket pair, which
/// the connection sees as a lost connection.
final class LinkTransport: @unchecked Sendable {
    /// The end for `ServerConnection.handshake`. The connection owns it.
    let connectionFD: Int32

    /// No authenticated packet for this long (awake) ends the link.
    static let deadAfter: Int64 = 5 * 60 * 1000
    /// No authenticated packet for this long (awake) makes the link quiet:
    /// the host misses three keepalives (`LinkStream.keepalive`). The link
    /// stays, but the host cannot be reached now.
    static let quietAfter: Int64 = 10 * 1000

    static func isQuiet(now: Int64, lastRx: Int64) -> Bool {
        now - lastRx >= quietAfter
    }

    /// A packet after this long (awake) with no packet says that the host
    /// answers again. It is one keepalive (`LinkStream.keepalive`) and 2 s
    /// for delay, shorter than `quietAfter`. One lost keepalive also gives
    /// the sign. The host answers then, so a try of a lost pane can work.
    static let answersAfter: Int64 = LinkStream.keepalive + 2000

    static func answersAgain(now: Int64, lastRx: Int64) -> Bool {
        now - lastRx >= answersAfter
    }

    private let pump: Int32
    private let host: String
    private let port: UInt16
    private let codec: LinkPacketCodec
    private var stream = LinkStream()
    private let lock = NSLock()
    private var wake: (read: Int32, write: Int32) = (-1, -1)
    private var stopped = false
    /// The wake pipe is closed: `poke` writes nothing more. Under `lock`.
    private var closed = false
    private var rebindRequested = false
    private var started = false
    private var onDead: (@Sendable () -> Void)?
    /// Runs on the thread when the link becomes quiet, and when a packet
    /// comes again. It says only that the state changed: read `isQuiet`.
    private var onQuiet: (@Sendable () -> Void)?
    /// Runs on the thread when a packet comes after `answersAfter` with no
    /// packet.
    private var onAnswered: (@Sendable () -> Void)?
    /// Under `lock`.
    private var quiet = false

    /// The link hears nothing from the host now (`quietAfter`).
    var isQuiet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return quiet
    }

    private var udp: Int32 = -1
    private var remote = sockaddr_storage()
    private var remoteLength: socklen_t = 0
    private var remoteFamily: Int32 = AF_INET
    private var lastRx: Int64 = 0
    /// Stream bytes for the socket pair that did not fit yet.
    private var toPump = Data()
    /// The counter of what we send is spent.
    private var exhausted = false

    private static let toPumpCap = 1024 * 1024

    enum Failure: Error {
        case system(String)
        case unresolved
    }

    init(host: String, port: UInt16, key: Data, keyID: UInt32) throws {
        let codec = try LinkPacketCodec(key: key, keyID: keyID, sends: .clientToHost)
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure.system("socketpair") }
        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
            throw Failure.system("pipe")
        }
        self.codec = codec
        connectionFD = pair[0]
        pump = pair[1]
        self.wake = (wake[0], wake[1])
        self.host = host
        self.port = port
        for fd in [pump, self.wake.read, self.wake.write] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(connectionFD, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(connectionFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(pump, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Starts the thread. `onDead` runs once, on the thread, when the link
    /// ends by itself. `onQuiet` runs on the thread when the quiet state of
    /// the link changes. `onAnswered` runs on the thread when the host
    /// answers after a gap (`answersAfter`).
    func start(
        onDead: @escaping @Sendable () -> Void,
        onQuiet: @escaping @Sendable () -> Void = {},
        onAnswered: @escaping @Sendable () -> Void = {}
    ) throws {
        lock.lock()
        let wasStopped = stopped
        lock.unlock()
        guard !wasStopped else { throw Failure.system("stopped") }
        try resolve()
        try openSocket()
        lock.lock()
        self.onDead = onDead
        self.onQuiet = onQuiet
        self.onAnswered = onAnswered
        started = true
        lock.unlock()
        let thread = Thread { [self] in run() }
        thread.name = "LinkTransport"
        thread.start()
    }

    /// Ends the transport. The socket pair closes, so the connection ends.
    func stop() {
        lock.lock()
        let wasStarted = started
        let already = stopped
        stopped = true
        onDead = nil
        onQuiet = nil
        onAnswered = nil
        lock.unlock()
        if already { return }
        if wasStarted {
            poke()
        } else {
            teardown()
        }
    }

    /// The network changed: use a new socket, so that the packets leave on
    /// the new path.
    func pathChanged() {
        lock.lock()
        rebindRequested = true
        lock.unlock()
        poke()
    }

    private func poke() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(wake.write, &byte, 1)
    }

    // MARK: - Thread

    private func run() {
        lastRx = Self.now()
        var buffer = [UInt8](repeating: 0, count: LinkPacketCodec.maxPacket + 1)
        var dead = false
        while true {
            lock.lock()
            let quit = stopped
            let rebind = rebindRequested
            rebindRequested = false
            lock.unlock()
            if quit { break }
            if rebind, (try? openSocket()) != nil { stream.nudge() }

            let now = Self.now()
            transmit(now: now)
            if exhausted || now - lastRx >= Self.deadAfter {
                dead = true
                break
            }
            reportQuiet(Self.isQuiet(now: now, lastRx: lastRx))

            var fds = [
                pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
                pollfd(fd: udp, events: Int16(POLLIN), revents: 0),
                pollfd(fd: pump, events: Int16((stream.room > 0 ? POLLIN : 0) | (toPump.isEmpty ? 0 : POLLOUT)), revents: 0),
            ]
            let wait = max(0, min(stream.deadline(now: now), lastRx + Self.deadAfter) - now)
            _ = poll(&fds, nfds_t(fds.count), Int32(min(wait, 1000)))
            let after = Self.now()

            if fds[0].revents & Int16(POLLIN) != 0 {
                var drain = [UInt8](repeating: 0, count: 64)
                _ = Darwin.read(wake.read, &drain, drain.count)
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let answered = readUDP(&buffer, now: after)
                // Quiet first, so the host is not quiet when it answers.
                reportQuiet(Self.isQuiet(now: after, lastRx: lastRx))
                if answered { reportAnswered() }
            }
            if fds[2].revents & Int16(POLLIN) != 0, !readPump() {
                break
            }
            if !flushToPump() { break }
            if fds[2].revents & Int16(POLLHUP | POLLERR) != 0 { break }
        }
        let callback: (@Sendable () -> Void)?
        lock.lock()
        callback = dead ? onDead : nil
        onDead = nil
        onQuiet = nil
        onAnswered = nil
        stopped = true
        lock.unlock()
        teardown()
        callback?()
    }

    private func reportQuiet(_ now: Bool) {
        lock.lock()
        guard now != quiet else {
            lock.unlock()
            return
        }
        quiet = now
        let callback = onQuiet
        lock.unlock()
        callback?()
    }

    private func reportAnswered() {
        lock.lock()
        let callback = onAnswered
        lock.unlock()
        callback?()
    }

    private func transmit(now: Int64) {
        guard udp >= 0 else { return }
        var count = 0
        while count < 64, let payload = stream.next(now: now) {
            count += 1
            guard let sealed = try? codec.seal(payload) else {
                // The counter is spent: the link is done.
                exhausted = true
                return
            }
            sealed.withUnsafeBytes { raw in
                withUnsafePointer(to: &remote) { storage in
                    storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        _ = sendto(udp, raw.baseAddress, raw.count, 0, address, remoteLength)
                    }
                }
            }
        }
    }

    /// True when an authenticated packet ended a gap (`answersAgain`).
    private func readUDP(_ buffer: inout [UInt8], now: Int64) -> Bool {
        var answered = false
        for _ in 0 ..< 64 {
            let got = recv(udp, &buffer, buffer.count, 0)
            if got < 0 { break }
            guard got >= LinkPacketCodec.overhead, got <= LinkPacketCodec.maxPacket else { continue }
            guard let opened = try? codec.open(Data(buffer[0 ..< got])) else { continue }
            if Self.answersAgain(now: now, lastRx: lastRx) { answered = true }
            lastRx = now
            if let bytes = stream.receive(now: now, opened.payload), !bytes.isEmpty {
                toPump.append(bytes)
            }
        }
        return answered
    }

    /// False when the socket pair ended.
    private func readPump() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let want = min(chunk.count, stream.room)
        guard want > 0 else { return true }
        let count = Darwin.read(pump, &chunk, want)
        if count < 0 { return errno == EAGAIN || errno == EINTR }
        if count == 0 { return false }
        _ = stream.write(Data(chunk[0 ..< count]))
        return true
    }

    /// False when the socket pair ended or too much waits.
    private func flushToPump() -> Bool {
        if toPump.count > Self.toPumpCap { return false }
        while !toPump.isEmpty {
            let written = toPump.withUnsafeBytes { Darwin.write(pump, $0.baseAddress, $0.count) }
            if written < 0 { return errno == EAGAIN || errno == EINTR }
            toPump.removeFirst(written)
        }
        return true
    }

    // MARK: - Sockets

    /// Resolves the host once, at the start: a rebind must not wait for DNS
    /// before the network is up.
    private func resolve() throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw Failure.unresolved
        }
        defer { freeaddrinfo(result) }
        var address = sockaddr_storage()
        memcpy(&address, first.pointee.ai_addr, Int(first.pointee.ai_addrlen))
        remote = address
        remoteLength = first.pointee.ai_addrlen
        remoteFamily = first.pointee.ai_family
    }

    /// Opens a new UDP socket, closing the old one.
    private func openSocket() throws {
        let fd = socket(remoteFamily, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure.system("socket") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if udp >= 0 { Darwin.close(udp) }
        udp = fd
    }

    private func teardown() {
        lock.lock()
        closed = true
        lock.unlock()
        if udp >= 0 { Darwin.close(udp) }
        udp = -1
        Darwin.close(pump)
        Darwin.close(wake.read)
        Darwin.close(wake.write)
    }

    /// Awake milliseconds: the clock does not run while the Mac sleeps.
    static func now() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
