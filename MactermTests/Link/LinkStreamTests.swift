import Foundation
@testable import Macterm
import Testing

/// The Swift stream against the cases of `server/src/link/stream.zig`.
struct LinkStreamTests {
    /// What one direction of the test link has carried.
    private struct Flow {
        var count = 0
        var sink = Data()
    }

    private static func pump(_ from: inout LinkStream, _ to: inout LinkStream, now: Int64, drop: (Int) -> Bool, flow: inout Flow) {
        while let payload = from.next(now: now) {
            flow.count += 1
            if drop(flow.count) { continue }
            if let bytes = to.receive(now: now, payload) { flow.sink.append(bytes) }
        }
    }

    @Test
    func bytes_arrive_in_order_both_ways() {
        var a = LinkStream()
        var b = LinkStream()
        _ = a.write(Data("hello".utf8))
        _ = b.write(Data("world".utf8))
        var toB = Flow()
        var toA = Flow()
        for i in 0 ..< 3 {
            Self.pump(&a, &b, now: Int64(i), drop: { _ in false }, flow: &toB)
            Self.pump(&b, &a, now: Int64(i), drop: { _ in false }, flow: &toA)
        }
        #expect(toB.sink == Data("hello".utf8))
        #expect(toA.sink == Data("world".utf8))
        #expect(a.out.isEmpty && b.out.isEmpty)
    }

    @Test
    func a_lossy_link_still_delivers_every_byte_once_in_order() {
        var a = LinkStream()
        var b = LinkStream()
        let data = Data((0 ..< 20000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var left = data[...]
        var toB = Flow()
        var toA = Flow()
        var now: Int64 = 0
        let drop: (Int) -> Bool = { n in ((n &* 2_654_435_761) >> 7).isMultiple(of: 3) }
        while now < 60000, !(left.isEmpty && a.out.isEmpty) {
            if !left.isEmpty { left = left.dropFirst(a.write(Data(left))) }
            Self.pump(&a, &b, now: now, drop: drop, flow: &toB)
            Self.pump(&b, &a, now: now, drop: drop, flow: &toA)
            now += 50
        }
        #expect(a.out.isEmpty)
        #expect(toB.sink == data)
    }

    @Test
    func a_duplicate_and_a_gap_deliver_nothing_an_overlap_delivers_the_tail() {
        var s = LinkStream()
        func data(_ offset: UInt64, _ text: String) -> Data {
            var d = Data([LinkStream.dataTag])
            withUnsafeBytes(of: offset.littleEndian) { d.append(contentsOf: $0) }
            d.append(Data(text.utf8))
            return d
        }
        #expect(s.receive(now: 0, data(0, "abc")) == Data("abc".utf8))
        #expect(s.receive(now: 0, data(0, "abc")) == nil)
        #expect(s.receive(now: 0, data(10, "abc")) == nil)
        #expect(s.receive(now: 0, data(1, "bcde")) == Data("de".utf8))
        #expect(s.received == 5)
    }

    @Test
    func an_ack_for_bytes_never_sent_is_ignored() {
        var s = LinkStream()
        _ = s.write(Data("abc".utf8))
        var ack = Data([LinkStream.ackTag])
        withUnsafeBytes(of: UInt64(99).littleEndian) { ack.append(contentsOf: $0) }
        _ = s.receive(now: 0, ack)
        #expect(s.acked == 0)
        #expect(s.out.count == 3)
    }

    @Test
    func the_window_and_the_queue_are_bounded() {
        var s = LinkStream()
        let taken = s.write(Data(repeating: 0x78, count: LinkStream.queueCap + 100))
        #expect(taken == LinkStream.queueCap)
        #expect(s.room == 0)
        var sent: UInt64 = 0
        while let payload = s.next(now: 0) {
            sent += UInt64(payload.count - 9)
        }
        #expect(sent == LinkStream.window)
        #expect(s.deadline(now: 1) > 1)
    }

    @Test
    func a_quiet_stream_sends_a_keepalive_and_the_timeout_doubles() {
        var s = LinkStream()
        #expect(s.next(now: 0) == nil)
        #expect(s.next(now: LinkStream.keepalive)?.first == LinkStream.ackTag)
        _ = s.write(Data("x".utf8))
        #expect(s.next(now: LinkStream.keepalive)?.first == LinkStream.dataTag)
        #expect(s.next(now: LinkStream.keepalive + 1) == nil)
        #expect(s.next(now: LinkStream.keepalive + LinkStream.rtoFirst)?.first == LinkStream.dataTag)
        #expect(s.rto == LinkStream.rtoFirst * 2)
    }
}
