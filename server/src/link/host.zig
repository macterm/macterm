//! The host side of the roaming link (design/009 §2, §4).
//!
//! `link.open` (an ssh client sends it, with a key that only the two sides
//! know) gives the client a UDP port. The packets that arrive there are
//! opened with `packet.zig`, and their bytes go through `stream.zig` to one
//! end of a socket pair. The server holds the other end as an ordinary client
//! (`Server.addPeer`), so the relay, its skip-ahead and every request work on
//! a link as they work on a socket. This file has no knowledge of the server.
//!
//! Rules (design/009 §2, and the three costs in its table):
//!
//! - One UDP socket for all links, in a port range. It opens at the first
//!   link and closes with the last.
//! - A packet goes to the link that its `key_id` names. A packet that does not
//!   authenticate gets no reply, and costs one AEAD check. Checks for a source
//!   that no link knows come from a bucket, so a flood costs a bounded CPU.
//! - The client's address moves only on an authenticated packet with a counter
//!   higher than any before (`Opened.newest`).
//! - A link that gets no authenticated packet within `first_packet_ms`, or
//!   within `idle_ms` after the last, ends. The owner's end (the ssh
//!   connection that asked) ends all of its links.
//! - The key lives only in this process's memory, and is wiped when the link
//!   ends.

const std = @import("std");
const c = std.c;
const packet = @import("packet.zig");
const stream = @import("stream.zig");
const lib_posix = @import("../posix.zig");

/// A link that gets no authenticated packet this long after it opened ends.
pub const first_packet_ms: i64 = 60 * 1000;

/// An open link that hears nothing for this long ends. This is also the life
/// of a key that nobody uses.
pub const idle_ms: i64 = 24 * 60 * 60 * 1000;

pub const default_first_port: u16 = 60001;
pub const default_last_port: u16 = 60999;

/// The most links at one time.
pub const max_links = 16;

/// The most packets that one pass reads or sends, so that one link cannot
/// keep the server's loop.
const pass_packets = 64;

/// Checks for packets from sources that no link knows (see the top).
const bucket_size: f64 = 400;
const bucket_per_s: f64 = 200;

/// The cap of bytes that wait for the server's end of the socket pair.
const to_inner_cap: usize = 1024 * 1024;

pub const Addr = struct {
    storage: c.sockaddr.storage = undefined,
    len: c.socklen_t = 0,

    fn bytes(a: *const Addr) []const u8 {
        return std.mem.asBytes(&a.storage)[0..a.len];
    }

    fn eql(a: *const Addr, b: *const Addr) bool {
        return a.len == b.len and std.mem.eql(u8, a.bytes(), b.bytes());
    }
};

pub const Link = struct {
    /// The client of the server that asked (`link.open`).
    owner: u64,
    codec: packet.Link,
    st: stream.Stream,
    /// This end of the socket pair. The server holds the other end.
    inner: i32,
    /// Stream bytes for `inner` that did not fit yet.
    to_inner: std.ArrayList(u8) = .empty,
    remote: ?Addr = null,
    opened_at: i64,
    last_rx: i64,
    dead: bool = false,

    fn deinit(l: *Link, gpa: std.mem.Allocator) void {
        lib_posix.close(l.inner);
        l.codec.deinit();
        l.st.deinit();
        l.to_inner.deinit(gpa);
        gpa.destroy(l);
    }
};

pub const OpenError = error{ TooMany, KeyInUse, NoPort, Disabled, OutOfMemory, System };

pub const Opened = struct {
    port: u16,
    /// The server's end of the socket pair: the server makes a client of it.
    peer_fd: i32,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    udp: i32 = -1,
    port: u16 = 0,
    links: std.ArrayList(*Link) = .empty,
    tokens: f64 = bucket_size,
    tokens_at: i64 = 0,

    pub fn init(gpa: std.mem.Allocator) Host {
        return .{ .gpa = gpa };
    }

    pub fn deinit(h: *Host) void {
        for (h.links.items) |l| l.deinit(h.gpa);
        h.links.deinit(h.gpa);
        h.closeUdp();
    }

    /// Opens a link for `owner`. `ports` is the first and last port to try.
    /// `seed` picks where in the range to start (any random u32).
    pub fn open(h: *Host, owner: u64, key: [packet.key_len]u8, key_id: u32, now: i64, ports: [2]u16, seed: u32) OpenError!Opened {
        if (h.links.items.len >= max_links) return error.TooMany;
        for (h.links.items) |l| if (l.codec.key_id == key_id) return error.KeyInUse;
        if (h.udp < 0) try h.openUdp(ports, seed);
        errdefer if (h.links.items.len == 0) h.closeUdp();

        var pair: [2]i32 = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair) != 0) return error.System;
        errdefer {
            lib_posix.close(pair[0]);
            lib_posix.close(pair[1]);
        }
        for (pair) |fd| setNonblockingCloexec(fd) catch return error.System;

        const l = h.gpa.create(Link) catch return error.OutOfMemory;
        errdefer h.gpa.destroy(l);
        l.* = .{
            .owner = owner,
            .codec = packet.Link.init(key, key_id, .host_to_client),
            .st = stream.Stream.init(h.gpa),
            .inner = pair[0],
            .opened_at = now,
            .last_rx = now,
        };
        h.links.append(h.gpa, l) catch return error.OutOfMemory;
        return .{ .port = h.port, .peer_fd = pair[1] };
    }

    /// Ends the links of `owner`, or the one with this key id.
    pub fn closeOwner(h: *Host, owner: u64) void {
        for (h.links.items) |l| if (l.owner == owner) {
            l.dead = true;
        };
    }

    pub fn closeKey(h: *Host, owner: u64, key_id: u32) bool {
        for (h.links.items) |l| if (l.owner == owner and l.codec.key_id == key_id) {
            l.dead = true;
            return true;
        };
        return false;
    }

    // ── The poll loop ───────────────────────────────────────────────────────

    /// How many descriptors `pollFds` adds.
    pub fn fdCount(h: *const Host) usize {
        return if (h.udp < 0) 0 else 1 + h.links.items.len;
    }

    /// Adds the UDP socket, then the `inner` end of each link.
    pub fn pollFds(h: *const Host, fds: *std.ArrayList(lib_posix.pollfd), gpa: std.mem.Allocator) !void {
        if (h.udp < 0) return;
        try fds.append(gpa, .{ .fd = h.udp, .events = lib_posix.POLL.IN, .revents = 0 });
        for (h.links.items) |l| {
            var ev: i16 = 0;
            if (l.st.room() > 0) ev |= lib_posix.POLL.IN;
            if (l.to_inner.items.len > 0) ev |= lib_posix.POLL.OUT;
            try fds.append(gpa, .{ .fd = l.inner, .events = ev, .revents = 0 });
        }
    }

    /// Runs what the poll found. `fds` is what `pollFds` added, in the same
    /// order. Call it also on a timeout, with the time.
    pub fn handle(h: *Host, fds: []const lib_posix.pollfd, now: i64) void {
        if (h.udp < 0) return;
        if (fds.len > 0) {
            // The list can be shorter than the links if one was added since.
            if (fds[0].revents & lib_posix.POLL.IN != 0) h.readUdp(now);
            for (fds[1..], 0..) |pfd, i| {
                if (i >= h.links.items.len) break;
                const l = h.links.items[i];
                if (pfd.revents & lib_posix.POLL.IN != 0) h.readInner(l);
                if (pfd.revents & (lib_posix.POLL.HUP | lib_posix.POLL.ERR) != 0 and pfd.revents & lib_posix.POLL.IN == 0) l.dead = true;
                if (pfd.revents & lib_posix.POLL.OUT != 0) writeInner(l);
            }
        }
        for (h.links.items) |l| {
            if (!l.dead) h.transmit(l, now);
            if (!l.dead and l.remote == null and now - l.opened_at >= first_packet_ms) l.dead = true;
            if (!l.dead and now - l.last_rx >= idle_ms) l.dead = true;
        }
        h.reap();
    }

    /// The time until `handle` has something to do, in ms, or -1.
    pub fn timeout(h: *const Host, now: i64) i32 {
        var next: ?i64 = null;
        for (h.links.items) |l| {
            var d = if (l.remote == null) l.opened_at + first_packet_ms else l.st.deadline(now);
            d = @min(d, l.last_rx + idle_ms);
            next = @min(next orelse d, d);
        }
        const d = next orelse return -1;
        return @intCast(std.math.clamp(d - now, 0, std.math.maxInt(i32)));
    }

    // ── Pieces ──────────────────────────────────────────────────────────────

    fn readUdp(h: *Host, now: i64) void {
        h.refill(now);
        var buf: [packet.max_packet + 1]u8 = undefined;
        var n: usize = 0;
        while (n < pass_packets) : (n += 1) {
            var from: Addr = .{ .len = @sizeOf(c.sockaddr.storage) };
            const got = c.recvfrom(h.udp, &buf, buf.len, 0, @ptrCast(&from.storage), &from.len);
            if (got < 0) return;
            const len: usize = @intCast(got);
            if (len < packet.overhead or len > packet.max_packet) continue;
            const key_id = std.mem.readInt(u32, buf[0..4], .little);
            const l = h.find(key_id) orelse continue;
            // A source that is not the link's client pays for its check.
            const known = if (l.remote) |r| r.eql(&from) else false;
            if (!known) {
                if (h.tokens < 1) continue;
                h.tokens -= 1;
            }
            const opened = l.codec.open(buf[0..len]) catch continue;
            l.last_rx = now;
            if (opened.newest or l.remote == null) l.remote = from;
            if (l.st.receive(now, opened.payload)) |bytes| {
                if (l.to_inner.items.len + bytes.len > to_inner_cap) {
                    l.dead = true;
                    continue;
                }
                l.to_inner.appendSlice(h.gpa, bytes) catch {
                    l.dead = true;
                    continue;
                };
                writeInner(l);
            }
        }
    }

    fn readInner(h: *Host, l: *Link) void {
        _ = h;
        var buf: [16 * 1024]u8 = undefined;
        const want = @min(buf.len, l.st.room());
        if (want == 0) return;
        const n = lib_posix.read(l.inner, buf[0..want]) catch |err| switch (err) {
            error.WouldBlock => return,
            else => {
                l.dead = true;
                return;
            },
        };
        if (n == 0) {
            l.dead = true;
            return;
        }
        _ = l.st.write(buf[0..n]) catch {
            l.dead = true;
        };
    }

    fn writeInner(l: *Link) void {
        while (l.to_inner.items.len > 0) {
            const n = lib_posix.write(l.inner, l.to_inner.items) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    l.dead = true;
                    return;
                },
            };
            l.to_inner.replaceRangeAssumeCapacity(0, n, &.{});
        }
    }

    fn transmit(h: *Host, l: *Link, now: i64) void {
        const remote = l.remote orelse return;
        var payload: [packet.max_payload]u8 = undefined;
        var out: [packet.max_packet]u8 = undefined;
        var n: usize = 0;
        while (n < pass_packets) : (n += 1) {
            const p = l.st.next(now, &payload) orelse return;
            const sealed = l.codec.seal(&out, p) catch {
                // The counter is spent: the link is done.
                l.dead = true;
                return;
            };
            _ = c.sendto(h.udp, sealed.ptr, sealed.len, 0, @ptrCast(&remote.storage), remote.len);
        }
    }

    fn refill(h: *Host, now: i64) void {
        if (h.tokens_at != 0 and now > h.tokens_at) {
            const s: f64 = @floatFromInt(now - h.tokens_at);
            h.tokens = @min(bucket_size, h.tokens + s * bucket_per_s / 1000.0);
        }
        h.tokens_at = now;
    }

    fn find(h: *Host, key_id: u32) ?*Link {
        for (h.links.items) |l| if (l.codec.key_id == key_id and !l.dead) return l;
        return null;
    }

    /// Closes the links that ended. The server calls it after it ended some
    /// (`closeOwner`), so a socket does not wait for the next wake.
    pub fn reap(h: *Host) void {
        var i: usize = 0;
        while (i < h.links.items.len) {
            if (h.links.items[i].dead) {
                const l = h.links.orderedRemove(i);
                l.deinit(h.gpa);
            } else i += 1;
        }
        if (h.links.items.len == 0) h.closeUdp();
    }

    fn closeUdp(h: *Host) void {
        if (h.udp >= 0) lib_posix.close(h.udp);
        h.udp = -1;
        h.port = 0;
    }

    /// Tries the ports of the range from a random start. Dual stack when the
    /// host has IPv6, else IPv4.
    fn openUdp(h: *Host, ports: [2]u16, seed: u32) OpenError!void {
        if (ports[0] > ports[1]) return error.NoPort;
        const span: u32 = @as(u32, ports[1] - ports[0]) + 1;
        const start = seed % span;
        for ([_]bool{ true, false }) |v6| {
            const fd = c.socket(if (v6) c.AF.INET6 else c.AF.INET, c.SOCK.DGRAM, 0);
            if (fd < 0) continue;
            setNonblockingCloexec(fd) catch {
                lib_posix.close(fd);
                continue;
            };
            if (v6) {
                const off: c_int = 0;
                _ = c.setsockopt(fd, c.IPPROTO.IPV6, c.IPV6.V6ONLY, std.mem.asBytes(&off), @sizeOf(c_int));
            }
            var i: u32 = 0;
            while (i < span) : (i += 1) {
                const port: u16 = ports[0] + @as(u16, @intCast((start + i) % span));
                if (bindAny(fd, v6, port)) {
                    h.udp = fd;
                    h.port = port;
                    return;
                }
            }
            lib_posix.close(fd);
        }
        return error.NoPort;
    }
};

fn bindAny(fd: i32, v6: bool, port: u16) bool {
    if (v6) {
        var a: c.sockaddr.in6 = std.mem.zeroes(c.sockaddr.in6);
        a.family = c.AF.INET6;
        a.port = std.mem.nativeToBig(u16, port);
        return c.bind(fd, @ptrCast(&a), @sizeOf(c.sockaddr.in6)) == 0;
    }
    var a: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    a.family = c.AF.INET;
    a.port = std.mem.nativeToBig(u16, port);
    return c.bind(fd, @ptrCast(&a), @sizeOf(c.sockaddr.in)) == 0;
}

fn setNonblockingCloexec(fd: i32) !void {
    const fl = try lib_posix.fcntl(fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(fd, lib_posix.F.SETFL, fl | lib_posix.O_NONBLOCK);
    _ = try lib_posix.fcntl(fd, lib_posix.F.SETFD, 1); // FD_CLOEXEC
}

const testing = std.testing;

fn testKey() [packet.key_len]u8 {
    var k: [packet.key_len]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i + 1);
    return k;
}

/// A client socket for the tests: sends sealed packets to the host's port on
/// the loopback and reads what comes back.
const TestClient = struct {
    fd: i32,
    codec: packet.Link,
    st: stream.Stream,
    port: u16,

    fn init(port: u16, key_id: u32) !TestClient {
        const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        try testing.expect(fd >= 0);
        try setNonblockingCloexec(fd);
        return .{
            .fd = fd,
            .codec = packet.Link.init(testKey(), key_id, .client_to_host),
            .st = stream.Stream.init(testing.allocator),
            .port = port,
        };
    }

    fn deinit(t: *TestClient) void {
        lib_posix.close(t.fd);
        t.st.deinit();
    }

    /// Sends what the stream has.
    fn send(t: *TestClient, now: i64) !void {
        var a: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
        a.family = c.AF.INET;
        a.port = std.mem.nativeToBig(u16, t.port);
        a.addr = std.mem.nativeToBig(u32, 0x7f000001);
        var payload: [packet.max_payload]u8 = undefined;
        var out: [packet.max_packet]u8 = undefined;
        while (t.st.next(now, &payload)) |p| {
            const sealed = try t.codec.seal(&out, p);
            _ = c.sendto(t.fd, sealed.ptr, sealed.len, 0, @ptrCast(&a), @sizeOf(c.sockaddr.in));
        }
    }

    /// Reads what arrived, and returns the stream bytes.
    fn recv(t: *TestClient, now: i64, into: *std.ArrayList(u8)) !void {
        var buf: [packet.max_packet + 1]u8 = undefined;
        while (true) {
            const got = c.recvfrom(t.fd, &buf, buf.len, 0, null, null);
            if (got < 0) return;
            const opened = t.codec.open(buf[0..@intCast(got)]) catch continue;
            if (t.st.receive(now, opened.payload)) |bytes| try into.appendSlice(testing.allocator, bytes);
        }
    }
};

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, null);
}

fn runHost(h: *Host, now: i64) void {
    var fds: std.ArrayList(lib_posix.pollfd) = .empty;
    defer fds.deinit(testing.allocator);
    h.pollFds(&fds, testing.allocator) catch return;
    _ = lib_posix.poll(fds.items, 0) catch {};
    h.handle(fds.items, now);
}

test "bytes go both ways through a link, and the client's address is learned" {
    var h = Host.init(testing.allocator);
    defer h.deinit();
    const o = try h.open(1, testKey(), 77, 1000, .{ 62001, 62099 }, 0);
    defer lib_posix.close(o.peer_fd);
    try testing.expect(o.port >= 62001 and o.port <= 62099);

    var t = try TestClient.init(o.port, 77);
    defer t.deinit();
    _ = try t.st.write("to the server");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    // The host writes "from the server" into its socket pair end.
    _ = c.write(o.peer_fd, "from the server", 15);

    var now: i64 = 1000;
    var at_server: [64]u8 = undefined;
    var at_server_len: usize = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        now += 10;
        try t.send(now);
        sleepMs(2);
        runHost(&h, now);
        try t.recv(now, &got);
        const n = lib_posix.read(o.peer_fd, at_server[at_server_len..]) catch 0;
        at_server_len += n;
        if (got.items.len == 15 and at_server_len == 13) break;
    }
    try testing.expectEqualStrings("from the server", got.items);
    try testing.expectEqualStrings("to the server", at_server[0..at_server_len]);
    try testing.expect(h.links.items[0].remote != null);
}

test "a packet that does not authenticate gets no reply and moves nothing" {
    var h = Host.init(testing.allocator);
    defer h.deinit();
    const o = try h.open(1, testKey(), 5, 1000, .{ 62101, 62199 }, 0);
    defer lib_posix.close(o.peer_fd);
    var t = try TestClient.init(o.port, 5);
    defer t.deinit();
    t.codec.deinit();
    var wrong = testKey();
    wrong[0] ^= 1;
    t.codec = packet.Link.init(wrong, 5, .client_to_host);
    _ = try t.st.write("x");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var now: i64 = 1000;
    for (0..10) |_| {
        now += 10;
        try t.send(now);
        sleepMs(2);
        runHost(&h, now);
        try t.recv(now, &got);
    }
    try testing.expectEqual(@as(usize, 0), got.items.len);
    try testing.expect(h.links.items[0].remote == null);
}

test "a link with no packet ends, the socket closes with the last link" {
    var h = Host.init(testing.allocator);
    defer h.deinit();
    const o = try h.open(1, testKey(), 9, 0, .{ 62201, 62299 }, 0);
    defer lib_posix.close(o.peer_fd);
    try testing.expect(h.udp >= 0);
    runHost(&h, first_packet_ms + 1);
    try testing.expectEqual(@as(usize, 0), h.links.items.len);
    try testing.expect(h.udp < 0);
}

test "the owner's end closes its links, a key id is used once" {
    var h = Host.init(testing.allocator);
    defer h.deinit();
    const a = try h.open(1, testKey(), 1, 0, .{ 62301, 62399 }, 0);
    defer lib_posix.close(a.peer_fd);
    try testing.expectError(error.KeyInUse, h.open(2, testKey(), 1, 0, .{ 62301, 62399 }, 0));
    h.closeOwner(1);
    runHost(&h, 1);
    try testing.expectEqual(@as(usize, 0), h.links.items.len);
}

test "a range with no free port is refused" {
    var h = Host.init(testing.allocator);
    defer h.deinit();
    try testing.expectError(error.NoPort, h.open(1, testKey(), 1, 0, .{ 5, 4 }, 0));
}
