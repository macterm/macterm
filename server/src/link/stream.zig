//! The reliable byte stream under the roaming link (design/009 §3).
//!
//! The server's relay already skips ahead and sends a snapshot when a client
//! falls behind, so this layer needs no cleverness: it carries the frames of
//! design/003 in order, resends what the peer did not acknowledge, and stops
//! reading its source when too much waits. It does no I/O and keeps no clock:
//! the caller gives the time in ms.
//!
//! Payloads (inside the sealed packets of `packet.zig`):
//!
//!     0x01 DATA  offset u64 LE, bytes   the bytes at `offset` of the stream
//!     0x02 ACK   offset u64 LE          every byte before `offset` arrived
//!
//! An ACK with nothing new is also the keepalive. The sender resends from the
//! first byte that is not acknowledged (go back N) after a timeout that
//! doubles until an ACK moves it. Nothing here is a congestion algorithm: the
//! window is small and fixed.

const std = @import("std");
const packet = @import("packet.zig");

pub const data_tag: u8 = 1;
pub const ack_tag: u8 = 2;

/// Bytes of the stream in one packet.
pub const chunk = packet.max_payload - 1 - 8;

/// Bytes in flight. A link is for typing and screens, not for bulk.
pub const window: u64 = 32 * 1024;

/// The most that waits to be sent. `write` takes less when it is full, and the
/// caller stops reading its source.
pub const queue_cap: usize = 256 * 1024;

pub const rto_first_ms: i64 = 250;
pub const rto_max_ms: i64 = 2000;

/// An empty ACK goes this often while the stream is quiet.
pub const keepalive_ms: i64 = 3000;

pub const Stream = struct {
    gpa: std.mem.Allocator,
    /// The bytes from `acked`: what is in flight and what waits.
    out: std.ArrayList(u8) = .empty,
    /// Every byte before this was acknowledged.
    acked: u64 = 0,
    /// The next byte to send. Between `acked` and `acked + out.len`.
    sent: u64 = 0,
    rto_ms: i64 = rto_first_ms,
    /// When to resend, while something is in flight.
    resend_at: i64 = 0,
    /// The next byte that we expect from the peer.
    received: u64 = 0,
    ack_due: bool = false,
    /// When we last sent a packet.
    last_tx: i64 = 0,

    pub fn init(gpa: std.mem.Allocator) Stream {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Stream) void {
        s.out.deinit(s.gpa);
    }

    /// How many bytes `write` takes now.
    pub fn room(s: *const Stream) usize {
        return queue_cap - s.out.items.len;
    }

    /// Queues bytes for the peer. Returns how many it took.
    pub fn write(s: *Stream, bytes: []const u8) !usize {
        const n = @min(bytes.len, s.room());
        try s.out.appendSlice(s.gpa, bytes[0..n]);
        return n;
    }

    /// The bytes that this payload delivers, in order, or null for a payload
    /// that delivers nothing (an ACK, a duplicate, a gap, an unknown tag).
    /// An ACK moves the window. A DATA asks for an ACK.
    pub fn receive(s: *Stream, now: i64, payload: []const u8) ?[]const u8 {
        if (payload.len < 9) return null;
        const off = std.mem.readInt(u64, payload[1..9], .little);
        switch (payload[0]) {
            ack_tag => {
                s.onAck(now, off);
                return null;
            },
            data_tag => {
                const bytes = payload[9..];
                s.ack_due = true;
                if (off > s.received) return null;
                const skip: usize = @intCast(s.received - off);
                if (skip >= bytes.len) return null;
                s.received += bytes.len - skip;
                return bytes[skip..];
            },
            else => return null,
        }
    }

    fn onAck(s: *Stream, now: i64, off: u64) void {
        // An ACK for bytes that we did not send is wrong and ignored.
        if (off <= s.acked or off > s.acked + s.out.items.len) return;
        const n: usize = @intCast(off - s.acked);
        s.out.replaceRangeAssumeCapacity(0, n, &.{});
        s.acked = off;
        if (s.sent < off) s.sent = off;
        s.rto_ms = rto_first_ms;
        s.resend_at = now + s.rto_ms;
    }

    /// The next payload to send, written into `buf` (at least
    /// `packet.max_payload` long), or null when there is nothing to send.
    pub fn next(s: *Stream, now: i64, buf: []u8) ?[]u8 {
        // Resend: go back to the first byte that is not acknowledged.
        if (s.sent > s.acked and now >= s.resend_at) {
            s.sent = s.acked;
            s.rto_ms = @min(s.rto_ms * 2, rto_max_ms);
        }
        const queued: u64 = s.out.items.len;
        const can = @min(s.acked + queued, s.acked + window);
        if (s.sent < can) {
            const start: usize = @intCast(s.sent - s.acked);
            const n: usize = @intCast(@min(can - s.sent, chunk));
            buf[0] = data_tag;
            std.mem.writeInt(u64, buf[1..9], s.sent, .little);
            @memcpy(buf[9..][0..n], s.out.items[start..][0..n]);
            if (s.sent == s.acked) s.resend_at = now + s.rto_ms;
            s.sent += n;
            s.last_tx = now;
            return buf[0 .. 9 + n];
        }
        if (s.ack_due or now - s.last_tx >= keepalive_ms) {
            buf[0] = ack_tag;
            std.mem.writeInt(u64, buf[1..9], s.received, .little);
            s.ack_due = false;
            s.last_tx = now;
            return buf[0..9];
        }
        return null;
    }

    /// When `next` could have something to send, in ms, for a poll timeout.
    pub fn deadline(s: *const Stream, now: i64) i64 {
        var at = s.last_tx + keepalive_ms;
        if (s.sent > s.acked) at = @min(at, s.resend_at);
        // Something can go out now only if it fits in the window.
        const can = @min(s.acked + s.out.items.len, s.acked + window);
        if (s.ack_due or s.sent < can) at = now;
        return at;
    }
};

const testing = std.testing;

/// A lossy pipe for the tests: it keeps what it is given in order, and drops
/// the packets that the test says.
fn pump(from: *Stream, to: *Stream, now: i64, drop: *const fn (n: usize) bool, count: *usize, sink: *std.ArrayList(u8)) !void {
    var buf: [packet.max_payload]u8 = undefined;
    while (from.next(now, &buf)) |p| {
        count.* += 1;
        if (drop(count.*)) continue;
        if (to.receive(now, p)) |bytes| try sink.appendSlice(testing.allocator, bytes);
    }
}

fn dropNone(_: usize) bool {
    return false;
}

fn dropEveryThird(n: usize) bool {
    // About a third, with no pattern that a resend can fall into.
    return (n *% 2654435761 >> 7) % 3 == 0;
}

test "bytes arrive in order, both ways" {
    var a = Stream.init(testing.allocator);
    defer a.deinit();
    var b = Stream.init(testing.allocator);
    defer b.deinit();
    var at_b: std.ArrayList(u8) = .empty;
    defer at_b.deinit(testing.allocator);
    var at_a: std.ArrayList(u8) = .empty;
    defer at_a.deinit(testing.allocator);
    _ = try a.write("hello");
    _ = try b.write("world");
    var n1: usize = 0;
    var n2: usize = 0;
    for (0..3) |i| {
        const now: i64 = @intCast(i);
        try pump(&a, &b, now, dropNone, &n1, &at_b);
        try pump(&b, &a, now, dropNone, &n2, &at_a);
    }
    try testing.expectEqualStrings("hello", at_b.items);
    try testing.expectEqualStrings("world", at_a.items);
    try testing.expect(a.out.items.len == 0);
    try testing.expect(b.out.items.len == 0);
}

test "a lossy link still delivers every byte once, in order" {
    var a = Stream.init(testing.allocator);
    defer a.deinit();
    var b = Stream.init(testing.allocator);
    defer b.deinit();
    var at_b: std.ArrayList(u8) = .empty;
    defer at_b.deinit(testing.allocator);
    var sink_a: std.ArrayList(u8) = .empty;
    defer sink_a.deinit(testing.allocator);

    var data: [20000]u8 = undefined;
    for (&data, 0..) |*d, i| d.* = @truncate(i *% 31);
    var left: []const u8 = &data;
    var n1: usize = 0;
    var n2: usize = 0;
    var now: i64 = 0;
    while (now < 60_000 and !(left.len == 0 and a.out.items.len == 0)) : (now += 50) {
        if (left.len > 0) left = left[try a.write(left)..];
        try pump(&a, &b, now, dropEveryThird, &n1, &at_b);
        try pump(&b, &a, now, dropEveryThird, &n2, &sink_a);
    }
    try testing.expect(a.out.items.len == 0);
    try testing.expectEqualSlices(u8, &data, at_b.items);
}

test "a duplicate and a gap deliver nothing, an overlap delivers the tail" {
    var s = Stream.init(testing.allocator);
    defer s.deinit();
    var p: [20]u8 = undefined;
    p[0] = data_tag;
    std.mem.writeInt(u64, p[1..9], 0, .little);
    @memcpy(p[9..][0..3], "abc");
    try testing.expectEqualStrings("abc", s.receive(0, p[0..12]).?);
    try testing.expect(s.receive(0, p[0..12]) == null);
    std.mem.writeInt(u64, p[1..9], 10, .little);
    try testing.expect(s.receive(0, p[0..12]) == null);
    std.mem.writeInt(u64, p[1..9], 1, .little);
    @memcpy(p[9..][0..4], "bcde");
    try testing.expectEqualStrings("de", s.receive(0, p[0..13]).?);
    try testing.expectEqual(@as(u64, 5), s.received);
}

test "an ACK for bytes never sent is ignored" {
    var s = Stream.init(testing.allocator);
    defer s.deinit();
    _ = try s.write("abc");
    var p: [9]u8 = undefined;
    p[0] = ack_tag;
    std.mem.writeInt(u64, p[1..9], 99, .little);
    _ = s.receive(0, &p);
    try testing.expectEqual(@as(u64, 0), s.acked);
    try testing.expectEqual(@as(usize, 3), s.out.items.len);
}

test "the window and the queue are bounded" {
    var s = Stream.init(testing.allocator);
    defer s.deinit();
    var big: [queue_cap + 100]u8 = undefined;
    @memset(&big, 'x');
    try testing.expectEqual(queue_cap, try s.write(&big));
    try testing.expectEqual(@as(usize, 0), s.room());
    var buf: [packet.max_payload]u8 = undefined;
    var sent: u64 = 0;
    while (s.next(0, &buf)) |p| sent += p.len - 9;
    try testing.expectEqual(window, sent);
}

test "a full window does not ask for an immediate wake" {
    var s = Stream.init(testing.allocator);
    defer s.deinit();
    var big: [window + 1000]u8 = undefined;
    @memset(&big, 'x');
    _ = try s.write(&big);
    var buf: [packet.max_payload]u8 = undefined;
    while (s.next(0, &buf)) |_| {}
    try testing.expect(s.deadline(1) > 1);
}

test "a quiet stream sends a keepalive, and the timeout doubles" {
    var s = Stream.init(testing.allocator);
    defer s.deinit();
    var buf: [packet.max_payload]u8 = undefined;
    try testing.expect(s.next(0, &buf) == null);
    try testing.expectEqual(ack_tag, s.next(keepalive_ms, &buf).?[0]);
    _ = try s.write("x");
    try testing.expectEqual(data_tag, s.next(keepalive_ms, &buf).?[0]);
    try testing.expect(s.next(keepalive_ms + 1, &buf) == null);
    try testing.expectEqual(data_tag, s.next(keepalive_ms + rto_first_ms, &buf).?[0]);
    try testing.expectEqual(rto_first_ms * 2, s.rto_ms);
}

test "fuzz: any payload leaves the stream sane" {
    try testing.fuzz({}, fuzzReceive, .{});
}

fn fuzzReceive(_: void, smith: *testing.Smith) anyerror!void {
    var s = Stream.init(testing.allocator);
    defer s.deinit();
    _ = try s.write("abc");
    var buf: [64]u8 = undefined;
    const n = smith.slice(&buf);
    if (s.receive(0, buf[0..n])) |bytes| {
        try testing.expect(bytes.len <= n);
    }
    try testing.expect(s.acked <= s.sent);
    try testing.expect(s.sent <= s.acked + s.out.items.len);
}
