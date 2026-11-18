//! The CLI's connection to the local server (design 011 §7): socket
//! discovery, the handshake, and one request at a time.
//!
//! - **The CLI never starts the server.** v1's wait loop
//!   (`until macterm status; do sleep 0.2; done`) needs `status` to fail
//!   while the app is not up. Only `server`, `proxy` and `connect --` start it.
//! - **Discovery**: `--socket` pins one socket. Else `MACTERM_RUNTIME_DIR`
//!   pins the server socket of that folder: the app sets it in every pane,
//!   and a test that sets it must never reach the user's own server. Else
//!   the folder of each build flavor, Release first, as
//!   `LocalServer.runtimeDirectory` makes it. `MACTERM_SOCKET` is not read:
//!   it names the app's v1 `control.sock`, which this CLI does not speak.
//! - A server that answers is the target, also when it refuses: the CLI
//!   never goes on to another server after one answered.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib_posix = @import("../posix.zig");
const runtime = @import("../runtime.zig");
const socket = @import("../socket.zig");
const server = @import("../server.zig");
const protocol = @import("../protocol/protocol.zig");
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const m = protocol.messages;

/// How long the server may take to answer the handshake.
const handshake_timeout_ms = 5000;
/// How long the server may take to answer a request, as the v1 CLI.
const request_timeout_ms = 10_000;

/// The folder names of the build flavors (`LocalServer.folderName`).
const flavors = [_][]const u8{ "macterm", "macterm-debug" };

/// The sockets to try, in order.
pub fn candidates(arena: std.mem.Allocator, env: *const std.process.Environ.Map, pin: ?[]const u8) error{OutOfMemory}![]const []const u8 {
    if (pin) |path| if (path.len > 0) return arena.dupe([]const u8, &.{path});
    var paths: std.ArrayList([]const u8) = .empty;
    if (nonEmpty(env, runtime.dir_env)) |dir| {
        try paths.append(arena, try std.fs.path.join(arena, &.{ dir, server.socket_name }));
        return paths.items;
    }
    for (flavors) |name| {
        const dir = if (nonEmpty(env, "XDG_RUNTIME_DIR")) |base|
            try std.fs.path.join(arena, &.{ base, name })
        else if (builtin.os.tag.isDarwin() and nonEmpty(env, "TMPDIR") != null)
            try std.fs.path.join(arena, &.{ nonEmpty(env, "TMPDIR").?, name })
        else if (nonEmpty(env, "HOME")) |home|
            try std.fs.path.join(arena, &.{ home, ".local", "state", name, "run" })
        else
            continue;
        try paths.append(arena, try std.fs.path.join(arena, &.{ dir, server.socket_name }));
    }
    return paths.items;
}

fn nonEmpty(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    if (value.len == 0) return null;
    var v = value;
    while (v.len > 1 and v[v.len - 1] == '/') v = v[0 .. v.len - 1];
    return v;
}

/// A socket that did not lead to a server, and why.
pub const Attempt = struct { path: []const u8, reason: []const u8 };

pub const Connect = union(enum) {
    ok: Connection,
    /// No socket led to a server: exit 2.
    no_server: []const Attempt,
    /// A server answered and refused this CLI, or broke the protocol: exit 1.
    failed: []const u8,
};

/// Connects to the first socket of `paths` whose server answers the
/// handshake.
pub fn connect(arena: std.mem.Allocator, paths: []const []const u8) error{OutOfMemory}!Connect {
    var attempts: std.ArrayList(Attempt) = .empty;
    for (paths) |path| {
        const fd = open(path) catch |err| {
            try attempts.append(arena, .{ .path = path, .reason = switch (err) {
                error.NoFile => "no socket file",
                error.Refused => "connection refused",
                error.Failed => "cannot connect",
            } });
            continue;
        };
        if (!runtime.allowPeer(runtime.peerUid(fd), std.c.getuid())) {
            lib_posix.close(fd);
            try attempts.append(arena, .{ .path = path, .reason = "the socket belongs to another user" });
            continue;
        }
        var c: Connection = .{ .arena = arena, .fd = fd, .path = path, .pid = peerPid(fd) };
        switch (try c.handshake()) {
            .ok => return .{ .ok = c },
            .no_answer => {
                lib_posix.close(fd);
                try attempts.append(arena, .{ .path = path, .reason = "no answer to the handshake" });
            },
            .failed => |message| {
                lib_posix.close(fd);
                return .{ .failed = message };
            },
        }
    }
    return .{ .no_server = attempts.items };
}

fn open(path: []const u8) error{ NoFile, Refused, Failed }!i32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.Failed;
    if (std.c.access(z, std.c.F_OK) != 0) return error.NoFile;
    return socket.connectSession(path) catch |err| switch (err) {
        error.ConnectionRefused => error.Refused,
        error.Unexpected => error.Failed,
    };
}

/// The pid of a Unix socket's peer, from the kernel: the server cannot say
/// another pid. Null when the system does not say.
pub fn peerPid(fd: i32) ?i64 {
    if (comptime builtin.os.tag.isDarwin()) {
        const sol_local = 0;
        const local_peerpid = 0x002;
        var pid: std.c.pid_t = 0;
        var len: std.c.socklen_t = @sizeOf(std.c.pid_t);
        if (std.c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or pid <= 0) return null;
        return pid;
    } else if (comptime builtin.os.tag == .linux) {
        const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
        var cred: Ucred = undefined;
        var len: std.c.socklen_t = @sizeOf(Ucred);
        if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.PEERCRED, &cred, &len) != 0 or cred.pid <= 0) return null;
        return cred.pid;
    } else return null;
}

/// The `hello` of this CLI. The server refuses any other build (`negotiate`).
pub fn helloMessage() m.Hello {
    return .{
        .level = m.level,
        .min_level = m.min_level,
        .build = build_options.version,
        .build_key = build_options.key,
        .role = .cli,
        .epoch = 0,
        .caps = &.{},
    };
}

pub const Connection = struct {
    arena: std.mem.Allocator,
    fd: i32,
    path: []const u8,
    /// The server process, from the socket.
    pid: ?i64,
    /// The server's `hello`.
    hello: m.Hello = undefined,
    in: std.ArrayList(u8) = .empty,
    consumed: usize = 0,
    next_id: u64 = 1,

    const Handshake = union(enum) { ok, no_answer, failed: []const u8 };

    fn handshake(c: *Connection) error{OutOfMemory}!Handshake {
        const mine = helloMessage();
        c.sendControl(mine) catch return .no_answer;
        while (true) {
            const body = (c.nextMessage(handshake_timeout_ms) catch return .no_answer) orelse return .no_answer;
            switch (m.decodeControl(c.arena, body) catch return .no_answer) {
                .hello => |theirs| {
                    // Its strings point into `in`, which the next read reuses.
                    c.hello = theirs;
                    c.hello.build = try c.arena.dupe(u8, theirs.build);
                    c.hello.build_key = if (theirs.build_key) |k| try c.arena.dupe(u8, k) else null;
                    c.hello.caps = &.{};
                    switch (m.negotiate(mine, theirs)) {
                        .refuse => |r| {
                            c.sendControl(r) catch {};
                            return .{ .failed = try refusal(c.arena, c.path, r.reason, theirs.build) };
                        },
                        .speak => return .ok,
                    }
                },
                .refuse => |r| return .{ .failed = try refusal(c.arena, c.path, r.reason, null) },
                else => {},
            }
        }
    }

    /// The reply to one request: the method's result, or the server's error.
    pub fn Reply(comptime M: type) type {
        return union(enum) { ok: M.Result, err: m.ErrorInfo };
    }

    pub const RequestError = error{
        OutOfMemory,
        /// The connection ended or the time ran out before the reply.
        NoReply,
        /// The reply does not decode.
        Protocol,
    };

    /// Sends one request and waits for its reply. Events are skipped.
    pub fn request(c: *Connection, comptime M: type, args: M.Args) RequestError!Reply(M) {
        const id = c.next_id;
        c.next_id += 1;
        var out: std.Io.Writer.Allocating = .init(c.arena);
        m.encodeRequest(&out.writer, id, M, args) catch return error.OutOfMemory;
        c.sendFrame(out.written()) catch return error.NoReply;
        while (true) {
            const body = (try c.nextMessage(request_timeout_ms)) orelse return error.NoReply;
            switch (m.decodeControl(c.arena, body) catch return error.Protocol) {
                .response => |res| {
                    if (res.re != id) continue;
                    if (res.err) |e| return .{ .err = e };
                    return .{ .ok = m.decodeResult(M, c.arena, res) catch return error.Protocol };
                },
                else => {},
            }
        }
    }

    pub fn close(c: *Connection) void {
        lib_posix.close(c.fd);
    }

    fn sendControl(c: *Connection, value: anytype) error{ OutOfMemory, Failed }!void {
        try c.sendFrame(try msgpack.encodeAlloc(c.arena, value));
    }

    fn sendFrame(c: *Connection, body: []const u8) error{Failed}!void {
        var header: [frame.header_len]u8 = undefined;
        frame.writeHeader(&header, frame.control_channel, .msg, body.len) catch return error.Failed;
        writeAll(c.fd, &header) catch return error.Failed;
        writeAll(c.fd, body) catch return error.Failed;
    }

    /// The body of the next channel 0 message, waiting at most `timeout_ms`
    /// for each read. Null on a timeout or at the end of the stream. Frames
    /// of other channels are skipped.
    fn nextMessage(c: *Connection, timeout_ms: i32) RequestError!?[]const u8 {
        while (true) {
            c.in.replaceRangeAssumeCapacity(0, c.consumed, &.{});
            c.consumed = 0;
            if (frame.parse(c.in.items) catch return error.Protocol) |p| {
                c.consumed = p.len;
                if (p.frame.channel != frame.control_channel) continue;
                return p.frame.body;
            }
            var fds = [_]lib_posix.pollfd{.{ .fd = c.fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            const ready = lib_posix.poll(&fds, timeout_ms) catch return null;
            if (ready == 0) return null;
            var buf: [64 * 1024]u8 = undefined;
            const n = lib_posix.read(c.fd, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return null,
            };
            if (n == 0) return null;
            try c.in.appendSlice(c.arena, buf[0..n]);
        }
    }
};

fn refusal(arena: std.mem.Allocator, path: []const u8, reason: []const u8, their_build: ?[]const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.eql(u8, reason, "build_mismatch")) {
        if (their_build) |build|
            return std.fmt.allocPrint(arena, "the server at {s} runs build {s}, and this CLI is build {s}", .{ path, build, build_options.version });
        return std.fmt.allocPrint(arena, "the server at {s} runs another build, and this CLI is build {s}", .{ path, build_options.version });
    }
    return std.fmt.allocPrint(arena, "the server at {s} refused this CLI: {s}", .{ path, reason });
}

fn writeAll(fd: i32, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const n = try lib_posix.write(fd, rest);
        rest = rest[n..];
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testEnv(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "--socket pins one socket, and MACTERM_RUNTIME_DIR pins its folder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(&.{ .{ "MACTERM_RUNTIME_DIR", "/run/x/" }, .{ "TMPDIR", "/tmp/u" } });
    defer env.deinit();
    const pinned = try candidates(a, &env, "/s");
    try testing.expectEqual(1, pinned.len);
    try testing.expectEqualStrings("/s", pinned[0]);
    const dir = try candidates(a, &env, null);
    try testing.expectEqual(1, dir.len);
    try testing.expectEqualStrings("/run/x/.server", dir[0]);
}

test "with no pin, each build flavor's folder is tried, Release first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env = try testEnv(&.{ .{ "XDG_RUNTIME_DIR", "/run/user/1" }, .{ "MACTERM_RUNTIME_DIR", "" } });
    defer env.deinit();
    const paths = try candidates(arena.allocator(), &env, null);
    try testing.expectEqual(2, paths.len);
    try testing.expectEqualStrings("/run/user/1/macterm/.server", paths[0]);
    try testing.expectEqualStrings("/run/user/1/macterm-debug/.server", paths[1]);

    var home = try testEnv(&.{.{ "HOME", "/h" }});
    defer home.deinit();
    const from_home = try candidates(arena.allocator(), &home, null);
    try testing.expectEqualStrings("/h/.local/state/macterm/run/.server", from_home[0]);
    try testing.expectEqualStrings("/h/.local/state/macterm-debug/run/.server", from_home[1]);
}

test "a missing socket is no server, with the reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = try connect(arena.allocator(), &.{"/nonexistent/macterm/.server"});
    try testing.expectEqual(1, result.no_server.len);
    try testing.expectEqualStrings("no socket file", result.no_server[0].reason);
}

test "a socket pair's peer pid is this process" {
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(0, std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try testing.expectEqual(@as(i64, std.c.getpid()), peerPid(fds[0]).?);
}
