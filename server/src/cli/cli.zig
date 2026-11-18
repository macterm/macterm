//! The `macterm` CLI in the server binary (design 011). It keeps the grammar,
//! the output and the exit codes of the v1 CLI (`golden/`):
//!
//! - 0: the command worked.
//! - 1: the server refused the command, or it failed.
//! - 2: no server answered.
//! - 64: a usage error (ArgumentParser's `EX_USAGE`).
//!
//! The Swift CLI stays `Resources/bin/macterm` until the swap (design 011
//! §3). Each port issue adds its verbs to `root`, and the golden tests below
//! check each one against the contract.

const std = @import("std");
const command = @import("command.zig");
const client = @import("client.zig");
const output = @import("output.zig");
const m = @import("../protocol/messages.zig");

const Command = command.Command;
const Option = command.Option;

/// Where a run reads and writes.
pub const Context = struct {
    /// An arena: the CLI is short-lived.
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
};

const socket_option: Option = .{ .names = &.{"--socket"}, .value = "socket", .abstract = "Control socket path. It overrides discovery." };
const json_option: Option = .{ .names = &.{"--json"}, .abstract = "Print the raw JSON payload instead of a table." };

const status_command: Command = .{
    .name = "status",
    .abstract = "Show whether Macterm is running and which project is active.",
    .options = &.{ socket_option, json_option },
};

/// `macterm help <subcommand>`: ArgumentParser's own help command.
const help_command: Command = .{ .name = "help", .abstract = "Show subcommand help information.", .hidden = true };

pub const root: Command = .{
    .name = "macterm",
    .abstract = "Control a running Macterm: projects, tabs, panes, zmx sessions.",
    .subcommands = &.{ &status_command, &help_command },
};

/// Runs one argument line (without the program name) and returns the exit
/// code.
pub fn run(ctx: Context, words: []const []const u8) error{ OutOfMemory, WriteFailed }!u8 {
    switch (try command.parse(ctx.arena, &root, words)) {
        .help => |path| {
            try command.writeHelp(ctx.out, path);
            return 0;
        },
        .usage_error => |e| {
            try command.writeUsageError(ctx.err, e.path, e.message);
            return command.usage_exit;
        },
        .run => |parsed| {
            const c = parsed.command();
            if (c == &status_command) return status(ctx, parsed);
            unreachable;
        },
    }
}

// ── status ──────────────────────────────────────────────────────────────────

/// What `status` prints, with the JSON keys of v1. `activeProject` and
/// `activeProjectID` come with the model (design 010); until then they are
/// absent, as v1 printed them with no active project.
pub const Status = struct {
    version: []const u8,
    pid: ?i64 = null,
    activeProject: ?[]const u8 = null,
    activeProjectID: ?[]const u8 = null,
};

/// `status`: the server's build and pid. It sends `ping`, so that a server
/// that answers the handshake but no request is not reported as up.
fn status(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    switch (conn.request(m.Ping, .{}) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => {},
        .err => |e| {
            try output.writeError(ctx.err, e.message, null);
            return 1;
        },
    }
    try writeStatus(ctx, .{ .version = conn.hello.build, .pid = if (conn.pid) |p| p else null }, parsed.flag("--json"));
    return 0;
}

fn writeStatus(ctx: Context, s: Status, json: bool) error{ OutOfMemory, WriteFailed }!void {
    if (json) {
        var fields: std.json.ObjectMap = .empty;
        try fields.put(ctx.arena, "version", .{ .string = s.version });
        if (s.pid) |pid| try fields.put(ctx.arena, "pid", .{ .integer = pid });
        if (s.activeProject) |p| try fields.put(ctx.arena, "activeProject", .{ .string = p });
        if (s.activeProjectID) |p| try fields.put(ctx.arena, "activeProjectID", .{ .string = p });
        var data: std.json.ObjectMap = .empty;
        try data.put(ctx.arena, "status", .{ .object = fields });
        return output.writeJson(ctx.arena, ctx.out, .{ .object = data });
    }
    try ctx.out.print("Macterm {s}", .{s.version});
    if (s.pid) |pid| try ctx.out.print(" (pid {d})", .{pid});
    if (s.activeProject) |p| try ctx.out.print(" \u{2014} active project: {s}", .{p});
    try ctx.out.writeByte('\n');
}

// ── The connection ──────────────────────────────────────────────────────────

const Connected = union(enum) { ok: client.Connection, exit: u8 };

/// Connects as `--socket` and the environment say, or prints why not and
/// gives the exit code.
fn connect(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!Connected {
    const pin = parsed.value("--socket");
    const paths = try client.candidates(ctx.arena, ctx.env, pin);
    switch (try client.connect(ctx.arena, paths)) {
        .ok => |c| return .{ .ok = c },
        .failed => |message| {
            try output.writeError(ctx.err, message, null);
            return .{ .exit = 1 };
        },
        .no_server => |attempts| {
            var text: std.Io.Writer.Allocating = .init(ctx.arena);
            const w = &text.writer;
            if (attempts.len == 0) {
                try output.writeError(ctx.err, "no runtime folder: set MACTERM_RUNTIME_DIR, or use --socket", null);
                return .{ .exit = 2 };
            }
            try w.writeAll("could not reach the Macterm server:");
            for (attempts) |a| try w.print("\n  {s}: {s}", .{ a.path, a.reason });
            if (pin == null or pin.?.len == 0)
                try w.writeAll("\nIs Macterm running? Start it, or use --socket for a different location.");
            try output.writeError(ctx.err, text.written(), null);
            return .{ .exit = 2 };
        },
    }
}

fn requestFailed(ctx: Context, conn: client.Connection, err: client.Connection.RequestError) error{ OutOfMemory, WriteFailed }!u8 {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoReply => {
            try ctx.err.print("macterm: the server at {s} stopped answering\n", .{conn.path});
            return 2;
        },
        error.Protocol => {
            try ctx.err.print("macterm: the server at {s} sent a reply that does not decode\n", .{conn.path});
            return 1;
        },
    }
}

// ── Tests: the golden files ─────────────────────────────────────────────────

const testing = std.testing;
const contract = @import("contract.zig");

const golden_cases_json = @embedFile("golden/cases.json");

/// The golden help text of each command that prints it byte for byte. A
/// group prints only the subcommands that are ported, so its help is checked
/// by structure alone.
const golden_help = .{
    .{ &status_command, @embedFile("golden/help/status.txt") },
};

fn collapse(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \n");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.items;
}

fn expectCommandMatchesContract(arena: std.mem.Allocator, spec: contract.Contract, path: []const *const Command) !void {
    const c = path[path.len - 1];
    const words = try arena.alloc([]const u8, path.len - 1);
    for (path[1..], words) |p, *w| w.* = p.name;
    const golden = spec.find(words) orelse {
        std.debug.print("macterm {f}: not in the contract\n", .{std.json.fmt(words, .{})});
        return error.NotInContract;
    };
    try testing.expectEqualStrings(golden.abstract, c.abstract);
    try testing.expectEqual(golden.hidden, c.hidden);
    try testing.expect(!golden.debug);
    if (c == &help_command) return;

    var usage: std.Io.Writer.Allocating = .init(arena);
    try command.writeUsage(&usage.writer, path);
    try testing.expectEqualStrings(golden.usage.?, usage.written());
    try testing.expect(golden.default == null);

    // Options: the same names, values and abstracts, in the same order.
    var visible: std.ArrayList(contract.Contract.Option) = .empty;
    for (golden.options) |o| if (!o.hidden) try visible.append(arena, o);
    var all: std.ArrayList(Option) = .empty;
    try all.appendSlice(arena, c.options);
    try all.append(arena, command.help_option);
    var n: usize = 0;
    for (all.items) |o| {
        defer n += 1;
        try testing.expect(n < visible.items.len);
        const g = visible.items[n];
        try testing.expectEqual(g.names.len, o.names.len);
        for (g.names, o.names) |a, b| try testing.expectEqualStrings(a, b);
        try testing.expectEqualStrings(g.value orelse "", o.value orelse "");
        try testing.expectEqualStrings(try collapse(arena, g.abstract), try collapse(arena, o.abstract));
    }
    try testing.expectEqual(visible.items.len, n);

    try testing.expectEqual(golden.arguments.len, c.arguments.len);
    for (golden.arguments, c.arguments) |g, a| {
        try testing.expectEqualStrings(g.name, a.name);
        try testing.expectEqual(g.optional, a.optional);
        try testing.expectEqualStrings(try collapse(arena, g.abstract), try collapse(arena, a.abstract));
    }

    // Subcommands: each ported one is in the contract, in the same order.
    var last: usize = 0;
    for (c.subcommands) |sub| {
        var at: ?usize = null;
        for (golden.subcommands, 0..) |name, k| {
            if (std.mem.eql(u8, name, sub.name)) at = k;
        }
        try testing.expect(at != null and at.? >= last);
        last = at.?;
        const child = try arena.alloc(*const Command, path.len + 1);
        @memcpy(child[0..path.len], path);
        child[path.len] = sub;
        try expectCommandMatchesContract(arena, spec, child);
    }
}

test "every ported command has the abstract, usage, options and arguments of the contract" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try contract.parseContract(arena.allocator());
    try expectCommandMatchesContract(arena.allocator(), spec, &.{&root});
}

test "the help of a ported leaf command is the golden text" {
    inline for (golden_help) |entry| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try command.writeHelp(&out.writer, &.{ &root, entry[0] });
        try testing.expectEqualStrings(entry[1], out.written());
    }
}

test "the root help lists the ported commands as the golden text does" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try command.writeHelp(&out.writer, &.{&root});
    try testing.expectEqualStrings(
        \\OVERVIEW: Control a running Macterm: projects, tabs, panes, zmx sessions.
        \\
        \\USAGE: macterm <subcommand>
        \\
        \\OPTIONS:
        \\  -h, --help              Show help information.
        \\
        \\SUBCOMMANDS:
        \\  status                  Show whether Macterm is running and which project is
        \\                          active.
        \\
        \\  See 'macterm help <subcommand>' for detailed help.
        \\
    , out.written());
}

const GoldenCase = struct {
    arguments: []const []const u8,
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
    requests: []const std.json.Value,
};

/// The v1 response of a canned case, as `ControlResponse` holds it.
const CannedStatus = struct {
    ok: bool,
    data: ?struct { status: Status } = null,
    @"error": ?struct { code: []const u8, message: []const u8, action: ?[]const u8 = null } = null,
};

test "status and usage errors print the golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec = try contract.parseContract(arena);
    const inputs = try contract.parseCases(arena);
    const goldens = try std.json.parseFromSliceLeaky([]const GoldenCase, arena, golden_cases_json, .{});
    try testing.expectEqual(inputs.len, goldens.len);

    var env: std.process.Environ.Map = .init(arena);
    var checked: usize = 0;
    for (inputs, goldens) |input, golden| {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
        const exit: u8 = switch (try command.parse(arena, &root, input.arguments)) {
            // A word that is not a command: the other verbs are not ported yet.
            .usage_error => if (spec.find(input.arguments[0..1]) == null) try run(ctx, input.arguments) else continue,
            .run => |parsed| if (parsed.command() == &status_command) exit: {
                try testing.expectEqualStrings("ping", input.method.?);
                const canned = try std.json.parseFromValueLeaky(CannedStatus, arena, input.responses.?.object.get("status").?, .{});
                if (canned.ok) {
                    try writeStatus(ctx, canned.data.?.status, parsed.flag("--json"));
                    break :exit 0;
                }
                try output.writeError(ctx.err, canned.@"error".?.message, canned.@"error".?.action);
                break :exit 1;
            } else continue,
            .help => continue,
        };
        testing.expectEqualStrings(golden.stdout, out.written()) catch |e| {
            std.debug.print("case {f}\n", .{std.json.fmt(input.arguments, .{})});
            return e;
        };
        try testing.expectEqualStrings(golden.stderr, err.written());
        try testing.expectEqual(golden.exit, exit);
        checked += 1;
    }
    // Five status lines and the unknown verb.
    try testing.expectEqual(6, checked);
}

test "status with no server exits 2 and names the socket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
    try testing.expectEqual(2, try run(ctx, &.{ "status", "--socket", "/nonexistent/.server" }));
    try testing.expectEqualStrings("", out.written());
    try testing.expectEqualStrings("macterm: could not reach the Macterm server:\n  /nonexistent/.server: no socket file\n", err.written());
}

// ── Tests: status against a stand-in server ─────────────────────────────────

const lib_posix = @import("../posix.zig");
const socket = @import("../socket.zig");
const frame = @import("../protocol/frame.zig");
const msgpack = @import("../protocol/msgpack.zig");
const build_options = @import("build_options");

/// A server on a real socket that answers one connection, on a thread of
/// its own. It records the method of the request that it got.
const Stub = struct {
    listen_fd: i32,
    build: []const u8,
    reply: enum { ok, err, garbage },
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    method: []const u8 = "",

    fn serve(s: *Stub) void {
        const a = s.arena.allocator();
        var fds = [_]lib_posix.pollfd{.{ .fd = s.listen_fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        _ = lib_posix.poll(&fds, 5000) catch return;
        const fd = std.c.accept(s.listen_fd, null, null);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        if (s.reply == .garbage) {
            writeAll(fd, "this is not a frame");
            return drain(fd);
        }
        sendMessage(a, fd, m.Hello{ .level = m.level, .min_level = m.min_level, .build = s.build, .role = .server, .epoch = 1, .caps = &.{} });
        _ = readMessage(a, fd) orelse return; // the CLI's hello
        const body = readMessage(a, fd) orelse return;
        const req = switch (m.decodeControl(a, body) catch return) {
            .request => |r| r,
            else => return,
        };
        s.method = req.m;
        switch (s.reply) {
            .ok => sendMessage(a, fd, struct { re: u64, ok: m.Ping.Result }{ .re = req.id, .ok = .{} }),
            .err => sendMessage(a, fd, struct { re: u64, err: m.ErrorInfo }{ .re = req.id, .err = .{ .code = "unavailable", .message = "the stand-in refused" } }),
            .garbage => unreachable,
        }
        drain(fd);
    }

    fn sendMessage(a: std.mem.Allocator, fd: i32, value: anytype) void {
        const body = msgpack.encodeAlloc(a, value) catch return;
        var header: [frame.header_len]u8 = undefined;
        frame.writeHeader(&header, frame.control_channel, .msg, body.len) catch return;
        writeAll(fd, &header);
        writeAll(fd, body);
    }

    fn writeAll(fd: i32, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n <= 0) return;
            rest = rest[@intCast(n)..];
        }
    }

    /// The body of the next frame, or null at the end of the stream.
    fn readMessage(a: std.mem.Allocator, fd: i32) ?[]const u8 {
        var header: [frame.header_len]u8 = undefined;
        if (!readExact(fd, &header)) return null;
        const len = std.mem.readInt(u32, header[0..4], .little);
        const body = a.alloc(u8, len) catch return null;
        if (!readExact(fd, body)) return null;
        return body;
    }

    fn readExact(fd: i32, buf: []u8) bool {
        var got: usize = 0;
        while (got < buf.len) {
            var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            const ready = lib_posix.poll(&fds, 5000) catch return false;
            if (ready == 0) return false;
            const n = std.c.read(fd, buf[got..].ptr, buf.len - got);
            if (n <= 0) return false;
            got += @intCast(n);
        }
        return true;
    }

    /// Waits until the CLI closes the connection.
    fn drain(fd: i32) void {
        var buf: [256]u8 = undefined;
        while (true) {
            var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            const ready = lib_posix.poll(&fds, 5000) catch return;
            if (ready == 0 or std.c.read(fd, &buf, buf.len) <= 0) return;
        }
    }
};

const StubRun = struct { exit: u8, out: []const u8, err: []const u8, method: []const u8, path: []const u8 };

fn runAgainstStub(arena: std.mem.Allocator, build: []const u8, reply: @FieldType(Stub, "reply"), json: bool) !StubRun {
    // Short: a socket path has at most 103 bytes on macOS.
    const path = try std.fmt.allocPrint(arena, "/tmp/macterm-cli-test-{d}.sock", .{std.c.getpid()});
    const path_z = try arena.dupeSentinel(u8, path, 0);
    _ = std.c.unlink(path_z);
    const listen_fd = try socket.createSocket(path);
    defer {
        lib_posix.close(listen_fd);
        _ = std.c.unlink(path_z);
    }
    var stub: Stub = .{ .listen_fd = listen_fd, .build = build, .reply = reply };
    defer stub.arena.deinit();
    const thread = try std.Thread.spawn(.{}, Stub.serve, .{&stub});

    var env: std.process.Environ.Map = .init(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
    const words: []const []const u8 = if (json) &.{ "status", "--json", "--socket", path } else &.{ "status", "--socket", path };
    const exit = try run(ctx, words);
    thread.join();
    return .{ .exit = exit, .out = out.written(), .err = err.written(), .method = try arena.dupe(u8, stub.method), .path = path };
}

test "status sends ping and prints the server's build and the pid of its socket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The stand-in runs in this process, so its pid is ours.
    const r = try runAgainstStub(arena, build_options.version, .ok, false);
    try testing.expectEqual(0, r.exit);
    try testing.expectEqualStrings("ping", r.method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "Macterm {s} (pid {d})\n", .{ build_options.version, std.c.getpid() }), r.out);
    try testing.expectEqualStrings("", r.err);

    const j = try runAgainstStub(arena, build_options.version, .ok, true);
    try testing.expectEqual(0, j.exit);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{{\n  \"status\" : {{\n    \"pid\" : {d},\n    \"version\" : \"{s}\"\n  }}\n}}\n", .{ std.c.getpid(), build_options.version }), j.out);
}

test "status prints the server's error and exits 1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const r = try runAgainstStub(arena_state.allocator(), build_options.version, .err, false);
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings("", r.out);
    try testing.expectEqualStrings("macterm: the stand-in refused\n", r.err);
}

test "status refuses a server of another build and exits 1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try runAgainstStub(arena, "0.0.0+other", .ok, false);
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings("", r.method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "macterm: the server at {s} runs build 0.0.0+other, and this CLI is build {s}\n", .{ r.path, build_options.version }), r.err);
}

test "status exits 1 for a program that does not speak the protocol" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try runAgainstStub(arena, build_options.version, .garbage, false);
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "macterm: the program at {s} does not speak the protocol of the Macterm server\n", .{r.path}), r.err);
}

test "status exits 2 for a path that is not a socket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "/tmp/macterm-cli-test-{d}.file", .{std.c.getpid()});
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z);
    var env: std.process.Environ.Map = .init(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
    try testing.expectEqual(2, try run(ctx, &.{ "status", "--socket", path }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "macterm: could not reach the Macterm server:\n  {s}: not a socket\n", .{path}), err.written());
}
