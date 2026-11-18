//! A connection that carries frames (design/003 §1), the queue of frames
//! that wait for a connection, and the poll loop that serves many
//! connections. The session (`session.zig`) and the server (`server.zig`,
//! `registry.zig`, `peers.zig`) use them for each connection that they hold.

const std = @import("std");
const lib_posix = @import("posix.zig");
const protocol = @import("protocol/protocol.zig");
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const m = protocol.messages;

/// What a frame is to a drop (`FrameQueue.dropStale`).
pub const Class = enum {
    /// Pane output.
    output,
    /// A message, or other data that a drop never removes.
    message,
    snapshot_start,
    /// Snapshot data that the relay can drop until its start went out.
    snapshot,
    snapshot_end,
};

/// Whole frames that wait to go out, in order. A write can send part of the
/// first frame; the rest of that frame then goes out before anything else,
/// and no drop removes it.
///
/// It has two drops. The relay drops the stale frames of a channel
/// (`dropStale`). A session drops the output at the end of a client's queue
/// (`dropOutput`).
pub const FrameQueue = struct {
    items: std.ArrayList(Item) = .empty,
    head: usize = 0,
    /// The bytes that wait, headers included.
    bytes: usize = 0,
    /// The bytes of the first frame that a write sent.
    sent: usize = 0,
    /// The bytes of the output frames after the last frame of another
    /// class, less a frame that started to go out (`dropOutput`).
    output_tail: usize = 0,
    /// The start of a snapshot went out with `pop`, and its end did not.
    sending_snapshot: bool = false,

    pub const Item = struct {
        /// The frame, header included. The queue owns it.
        data: []u8,
        /// When it came, in ms.
        at: i64,
        class: Class,
    };

    pub fn deinit(q: *FrameQueue, gpa: std.mem.Allocator) void {
        for (q.items.items[q.head..]) |it| gpa.free(it.data);
        q.items.deinit(gpa);
        q.* = .{};
    }

    pub fn empty(q: *const FrameQueue) bool {
        return q.head == q.items.items.len;
    }

    pub fn push(q: *FrameQueue, gpa: std.mem.Allocator, channel: u32, kind: frame.Kind, body: []const u8, at: i64, class: Class) !void {
        const data = try gpa.alloc(u8, frame.header_len + body.len);
        errdefer gpa.free(data);
        try frame.writeHeader(data[0..frame.header_len], channel, kind, body.len);
        @memcpy(data[frame.header_len..], body);
        try q.items.append(gpa, .{ .data = data, .at = at, .class = class });
        q.added(data.len, class);
    }

    /// Adds a frame that another queue gave up (`pop`). On a failure the
    /// frame is freed.
    pub fn put(q: *FrameQueue, gpa: std.mem.Allocator, it: Item) !void {
        q.items.append(gpa, it) catch |err| {
            gpa.free(it.data);
            return err;
        };
        q.added(it.data.len, it.class);
    }

    fn added(q: *FrameQueue, len: usize, class: Class) void {
        q.bytes += len;
        q.output_tail = if (class == .output) q.output_tail + len else 0;
    }

    /// The first frame. The caller owns its `data`. Not for a queue that a
    /// write sent part of.
    pub fn pop(q: *FrameQueue) ?Item {
        std.debug.assert(q.sent == 0);
        if (q.empty()) return null;
        const it = q.items.items[q.head];
        switch (it.class) {
            .snapshot_start => q.sending_snapshot = true,
            .snapshot_end => q.sending_snapshot = false,
            else => {},
        }
        q.head += 1;
        q.bytes -= it.data.len;
        q.output_tail = @min(q.output_tail, q.bytes);
        q.compact();
        return it;
    }

    pub fn peek(q: *const FrameQueue) ?Item {
        if (q.empty()) return null;
        return q.items.items[q.head];
    }

    /// Writes what waits, until `fd` is full. `error.WouldBlock` is not an
    /// error here. The frames that went out are freed.
    pub fn write(q: *FrameQueue, gpa: std.mem.Allocator, fd: i32) lib_posix.WriteError!void {
        while (!q.empty()) {
            var iov: [16]lib_posix.iovec_const = undefined;
            var count: usize = 0;
            var total: usize = 0;
            for (q.items.items[q.head..]) |it| {
                const data = if (count == 0) it.data[q.sent..] else it.data;
                iov[count] = .{ .base = data.ptr, .len = data.len };
                total += data.len;
                count += 1;
                if (count == iov.len) break;
            }
            const n = lib_posix.writev(fd, iov[0..count]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            q.consume(gpa, n);
            if (n < total) return;
        }
    }

    /// Removes the first `n` bytes, which a write sent.
    fn consume(q: *FrameQueue, gpa: std.mem.Allocator, n: usize) void {
        std.debug.assert(n <= q.bytes);
        var left = n;
        while (left > 0) {
            const it = q.items.items[q.head];
            const rest = it.data.len - q.sent;
            if (left < rest) {
                q.sent += left;
                q.bytes -= left;
                break;
            }
            left -= rest;
            q.bytes -= rest;
            gpa.free(it.data);
            q.head += 1;
            q.sent = 0;
        }
        // The tail is the end of the queue: it loses only what went out.
        const started_rest = if (q.sent > 0) q.items.items[q.head].data.len - q.sent else 0;
        q.output_tail = @min(q.output_tail, q.bytes - started_rest);
        q.compact();
    }

    /// Moves the frames that wait to the start of `items`, when the frames
    /// that went out take more than half of it.
    fn compact(q: *FrameQueue) void {
        if (q.empty()) {
            q.items.clearRetainingCapacity();
            q.head = 0;
        } else if (q.head >= 64 and q.head * 2 >= q.items.items.len) {
            const rest = q.items.items[q.head..];
            std.mem.copyForwards(Item, q.items.items[0..rest.len], rest);
            q.items.shrinkRetainingCapacity(rest.len);
            q.head = 0;
        }
    }

    /// What a drop would remove: every output frame, and every snapshot
    /// whose start did not go out. The rest of a snapshot that started to
    /// go out stays, so that the client gets its end. A frame that a write
    /// sent part of stays.
    pub const Stale = struct {
        bytes: usize = 0,
        /// When the oldest of them came.
        oldest: ?i64 = null,
    };

    pub fn stale(q: *const FrameQueue) Stale {
        var out: Stale = .{};
        var keep_snapshot = q.sending_snapshot;
        for (q.items.items[q.firstDroppable()..]) |it| {
            if (!dropped(it.class, &keep_snapshot)) continue;
            out.bytes += it.data.len;
            if (out.oldest == null) out.oldest = it.at;
        }
        return out;
    }

    /// Drops what `stale` names. Returns true when a snapshot that started
    /// to go out has not ended in the queue: the rest of it, which the
    /// session still sends, must go out too.
    pub fn dropStale(q: *FrameQueue, gpa: std.mem.Allocator) bool {
        var keep_snapshot = q.sending_snapshot;
        const first = q.firstDroppable();
        var kept: usize = first;
        for (q.items.items[first..]) |it| {
            if (dropped(it.class, &keep_snapshot)) {
                gpa.free(it.data);
                q.bytes -= it.data.len;
                continue;
            }
            q.items.items[kept] = it;
            kept += 1;
        }
        q.items.shrinkRetainingCapacity(kept);
        q.output_tail = 0;
        q.compact();
        return keep_snapshot;
    }

    /// Drops the output frames at the end of the queue, after the last frame
    /// of another class, that did not start to go out. Output in front of a
    /// message stays: it goes out first.
    pub fn dropOutput(q: *FrameQueue, gpa: std.mem.Allocator) void {
        const first = q.firstDroppable();
        while (q.items.items.len > first) {
            const it = q.items.items[q.items.items.len - 1];
            if (it.class != .output) break;
            gpa.free(it.data);
            q.bytes -= it.data.len;
            q.items.items.len -= 1;
        }
        q.output_tail = 0;
        q.compact();
    }

    fn firstDroppable(q: *const FrameQueue) usize {
        return if (q.sent > 0) q.head + 1 else q.head;
    }

    /// `keep_snapshot` is true while the frames belong to a snapshot whose
    /// start went out.
    fn dropped(class: Class, keep_snapshot: *bool) bool {
        return switch (class) {
            .output => true,
            .message => false,
            .snapshot_start => true,
            .snapshot => !keep_snapshot.*,
            .snapshot_end => {
                const keep = keep_snapshot.*;
                keep_snapshot.* = false;
                return !keep;
            },
        };
    }
};

/// One connection that carries frames: a client of the session or the
/// server, the server's connection to a session, a relay channel, or the
/// socket of `zmx connect` (`attach.zig`).
pub const FrameConn = struct {
    /// -1 after `close`.
    fd: i32,
    in: std.ArrayList(u8) = .empty,
    /// The bytes at the start of `in` that `next` gave out.
    used: usize = 0,
    out: FrameQueue = .{},
    /// A frame with a longer body ends the connection before its body is
    /// read.
    max_frame: u32,
    /// The peer's `hello` came and the levels meet.
    greeted: bool = false,
    /// Close it when its queue is empty (after a refusal). It reads nothing
    /// more.
    closing: bool = false,
    /// The connection is over. The owner frees it at the end of the loop
    /// pass.
    dead: bool = false,

    /// Why `read` stopped the connection.
    pub const End = enum {
        /// End of the stream, or a read that failed.
        closed,
        too_large,
        bad_frame,
        no_memory,
    };

    pub fn deinit(c: *FrameConn, gpa: std.mem.Allocator) void {
        c.close();
        c.in.deinit(gpa);
        c.out.deinit(gpa);
    }

    pub fn close(c: *FrameConn) void {
        if (c.fd < 0) return;
        lib_posix.close(c.fd);
        c.fd = -1;
    }

    /// It can still take frames from its peer.
    pub fn live(c: *const FrameConn) bool {
        return c.fd >= 0 and !c.dead and !c.closing;
    }

    /// The poll events: always IN, and OUT when frames wait in `out` or
    /// `owner_waits` is true (the owner has frames of its own to send).
    pub fn events(c: *const FrameConn, owner_waits: bool) i16 {
        var ev: i16 = lib_posix.POLL.IN;
        if (owner_waits or !c.out.empty()) ev |= lib_posix.POLL.OUT;
        return ev;
    }

    /// Reads what the socket has, and gives each whole frame to
    /// `onFrame`, with the arguments `ctx`, the frame and `arena`. It stops
    /// when the connection is not `live`. `arena` is cleared after each
    /// frame, and the frame's body is valid only in the call. Returns null,
    /// or why the connection must end: the owner then ends it.
    pub fn read(c: *FrameConn, gpa: std.mem.Allocator, arena: *std.heap.ArenaAllocator, ctx: anytype, comptime onFrame: anytype) ?End {
        if (!(c.fill(gpa) catch return .no_memory)) return .closed;
        while (c.live()) {
            const f = (c.next() catch |err| return switch (err) {
                error.TooLarge => .too_large,
                error.BadFrame => .bad_frame,
            }) orelse break;
            defer _ = arena.reset(.{ .retain_with_limit = 64 * 1024 });
            @call(.auto, onFrame, ctx ++ .{ f, arena.allocator() });
        }
        return null;
    }

    /// Reads once into `in`. False at the end of the stream, or when the
    /// read fails. True when the socket has nothing now.
    pub fn fill(c: *FrameConn, gpa: std.mem.Allocator) error{OutOfMemory}!bool {
        var buf: [16 * 1024]u8 = undefined;
        const n = lib_posix.read(c.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return true,
            else => return false,
        };
        if (n == 0) return false;
        try c.in.appendSlice(gpa, buf[0..n]);
        return true;
    }

    /// The next whole frame in `in`, or null. Its body is valid until the
    /// next call. A frame whose body is longer than `max_frame` is an error
    /// before its body comes.
    pub fn next(c: *FrameConn) error{ TooLarge, BadFrame }!?frame.Frame {
        c.in.replaceRangeAssumeCapacity(0, c.used, &.{});
        c.used = 0;
        if (c.in.items.len >= frame.header_len and std.mem.readInt(u32, c.in.items[0..4], .little) > c.max_frame)
            return error.TooLarge;
        const parsed = (frame.parse(c.in.items) catch return error.BadFrame) orelse return null;
        c.used = parsed.len;
        return parsed.frame;
    }

    /// Drops what `in` holds, for a new stream on a new socket.
    pub fn reset(c: *FrameConn) void {
        c.in.clearRetainingCapacity();
        c.used = 0;
    }

    /// Writes what waits, until the socket is full.
    pub fn flush(c: *FrameConn, gpa: std.mem.Allocator) lib_posix.WriteError!void {
        try c.out.write(gpa, c.fd);
    }

    /// Queues one frame that a drop never removes.
    pub fn send(c: *FrameConn, gpa: std.mem.Allocator, channel: u32, kind: frame.Kind, body: []const u8) !void {
        try c.out.push(gpa, channel, kind, body, 0, .message);
    }

    /// Queues a channel 0 message.
    pub fn sendControl(c: *FrameConn, gpa: std.mem.Allocator, value: anytype) !void {
        const body = try msgpack.encodeAlloc(gpa, value);
        defer gpa.free(body);
        try c.send(gpa, frame.control_channel, .msg, body);
    }

    /// Queues a pane channel message.
    pub fn sendPane(c: *FrameConn, gpa: std.mem.Allocator, comptime M: type, value: M) !void {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        m.encodePane(&out.writer, M, value) catch return error.OutOfMemory;
        try c.send(gpa, m.pane_channel, .msg, out.written());
    }
};

/// The `pollfd` list of one loop, with the source of each fd. `Source` is
/// the loop's own tagged union of pointers.
pub fn Reactor(comptime Source: type) type {
    return struct {
        const Self = @This();

        fds: std.ArrayList(lib_posix.pollfd) = .empty,
        sources: std.ArrayList(Source) = .empty,

        pub fn deinit(r: *Self, gpa: std.mem.Allocator) void {
            r.fds.deinit(gpa);
            r.sources.deinit(gpa);
        }

        pub fn clear(r: *Self) void {
            r.fds.clearRetainingCapacity();
            r.sources.clearRetainingCapacity();
        }

        pub fn add(r: *Self, gpa: std.mem.Allocator, fd: i32, events: i16, source: Source) !void {
            try r.fds.append(gpa, .{ .fd = fd, .events = events, .revents = 0 });
            try r.sources.append(gpa, source);
        }

        /// Gives `source` to the fds that a caller appended to `fds` itself.
        pub fn tag(r: *Self, gpa: std.mem.Allocator, source: Source) !void {
            while (r.sources.items.len < r.fds.items.len) try r.sources.append(gpa, source);
        }

        pub fn poll(r: *Self, timeout: i32) !void {
            _ = try lib_posix.poll(r.fds.items, timeout);
        }
    };
}

/// The poll result means that the peer closed or failed, and there is
/// nothing more to read.
pub fn hungUp(revents: i16) bool {
    return revents & lib_posix.POLL.IN == 0 and
        revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR | lib_posix.POLL.NVAL) != 0;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectBodies(gpa: std.mem.Allocator, q: *FrameQueue, want: []const []const u8) !void {
    for (want) |w| {
        const it = q.pop().?;
        defer gpa.free(it.data);
        try testing.expectEqualStrings(w, it.data[frame.header_len..]);
    }
    try testing.expect(q.empty());
}

test "a drop at the end of the queue keeps a frame that is half sent" {
    const gpa = testing.allocator;
    var q: FrameQueue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .bytes, "abcdef", 0, .output);
    try q.push(gpa, 1, .bytes, "gh", 0, .output);
    try testing.expectEqual(2 * frame.header_len + 8, q.bytes);

    // A write sent the first header and two bytes of the first body.
    q.consume(gpa, frame.header_len + 2);
    try testing.expectEqual(frame.header_len + 2, q.output_tail);
    try q.push(gpa, 1, .bytes, "x", 0, .output);
    q.dropOutput(gpa);
    // What is left is the rest of the first frame: "cdef".
    try testing.expectEqual(4, q.bytes);
    try testing.expectEqualStrings("cdef", q.peek().?.data[q.sent..]);
    q.consume(gpa, 4);
    try testing.expect(q.empty());
    try testing.expectEqual(0, q.bytes);
    try testing.expectEqual(0, q.sent);

    // At a frame's end, a drop leaves nothing.
    try q.push(gpa, 1, .bytes, "abc", 0, .output);
    q.dropOutput(gpa);
    try testing.expect(q.empty());

    // A write that ends inside the header of a later frame.
    try q.push(gpa, 1, .bytes, "ab", 0, .output);
    try q.push(gpa, 1, .bytes, "cd", 0, .output);
    q.consume(gpa, frame.header_len + 2 + 3);
    try testing.expectEqual(3, q.sent);
    q.dropOutput(gpa);
    try testing.expectEqual(frame.header_len - 3 + 2, q.bytes);
    try testing.expectEqualStrings("cd", q.peek().?.data[frame.header_len..]);
}

test "a drop at the end of the queue never removes a message, or the output in front of it" {
    const gpa = testing.allocator;
    var q: FrameQueue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .bytes, "out1", 0, .output);
    try q.push(gpa, 1, .msg, "lead", 0, .message);
    try q.push(gpa, 1, .bytes, "snap", 0, .message);
    try q.push(gpa, 1, .bytes, "out2", 0, .output);
    try testing.expectEqual(frame.header_len + 4, q.output_tail);
    q.dropOutput(gpa);
    // Output before the last kept frame stays: it comes first on the wire.
    try testing.expectEqual(3 * (frame.header_len + 4), q.bytes);
    try testing.expectEqual(0, q.output_tail);

    // Sent bytes leave the tail alone.
    q.consume(gpa, frame.header_len + 4);
    try q.push(gpa, 1, .bytes, "out3", 0, .output);
    try testing.expectEqual(frame.header_len + 4, q.output_tail);
    q.dropOutput(gpa);
    try testing.expectEqual(2 * (frame.header_len + 4), q.bytes);

    // A queue of output alone that goes out: the tail goes with it.
    q.deinit(gpa);
    for (0..100) |_| try q.push(gpa, 1, .bytes, "o", 0, .output);
    q.consume(gpa, 70 * (frame.header_len + 1) + 2);
    try testing.expectEqual(29 * (frame.header_len + 1), q.output_tail);
    try testing.expectEqual(30 * (frame.header_len + 1) - 2, q.bytes);
    // The frames that went out gave their places back.
    try testing.expectEqual(0, q.head);
    q.dropOutput(gpa);
    try testing.expectEqual(frame.header_len + 1 - 2, q.bytes);
}

test "a drop removes output and unsent snapshots, and keeps messages in order" {
    const gpa = testing.allocator;
    var q: FrameQueue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .bytes, "out1", 0, .output);
    try q.push(gpa, 1, .msg, "lead", 0, .message);
    try q.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    try q.push(gpa, 1, .bytes, "snap", 0, .snapshot);
    try q.push(gpa, 1, .msg, "end", 0, .snapshot_end);
    try q.push(gpa, 1, .bytes, "out2", 0, .output);
    try q.push(gpa, 1, .msg, "exit", 0, .message);
    try testing.expect(!q.dropStale(gpa));
    try expectBodies(gpa, &q, &.{ "lead", "exit" });
    try testing.expectEqual(0, q.bytes);
}

test "a drop keeps the rest of a snapshot that started to go out" {
    const gpa = testing.allocator;
    var q: FrameQueue = .{};
    defer q.deinit(gpa);
    try q.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    try q.push(gpa, 1, .bytes, "snap1", 0, .snapshot);
    gpa.free(q.pop().?.data);
    try q.push(gpa, 1, .bytes, "snap2", 0, .snapshot);
    try q.push(gpa, 1, .msg, "end", 0, .snapshot_end);
    try q.push(gpa, 1, .msg, "start2", 0, .snapshot_start);
    try q.push(gpa, 1, .bytes, "snap3", 0, .snapshot);
    // Its end is in the queue: nothing of it comes later.
    try testing.expect(!q.dropStale(gpa));
    try expectBodies(gpa, &q, &.{ "snap1", "snap2", "end" });

    // A snapshot that started to go out and whose end did not come yet.
    try q.push(gpa, 1, .msg, "start", 0, .snapshot_start);
    gpa.free(q.pop().?.data);
    try q.push(gpa, 1, .bytes, "snap", 0, .snapshot);
    try testing.expect(q.dropStale(gpa));
    try expectBodies(gpa, &q, &.{"snap"});
}

/// A socket pair whose first end does not block.
fn pair() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &fds) != 0) return error.SocketPair;
    const flags = try lib_posix.fcntl(fds[0], lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(fds[0], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
    return fds;
}

/// Reads every byte that waits on `fd` into `out`.
fn drain(gpa: std.mem.Allocator, fd: i32, out: *std.ArrayList(u8)) !void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        var pfd = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        if (try lib_posix.poll(&pfd, 0) == 0) return;
        const n = try lib_posix.read(fd, &buf);
        if (n == 0) return;
        try out.appendSlice(gpa, buf[0..n]);
    }
}

test "a write that stops inside a frame sends the rest of it first, and no drop takes it" {
    const gpa = testing.allocator;
    const fds = try pair();
    defer for (fds) |fd| lib_posix.close(fd);
    var q: FrameQueue = .{};
    defer q.deinit(gpa);
    // Larger than any socket buffer: the first write stops inside it.
    const big = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    try q.push(gpa, 1, .bytes, big, 0, .output);
    try q.push(gpa, 1, .bytes, "dropped", 0, .output);
    try q.push(gpa, 1, .msg, "kept", 0, .message);
    try q.write(gpa, fds[0]);
    try testing.expect(q.sent > 0);
    // Only the frame that did not start can go.
    try testing.expectEqual(frame.header_len + 7, q.stale().bytes);
    _ = q.dropStale(gpa);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    while (!q.empty()) {
        try drain(gpa, fds[1], &got);
        try q.write(gpa, fds[0]);
    }
    try drain(gpa, fds[1], &got);
    // The whole first frame, then the message: the stream stays whole.
    var rest: []const u8 = got.items;
    const first = (try frame.parse(rest)).?;
    try testing.expectEqual(big.len, first.frame.body.len);
    rest = rest[first.len..];
    const second = (try frame.parse(rest)).?;
    try testing.expectEqualStrings("kept", second.frame.body);
    try testing.expectEqual(second.len, rest.len);
    try testing.expectEqual(0, q.bytes);
}

test "a connection reads whole frames, and ends one that is too large" {
    const gpa = testing.allocator;
    const fds = try pair();
    defer lib_posix.close(fds[1]);
    var c: FrameConn = .{ .fd = fds[0], .max_frame = 8 };
    defer c.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var header: [frame.header_len]u8 = undefined;
    try frame.writeHeader(&header, 1, .bytes, 2);
    // One frame and the first half of the next.
    try lib_posix.writeAll(fds[1], &header);
    try lib_posix.writeAll(fds[1], "ab");
    try lib_posix.writeAll(fds[1], header[0..4]);
    const Seen = struct {
        bodies: std.ArrayList(u8) = .empty,
        fn onFrame(seen: *@This(), f: frame.Frame, a: std.mem.Allocator) void {
            _ = a;
            seen.bodies.appendSlice(testing.allocator, f.body) catch unreachable;
        }
    };
    var seen: Seen = .{};
    defer seen.bodies.deinit(gpa);
    try testing.expectEqual(null, c.read(gpa, &arena, .{&seen}, Seen.onFrame));
    try testing.expectEqualStrings("ab", seen.bodies.items);
    try testing.expectEqual(4, c.in.items.len - c.used);
    try lib_posix.writeAll(fds[1], header[4..]);
    try lib_posix.writeAll(fds[1], "cd");
    try testing.expectEqual(null, c.read(gpa, &arena, .{&seen}, Seen.onFrame));
    try testing.expectEqualStrings("abcd", seen.bodies.items);

    try frame.writeHeader(&header, 1, .bytes, 9);
    try lib_posix.writeAll(fds[1], &header);
    try testing.expectEqual(FrameConn.End.too_large, c.read(gpa, &arena, .{&seen}, Seen.onFrame).?);
}

test "a connection ends at a bad frame and at the end of the stream, and a closing one reads nothing more" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Count = struct {
        n: usize = 0,
        fn onFrame(count: *@This(), conn: *FrameConn, f: frame.Frame, a: std.mem.Allocator) void {
            _ = f;
            _ = a;
            count.n += 1;
            conn.closing = true;
        }
    };
    var header: [frame.header_len]u8 = undefined;
    try frame.writeHeader(&header, 1, .bytes, 0);

    // Two frames: the first one closes the connection, so the second one
    // is not read.
    var fds = try pair();
    var c: FrameConn = .{ .fd = fds[0], .max_frame = 8 };
    var count: Count = .{};
    try lib_posix.writeAll(fds[1], &header);
    try lib_posix.writeAll(fds[1], &header);
    try testing.expectEqual(null, c.read(gpa, &arena, .{ &count, &c }, Count.onFrame));
    try testing.expectEqual(1, count.n);

    // The next read gives the frame that waits.
    c.closing = false;
    try testing.expectEqual(null, c.read(gpa, &arena, .{ &count, &c }, Count.onFrame));
    try testing.expectEqual(2, count.n);

    // The end of the stream.
    c.closing = false;
    lib_posix.close(fds[1]);
    try testing.expectEqual(FrameConn.End.closed, c.read(gpa, &arena, .{ &count, &c }, Count.onFrame).?);
    c.deinit(gpa);

    // Pane bytes on channel 0.
    fds = try pair();
    defer lib_posix.close(fds[1]);
    c = .{ .fd = fds[0], .max_frame = 8 };
    defer c.deinit(gpa);
    try frame.writeHeader(&header, frame.control_channel, .bytes, 0);
    try lib_posix.writeAll(fds[1], &header);
    try testing.expectEqual(FrameConn.End.bad_frame, c.read(gpa, &arena, .{ &count, &c }, Count.onFrame).?);
}
