import Foundation

/// The reliable byte stream under the roaming link (design/009 §3), as
/// `server/src/link/stream.zig` writes it. It does no I/O and keeps no clock:
/// the caller gives the time in ms.
///
/// Payloads, inside the sealed packets of `LinkPacketCodec`:
///
/// - `0x01` DATA: `offset u64`, bytes. The bytes at `offset` of the stream.
/// - `0x02` ACK: `offset u64`. Every byte before `offset` arrived.
///
/// An ACK with nothing new is also the keepalive. The sender resends from the
/// first byte that is not acknowledged (go back N) after a timeout that
/// doubles until an ACK moves it.
struct LinkStream {
    static let dataTag: UInt8 = 1
    static let ackTag: UInt8 = 2
    /// Bytes of the stream in one packet.
    static let chunk = LinkPacketCodec.maxPayload - 1 - 8
    /// Bytes in flight.
    static let window: UInt64 = 32 * 1024
    /// The most that waits to be sent.
    static let queueCap = 256 * 1024
    static let rtoFirst: Int64 = 250
    static let rtoMax: Int64 = 2000
    static let keepalive: Int64 = 3000

    /// The bytes from `acked`: what is in flight and what waits.
    private(set) var out = Data()
    private(set) var acked: UInt64 = 0
    private(set) var sent: UInt64 = 0
    private(set) var rto: Int64 = rtoFirst
    private var resendAt: Int64 = 0
    private(set) var received: UInt64 = 0
    private var ackDue = false
    private var lastTx: Int64 = 0

    /// How many bytes `write` takes now.
    var room: Int {
        Self.queueCap - out.count
    }

    /// Queues bytes for the peer. Returns how many it took.
    mutating func write(_ bytes: Data) -> Int {
        let n = min(bytes.count, room)
        out.append(bytes.prefix(n))
        return n
    }

    /// The bytes that this payload delivers, in order, or nil for a payload
    /// that delivers nothing (an ACK, a duplicate, a gap, an unknown tag).
    mutating func receive(now: Int64, _ payload: Data) -> Data? {
        guard payload.count >= 9 else { return nil }
        let bytes = Data(payload)
        var off: UInt64 = 0
        for i in 0 ..< 8 {
            off |= UInt64(bytes[1 + i]) << (8 * UInt64(i))
        }
        switch bytes[0] {
        case Self.ackTag:
            onAck(now: now, off)
            return nil
        case Self.dataTag:
            let body = bytes.dropFirst(9)
            ackDue = true
            guard off <= received else { return nil }
            let skip = Int(received - off)
            guard skip < body.count else { return nil }
            received += UInt64(body.count - skip)
            return Data(body.dropFirst(skip))
        default:
            return nil
        }
    }

    private mutating func onAck(now: Int64, _ off: UInt64) {
        guard off > acked, off <= acked + UInt64(out.count) else { return }
        out.removeFirst(Int(off - acked))
        acked = off
        if sent < off { sent = off }
        rto = Self.rtoFirst
        resendAt = now + rto
    }

    /// The next payload to send, or nil when there is nothing to send.
    mutating func next(now: Int64) -> Data? {
        if sent > acked, now >= resendAt {
            sent = acked
            rto = min(rto * 2, Self.rtoMax)
        }
        let can = min(acked + UInt64(out.count), acked + Self.window)
        if sent < can {
            let start = Int(sent - acked)
            let n = Int(min(can - sent, UInt64(Self.chunk)))
            var payload = Data([Self.dataTag])
            payload.append(littleEndian: sent)
            payload.append(out.subdata(in: out.startIndex + start ..< out.startIndex + start + n))
            if sent == acked { resendAt = now + rto }
            sent += UInt64(n)
            lastTx = now
            return payload
        }
        if ackDue || now - lastTx >= Self.keepalive {
            var payload = Data([Self.ackTag])
            payload.append(littleEndian: received)
            ackDue = false
            lastTx = now
            return payload
        }
        return nil
    }

    /// When `next` could have something to send, in ms.
    func deadline(now: Int64) -> Int64 {
        var at = lastTx + Self.keepalive
        if sent > acked { at = min(at, resendAt) }
        let can = min(acked + UInt64(out.count), acked + Self.window)
        if ackDue || sent < can { at = now }
        return at
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
