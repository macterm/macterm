//! `macterm askpass <prompt>` (design 011 §2): the `SSH_ASKPASS` of a host's
//! ssh master (design/005 step 2), through the `macterm-askpass` shim. It
//! sends ssh's prompt to the app that started that ssh
//! (`MACTERM_ASKPASS_SOCKET`, the app's `control.sock`) as the v1 request
//! `ssh.askpass`, and prints the answer for ssh. The app answers only when
//! the parent of this process is one of its ssh masters. Exit 1: the user
//! cancelled or the app refused, and ssh stops the login.
//!
//! `fixtures/askpass.json` holds the requests and the replies. The tests
//! below and `SSHWrapperTests` read the same file, so that this side and the
//! app's `ControlProtocol` agree.

const std = @import("std");
const lib_posix = @import("../posix.zig");
const socket = @import("../socket.zig");
const runtime = @import("../runtime.zig");
const output = @import("output.zig");

/// The variable that names the app's socket. `SSHConnections` sets it for
/// its ssh masters.
pub const socket_variable = "MACTERM_ASKPASS_SOCKET";

/// An answer can take some time: the limit of the login is the server's
/// `LoginGraceTime`.
pub const answer_timeout_s = 600;

/// The v1 request line, with its newline.
pub fn requestLine(arena: std.mem.Allocator, id: []const u8, prompt: []const u8, confirm: bool) error{OutOfMemory}![]const u8 {
    const Args = struct { prompt: []const u8, confirm: ?bool };
    const Request = struct { v: u32, id: []const u8, command: []const u8, args: Args };
    const json = try std.json.Stringify.valueAlloc(arena, Request{
        .v = 1,
        .id = id,
        .command = "ssh.askpass",
        .args = .{ .prompt = prompt, .confirm = if (confirm) true else null },
    }, .{ .emit_null_optional_fields = false });
    return std.mem.concat(arena, u8, &.{ json, "\n" });
}

/// What the app's reply says.
pub const Reply = union(enum) {
    answer: []const u8,
    /// The app refused or the user cancelled. The message is the app's, or
    /// null when it gave none.
    refused: ?[]const u8,
    /// Not a v1 reply to this request: the text of the failure.
    invalid: []const u8,
};

pub fn parseReply(arena: std.mem.Allocator, raw: []const u8, id: []const u8) error{OutOfMemory}!Reply {
    const Response = struct {
        v: i64,
        id: []const u8,
        ok: bool,
        data: ?struct { askpass: ?struct { answer: []const u8 } = null } = null,
        @"error": ?struct { code: []const u8, message: []const u8, action: ?[]const u8 = null } = null,
    };
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const r = std.json.parseFromSliceLeaky(Response, arena, text, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = @errorName(err) },
    };
    if (!std.mem.eql(u8, r.id, id)) return .{ .invalid = "response id mismatch" };
    if (r.ok) if (r.data) |d| if (d.askpass) |a| return .{ .answer = a.answer };
    return .{ .refused = if (r.@"error") |e| e.message else null };
}

/// Runs the command. `prompt` is ssh's text.
pub fn run(arena: std.mem.Allocator, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, prompt: []const u8) error{ OutOfMemory, WriteFailed }!u8 {
    const mode = env.get("SSH_ASKPASS_PROMPT") orelse "";
    // "none" tells that ssh ends the prompt itself (a security key to
    // touch). There is nothing to answer.
    if (std.mem.eql(u8, mode, "none")) return 0;
    const confirm = std.mem.eql(u8, mode, "confirm");
    const path = env.get(socket_variable) orelse "";
    if (path.len == 0) {
        try output.writeError(err, "macterm askpass runs only for an ssh that Macterm started", null);
        return 1;
    }
    const id = try std.fmt.allocPrint(arena, "askpass-{d}", .{std.c.getpid()});
    const raw = switch (try exchange(arena, path, try requestLine(arena, id, prompt, confirm))) {
        .ok => |r| r,
        .failed => |reason| {
            try output.writeError(err, try std.fmt.allocPrint(arena, "could not reach Macterm's control socket:\n  {s}: {s}", .{ path, reason }), null);
            return 1;
        },
    };
    switch (try parseReply(arena, raw, id)) {
        .answer => |answer| {
            if (!confirm) try out.print("{s}\n", .{answer});
            return 0;
        },
        .refused => |message| {
            if (message) |text| try output.writeError(err, text, null);
            return 1;
        },
        .invalid => |reason| {
            try output.writeError(err, try std.fmt.allocPrint(arena, "undecodable response from {s}: {s}", .{ path, reason }), null);
            return 1;
        },
    }
}

const Exchange = union(enum) { ok: []const u8, failed: []const u8 };

/// One v1 round trip: connect, write the line, close the write end, read
/// to the end.
fn exchange(arena: std.mem.Allocator, path: []const u8, line: []const u8) error{OutOfMemory}!Exchange {
    const fd = socket.connectSession(path) catch |e| return .{ .failed = switch (e) {
        error.ConnectionRefused => "connection refused",
        error.Unexpected => "cannot connect",
    } };
    defer lib_posix.close(fd);
    // The same user only, as the v1 client: checked on the connected peer.
    if (runtime.peerUid(fd) != std.c.getuid()) return .{ .failed = "socket peer is not the current user; refusing to connect" };

    const timeout: std.c.timeval = .{ .sec = answer_timeout_s, .usec = 0 };
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(std.c.timeval));
    var rest = line;
    while (rest.len > 0) {
        const n = lib_posix.write(fd, rest) catch return .{ .failed = "write failed" };
        rest = rest[n..];
    }
    _ = std.c.shutdown(fd, std.c.SHUT.WR);

    var reply: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = lib_posix.read(fd, &buf) catch |e| return .{ .failed = switch (e) {
            error.WouldBlock => "timed out waiting for a response",
            else => "read failed",
        } };
        if (n == 0) break;
        try reply.appendSlice(arena, buf[0..n]);
    }
    return .{ .ok = reply.items };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// One line of `fixtures/askpass.json`. `request` is the line that the CLI
/// sends, as JSON with no `id`; `response` is the app's line, whose `id`
/// is `$ID`. `SSHWrapperTests` decodes both with `ControlProtocol`.
pub const Fixture = struct {
    name: []const u8,
    prompt: []const u8,
    mode: ?[]const u8 = null,
    request: ?std.json.Value = null,
    response: ?[]const u8 = null,
    stdout: []const u8,
    stderr: []const u8,
    exit: u8,
};

pub const fixtures_json = @embedFile("fixtures/askpass.json");

/// The app's side for one connection: reads the request line, keeps it, and
/// writes `response` with the request's id.
const Stub = struct {
    listen_fd: i32,
    response: []const u8,
    request: []const u8 = "",
    arena: std.mem.Allocator,

    fn serve(s: *Stub) void {
        var fds = [_]lib_posix.pollfd{.{ .fd = s.listen_fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        _ = lib_posix.poll(&fds, 5000) catch return;
        const fd = std.c.accept(s.listen_fd, null, null);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var got: std.ArrayList(u8) = .empty;
        var buf: [1024]u8 = undefined;
        while (true) {
            var rfds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            if ((lib_posix.poll(&rfds, 5000) catch 0) == 0) return;
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) break;
            got.appendSlice(s.arena, buf[0..@intCast(n)]) catch return;
        }
        s.request = got.items;
        const parsed = std.json.parseFromSliceLeaky(struct { id: []const u8 }, s.arena, got.items, .{ .ignore_unknown_fields = true }) catch return;
        const line = std.mem.replaceOwned(u8, s.arena, s.response, "$ID", parsed.id) catch return;
        _ = std.c.write(fd, line.ptr, line.len);
    }
};

test "askpass passes the shared fixtures" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = try std.json.parseFromSliceLeaky([]const Fixture, arena, fixtures_json, .{});
    const path = try std.fmt.allocPrint(arena, "/tmp/macterm-askpass-test-{d}.sock", .{std.c.getpid()});
    const path_z = try arena.dupeSentinel(u8, path, 0);
    for (cases) |c| {
        _ = std.c.unlink(path_z);
        var env: std.process.Environ.Map = .init(arena);
        if (c.mode) |mode| try env.put("SSH_ASKPASS_PROMPT", mode);
        var stub: Stub = .{ .listen_fd = -1, .response = c.response orelse "", .arena = arena };
        var thread: ?std.Thread = null;
        if (c.response != null) {
            try env.put(socket_variable, path);
            stub.listen_fd = try socket.createSocket(path);
            thread = try std.Thread.spawn(.{}, Stub.serve, .{&stub});
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        const exit = try run(arena, &env, &out.writer, &err.writer, c.prompt);
        if (thread) |t| {
            t.join();
            lib_posix.close(stub.listen_fd);
        }
        testing.expectEqualStrings(c.stdout, out.written()) catch |e| {
            std.debug.print("case {s}\n", .{c.name});
            return e;
        };
        try testing.expectEqualStrings(c.stderr, err.written());
        try testing.expectEqual(c.exit, exit);
        if (c.request) |want| {
            var got = (try std.json.parseFromSliceLeaky(std.json.Value, arena, stub.request, .{})).object;
            try testing.expect(got.orderedRemove("id"));
            try testing.expectEqualStrings(try std.json.Stringify.valueAlloc(arena, want, .{}), try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = got }, .{}));
        }
    }
    _ = std.c.unlink(path_z);
}

test "a reply to another request or that is not JSON is invalid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("response id mismatch", (try parseReply(arena, "{\"v\":2,\"id\":\"b\",\"ok\":true}\n", "a")).invalid);
    try testing.expect((try parseReply(arena, "nope", "a")) == .invalid);
}
