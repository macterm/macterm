//! The server's relay of session channels over one client stream
//! (design/003 §1, §6). On a host, the app reaches every pane through one
//! ssh stream: `macterm proxy` joins it to the server's socket, and the
//! server joins each channel to a connection of its own to the session.
//!
//! The order of the stream: channel 0 first, then the pane channels in turn,
//! each with a fair share. A channel whose oldest output or snapshot waits
//! longer than `skip_ms`, or that holds more than `skip_bytes` of them, is
//! skipped ahead: its output and the snapshots that did not start to go out
//! are dropped, and the session sends the screen again. The session's other
//! messages are never dropped. Input is never dropped.
//!
//! This file has the order and the flow of a channel. `conn.zig` has the
//! queue, and `peers.zig` the sockets.

const std = @import("std");
const frame = @import("protocol/protocol.zig").frame;
const conn = @import("conn.zig");

/// Output older than this is skipped ahead (design/003 §6: start at 1 s).
/// Measured (scripts/session_bench.py, relay flood, 50 ms round trip and
/// 100 Mbit/s): a flood that fills the link skips ahead about 75 times in
/// each run of a few seconds, which is `skip_bytes` and not the age, and an
/// interrupt shows its prompt after about 210 ms. The age trips only for
/// output a little faster than the link, so 1 s stays.
pub const skip_ms = 1000;

/// A channel with more than this to drop is skipped ahead. The same cap as a
/// session's for one client (`session.client_cap`).
pub const skip_bytes = 1024 * 1024;

/// The most that one channel sends in its turn, when others wait.
pub const quantum = 8 * 1024;

/// The most that goes to the socket in one fill. Channel 0 waits at most
/// behind this much output, plus what the buffers on the way hold.
pub const wire_budget = 32 * 1024;

const Class = conn.Class;
const FrameQueue = conn.FrameQueue;

/// What a channel does with one frame from its session's pane channel.
pub const Inbound = enum { send, drop };

/// The relay state of one channel, apart from its sockets.
pub const Flow = struct {
    /// The client paused the channel: no output goes out.
    paused: bool = false,
    /// Output goes out again only after a snapshot starts: after a skip or a
    /// resume. `asked_at` is when the server asked for it.
    want_snapshot: bool = false,
    asked_at: i64 = 0,
    /// The frames between `snapshot.start` and `snapshot.end`.
    in_snapshot: bool = false,
    /// A skip dropped the start of the snapshot that comes in now: drop the
    /// rest of it, up to its end.
    discard_snapshot: bool = false,

    /// Sorts one frame that came from the session.
    pub fn classify(f: *Flow, class: Class) Inbound {
        switch (class) {
            .message => return .send,
            .snapshot_start => {
                f.in_snapshot = true;
                f.want_snapshot = false;
                f.discard_snapshot = false;
                return .send;
            },
            .snapshot => return if (f.discard_snapshot) .drop else .send,
            .snapshot_end => {
                f.in_snapshot = false;
                if (f.discard_snapshot) {
                    f.discard_snapshot = false;
                    return .drop;
                }
                return .send;
            },
            .output => return if (f.in_snapshot or f.paused or f.want_snapshot) .drop else .send,
        }
    }

    /// After a skip dropped the queue's stale frames. `open_kept` is what
    /// `FrameQueue.dropStale` returned.
    pub fn skipped(f: *Flow, open_kept: bool, now: i64) void {
        f.discard_snapshot = f.in_snapshot and !open_kept;
        f.want_snapshot = true;
        f.asked_at = now;
    }

    /// True when the channel must skip ahead.
    pub fn mustSkip(f: *const Flow, st: FrameQueue.Stale, now: i64) bool {
        if (f.paused or f.want_snapshot) return false;
        if (st.bytes > skip_bytes) return true;
        const oldest = st.oldest orelse return false;
        return now - oldest >= skip_ms;
    }

    /// True when a snapshot that the server asked for did not come in time
    /// (the session ignored the request: no client attached yet). Ask again.
    pub fn mustAskAgain(f: *const Flow, now: i64) bool {
        return f.want_snapshot and !f.paused and now - f.asked_at >= skip_ms;
    }

    /// The next time that `mustSkip` or `mustAskAgain` can change.
    pub fn deadline(f: *const Flow, st: FrameQueue.Stale) ?i64 {
        if (f.paused) return null;
        if (f.want_snapshot) return f.asked_at + skip_ms;
        const oldest = st.oldest orelse return null;
        return oldest + skip_ms;
    }
};

/// Moves frames into `wire` until it holds `wire_budget` bytes or nothing
/// waits: all of `control` first, then each queue of `channels` in turn from
/// `next.*`, at most `quantum` bytes (and at least one frame) in each turn.
/// `next.*` is where the next fill starts, so that no channel goes first
/// every time. The frames stay whole.
pub fn fill(
    gpa: std.mem.Allocator,
    wire: *FrameQueue,
    control: *FrameQueue,
    channels: []const *FrameQueue,
    next: *usize,
) !void {
    while (wire.bytes < wire_budget) {
        if (!control.empty()) {
            try take(gpa, wire, control, std.math.maxInt(usize));
            continue;
        }
        const n = channels.len;
        var i: usize = 0;
        const pick = while (i < n) : (i += 1) {
            const k = (next.* + i) % n;
            if (!channels[k].empty()) break k;
        } else return;
        try take(gpa, wire, channels[pick], quantum);
        next.* = (pick + 1) % n;
    }
}

fn take(gpa: std.mem.Allocator, wire: *FrameQueue, q: *FrameQueue, limit: usize) !void {
    var sent: usize = 0;
    while (q.peek()) |it| {
        if (sent > 0 and sent + it.data.len > limit) return;
        sent += it.data.len;
        try wire.put(gpa, q.pop().?);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The channels of the frames in `wire`, in order.
fn channelsIn(gpa: std.mem.Allocator, wire: *const FrameQueue) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (wire.items.items[wire.head..]) |it| {
        const p = (try frame.parse(it.data)).?;
        try testing.expectEqual(it.data.len, p.len);
        try out.append(gpa, p.frame.channel);
    }
    return out.toOwnedSlice(gpa);
}

test "channel 0 goes before any output, also behind a flood" {
    const gpa = testing.allocator;
    var control: FrameQueue = .{};
    defer control.deinit(gpa);
    var flood: FrameQueue = .{};
    defer flood.deinit(gpa);
    const big: [4096]u8 = @splat('x');
    for (0..100) |_| try flood.push(gpa, 1, .bytes, &big, 0, .output);
    var wire: FrameQueue = .{};
    defer wire.deinit(gpa);
    var next: usize = 0;

    try fill(gpa, &wire, &control, &.{&flood}, &next);
    // One fill sends at most the budget and one frame.
    try testing.expect(wire.bytes <= wire_budget + big.len + frame.header_len);

    // A reply comes while the flood waits: it goes first in the next fill.
    try control.push(gpa, 0, .msg, &.{0x80}, 0, .message);
    wire.deinit(gpa);
    try fill(gpa, &wire, &control, &.{&flood}, &next);
    const chans = try channelsIn(gpa, &wire);
    defer gpa.free(chans);
    try testing.expectEqual(0, chans[0]);
}

test "a flooding channel sends one turn, then the other channel's output goes" {
    const gpa = testing.allocator;
    var control: FrameQueue = .{};
    defer control.deinit(gpa);
    var flood: FrameQueue = .{};
    defer flood.deinit(gpa);
    var quiet: FrameQueue = .{};
    defer quiet.deinit(gpa);
    const big: [4096]u8 = @splat('x');
    for (0..200) |_| try flood.push(gpa, 1, .bytes, &big, 0, .output);
    try quiet.push(gpa, 2, .bytes, "k", 0, .output);
    var wire: FrameQueue = .{};
    defer wire.deinit(gpa);
    // The flood's turn comes first.
    var next: usize = 0;
    try fill(gpa, &wire, &control, &.{ &flood, &quiet }, &next);
    const chans = try channelsIn(gpa, &wire);
    defer gpa.free(chans);
    try testing.expectEqual(1, chans[0]);
    var before: usize = 0;
    for (chans) |c| {
        if (c == 2) break;
        before += 1;
    } else return error.TestExpectedEqual;
    // At most one turn of the flood goes before it.
    try testing.expect(before * (big.len + frame.header_len) <= quantum);
}

test "frames stay whole and in order" {
    const gpa = testing.allocator;
    var control: FrameQueue = .{};
    defer control.deinit(gpa);
    var a: FrameQueue = .{};
    defer a.deinit(gpa);
    for (0..5) |i| try a.push(gpa, 1, .bytes, &.{@intCast(i)}, 0, .output);
    var wire: FrameQueue = .{};
    defer wire.deinit(gpa);
    var next: usize = 0;
    try fill(gpa, &wire, &control, &.{&a}, &next);
    var i: u8 = 0;
    while (wire.pop()) |it| : (i += 1) {
        defer gpa.free(it.data);
        const p = (try frame.parse(it.data)).?;
        try testing.expectEqual(it.data.len, p.len);
        try testing.expectEqualSlices(u8, &.{i}, p.frame.body);
    }
    try testing.expectEqual(5, i);
    try testing.expect(a.empty());
}

test "a skip during an incoming snapshot drops the rest of it, then waits for the next one" {
    var f: Flow = .{};
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_start));
    f.skipped(false, 0);
    try testing.expectEqual(Inbound.drop, f.classify(.snapshot));
    try testing.expectEqual(Inbound.drop, f.classify(.snapshot_end));
    try testing.expectEqual(Inbound.drop, f.classify(.output));
    try testing.expectEqual(Inbound.send, f.classify(.message));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_start));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_end));
    try testing.expectEqual(Inbound.send, f.classify(.output));

    // The snapshot whose start went out comes whole.
    f = .{};
    _ = f.classify(.snapshot_start);
    f.skipped(true, 0);
    try testing.expectEqual(Inbound.send, f.classify(.snapshot));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_end));
}

test "a channel skips ahead when its output or a snapshot is too old or too large" {
    const gpa = testing.allocator;
    var q: FrameQueue = .{};
    defer q.deinit(gpa);
    var f: Flow = .{};
    try testing.expect(!f.mustSkip(q.stale(), 10_000));
    try q.push(gpa, 1, .msg, "m", 0, .message);
    try testing.expect(!f.mustSkip(q.stale(), 10_000));
    try q.push(gpa, 1, .bytes, "x", 100, .output);
    try testing.expect(!f.mustSkip(q.stale(), 100 + skip_ms - 1));
    try testing.expect(f.mustSkip(q.stale(), 100 + skip_ms));
    try testing.expectEqual(100 + skip_ms, f.deadline(q.stale()).?);

    // A queue of snapshots alone, which a slow link let pile up.
    var snaps: FrameQueue = .{};
    defer snaps.deinit(gpa);
    const chunk: [64 * 1024]u8 = @splat('y');
    try snaps.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    for (0..17) |_| try snaps.push(gpa, 1, .bytes, &chunk, 0, .snapshot);
    try testing.expect(f.mustSkip(snaps.stale(), 0));
    // One that started to go out does not count.
    gpa.free(snaps.pop().?.data);
    try testing.expectEqual(0, snaps.stale().bytes);
    try testing.expect(!f.mustSkip(snaps.stale(), 10_000));
}

test "a paused channel drops output and passes messages; a resume waits for a snapshot" {
    var f: Flow = .{ .paused = true };
    try testing.expectEqual(Inbound.drop, f.classify(.output));
    try testing.expectEqual(Inbound.send, f.classify(.message));

    // Resume: output waits for the snapshot that the session sends.
    f = .{ .want_snapshot = true, .asked_at = 0 };
    try testing.expectEqual(Inbound.drop, f.classify(.output));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_start));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot));
    try testing.expectEqual(Inbound.send, f.classify(.snapshot_end));
    try testing.expectEqual(Inbound.send, f.classify(.output));
    try testing.expect(!f.want_snapshot);

    // A request that the session ignored is sent again.
    f = .{ .want_snapshot = true, .asked_at = 50 };
    try testing.expect(!f.mustAskAgain(50 + skip_ms - 1));
    try testing.expect(f.mustAskAgain(50 + skip_ms));
}
