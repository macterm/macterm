const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;
const build_options = @import("build_options");
const log = @import("log.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const v2session = @import("session.zig");
const v2server = @import("server.zig");
const v2proxy = @import("proxy.zig");
const runtime = @import("runtime.zig");
const Resize = @import("pty.zig").Resize;
const v2attach = @import("attach.zig");
const socket = @import("socket.zig");
const protocol = @import("protocol/protocol.zig");
const version = build_options.version;
const ghostty_version = build_options.ghostty_version;

pub const std_options: std.Options = .{
    .logFn = log.zmxLogFn,
    .log_level = .debug,
};

/// Prints an error message to stderr and exits with status 1.
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("error: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}
pub fn main(init: std.process.Init) !void {
    mainImpl(init) catch |err| switch (err) {
        error.Sighup => signal.reraise(.HUP),
        error.Sigint => signal.reraise(.INT),
        error.Sigterm => signal.reraise(.TERM),
        else => return err,
    };
}

fn mainImpl(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Every subcommand may write to a Unix-domain socket; a peer that
    // disappears between probe and send would otherwise kill us before
    // write() can return BrokenPipe. Inherited across fork, so this also
    // covers the daemon.
    signal.ignoreSigpipe();

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // skip program name
    const first_arg = args.next();

    // No log file until a session opens its own: lines go to stderr.
    log.log_system.io = io;

    const cmd = first_arg orelse return help(io);
    if (std.mem.eql(u8, cmd, "session")) return sessionCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, v2session.command_name)) return sessionEntry(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "server")) return serverCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "connect")) return connectCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "proxy")) return proxyCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) return printVersion(io);
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return help(io);
    return printError(io, "unknown command \"{s}\"", .{cmd});
}

/// `session [--cols N] [--rows N] [--cwd DIR] <name> [--] [command...]`: asks
/// the server to start a session, and starts the server when its socket does
/// not answer. Returns once the session's socket accepts connections. Not in
/// `help`: tests run it.
fn sessionCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    var name: []const u8 = "";
    var size: Resize = .{ .cols = 80, .rows = 24 };
    var cwd: ?[]const u8 = null;
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    while (args.next()) |arg| {
        if (name.len > 0) {
            if (command.items.len == 0 and std.mem.eql(u8, arg, "--")) continue;
            try command.append(gpa, arg);
        } else if (std.mem.eql(u8, arg, "--cols") or std.mem.eql(u8, arg, "--rows")) {
            const value = args.next() orelse return printError(io, "{s} requires a number", .{arg});
            const n = std.fmt.parseInt(u16, value, 10) catch 0;
            if (n == 0) return printError(io, "{s}: not a size: {s}", .{ arg, value });
            if (arg[2] == 'c') size.cols = n else size.rows = n;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            cwd = args.next() orelse return printError(io, "--cwd requires a directory", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return printError(io, "unknown option \"{s}\"", .{arg});
        } else {
            name = arg;
        }
    }
    if (name.len == 0) return printError(io, "session name required", .{});
    if (!v2session.validName(name)) return printError(io, "invalid session name \"{s}\": use letters, digits, '-', '_' and '.', not first", .{name});

    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    runtime.ensureDir(dir) catch |err| return printError(io, "runtime directory {s} {s}", .{ dir, runtime.describe(err) });
    // The server gives out a session that runs. This command makes a new one.
    const path = try socket.getSocketPath(gpa, dir, name);
    defer gpa.free(path);
    if (socket.connectSession(path)) |fd| {
        lib_posix.close(fd);
        return printError(io, "session \"{s}\" already exists", .{name});
    } else |_| {}

    const outcome = v2attach.createSession(gpa, dir, name, .{
        .command = if (command.items.len > 0) command.items else null,
        .cwd = cwd,
        .size = size,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return printError(io, "cannot start session \"{s}\": {s}", .{ name, @errorName(err) }),
    };
    if (outcome) |o| switch (o) {
        .not_created => |text| return printError(io, "{s}", .{text}),
        .session_too_old, .refused => return printError(io, "cannot start session \"{s}\": the server runs another build", .{name}),
        else => return printError(io, "cannot start session \"{s}\"", .{name}),
    };
}

/// `server`: starts the v2 server (src/server.zig) unless one answers, and
/// returns when its socket accepts connections.
fn serverCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    if (args.next()) |arg| return printError(io, "unexpected argument \"{s}\"", .{arg});
    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    v2server.start(gpa, dir) catch |err| switch (err) {
        error.AlreadyRunning => {},
        error.RuntimeDir => {
            const reason = if (runtime.ensureDir(dir)) |_| "failed the check" else |e| runtime.describe(e);
            return printError(io, "runtime directory {s} {s}", .{ dir, reason });
        },
        else => return printError(io, "cannot start the server: {s}", .{@errorName(err)}),
    };
}

/// `proxy`: joins stdin and stdout to the server's socket, and starts the
/// server first when its socket does not answer (design/005, step 3). The
/// app runs it on a host through ssh, and so reaches every pane of the host
/// on one stream. Not in `help`: the app runs it.
fn proxyCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    if (args.next()) |arg| return printError(io, "unexpected argument \"{s}\"", .{arg});
    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    const fd = v2proxy.connect(gpa, dir) catch |err| switch (err) {
        error.RuntimeDir => {
            const reason = if (runtime.ensureDir(dir)) |_| "failed the check" else |e| runtime.describe(e);
            return printError(io, "runtime directory {s} {s}", .{ dir, reason });
        },
        else => return printError(io, "cannot reach the server: {s}", .{@errorName(err)}),
    };
    v2proxy.pump(fd, lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO);
}

/// `zmx connect <name> [-- command...]`: the pane's client of a v2 session
/// (attach.zig). With `--`, a missing session is made through the server
/// and runs the command.
fn connectCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    const name = args.next() orelse return printError(io, "session name required", .{});
    var create: ?v2attach.Create = null;
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    if (args.next()) |sep| {
        if (!std.mem.eql(u8, sep, "--")) return printError(io, "unexpected argument \"{s}\"", .{sep});
        while (args.next()) |arg| try command.append(gpa, arg);
        create = .{ .command = if (command.items.len > 0) command.items else null };
    }
    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    const outcome = v2attach.run(gpa, dir, name, create) catch |err| switch (err) {
        error.Sighup, error.Sigint, error.Sigterm => return err,
        error.InvalidName => return printError(io, "invalid session name \"{s}\"", .{name}),
        error.RuntimeDir => return printError(io, "runtime directory {s} failed the check", .{dir}),
        error.NoSession => return printError(io, "no session \"{s}\"", .{name}),
        error.WrongPeer => return printError(io, "session \"{s}\" belongs to another user", .{name}),
        error.NoAnswer => return printError(io, "session \"{s}\" did not answer", .{name}),
        error.Protocol => return printError(io, "connection to session \"{s}\" failed", .{name}),
        error.OutOfMemory => return err,
    };
    switch (outcome) {
        .session_too_old => |o| return printError(io, "session \"{s}\" speaks protocol level {d}, and this build needs level {d} or later", .{ name, o.level, o.min_level }),
        .refused => |r| {
            if (std.mem.eql(u8, r.reason, "level_too_low"))
                return printError(io, "session \"{s}\" needs protocol level {d} or later, and this build speaks level {d}", .{ name, r.needs_level, v2attach.protocol_level });
            return printError(io, "session \"{s}\" refused this build: {s}", .{ name, r.reason });
        },
        .closed => return printError(io, "session \"{s}\" closed", .{name}),
        .not_created => |text| return printError(io, "cannot start session \"{s}\": {s}", .{ name, text }),
        else => std.process.exit(v2attach.exitCode(outcome)),
    }
}

/// The session process; not a user command. The server starts it
/// (`Server.spawn`) with argv `__session <name>` and its spec, one msgpack
/// `SessionCreate.Args`, on `session.spec_fd`.
fn sessionEntry(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    const name = args.next() orelse return printError(io, "{s}: session name required", .{v2session.command_name});
    const fd = v2session.spec_fd;
    // The shell must not get the server's end of the answer.
    _ = lib_posix.fcntl(fd, lib_posix.F.SETFD, std.c.FD_CLOEXEC) catch
        return printError(io, "{s}: no spec on fd {d}", .{ v2session.command_name, fd });
    var spec: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = lib_posix.read(fd, &buf) catch |err| return printError(io, "{s}: cannot read the spec: {s}", .{ v2session.command_name, @errorName(err) });
        if (n == 0) break;
        if (spec.items.len + n > spec_max) return printError(io, "{s}: the spec is too large", .{v2session.command_name});
        try spec.appendSlice(gpa, buf[0..n]);
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_state.allocator();
    const create = protocol.msgpack.decodeSlice(protocol.messages.SessionCreate.Args, arena, spec.items) catch |err|
        return printError(io, "{s}: the spec does not decode: {s}", .{ v2session.command_name, @errorName(err) });
    if (!std.mem.eql(u8, create.id, name)) return printError(io, "{s}: the spec names another session", .{v2session.command_name});
    var command: ?[]const []const u8 = null;
    if (create.command) |argv| {
        const list = try arena.alloc([]const u8, argv.len);
        for (argv, list) |arg, *item| item.* = arg.bytes;
        command = list;
    }
    const dir = try runtime.resolveDir(gpa, env);
    v2session.run(dir, .{
        .name = name,
        .command = command,
        .shell = env.get("SHELL") orelse "/bin/sh",
        .size = .{ .cols = create.cols, .rows = create.rows },
    }, if (create.cwd) |c| c.bytes else null, fd);
}

/// The largest spec that `__session` reads.
const spec_max = 1024 * 1024;

fn help(io: std.Io) !void {
    const help_text =
        \\zmx - the Macterm session server
        \\
        \\Usage: zmx <command> [args...]
        \\
        \\Commands:
        \\  connect <name> [-- command...]   Attach this terminal to a session. With --,
        \\                                   make the session if it is not there.
        \\  [v]ersion                        Show the version
        \\  [h]elp                           Show this help
        \\
        \\Ctrl+\ detaches.
        \\
        \\Environment variables:
        \\  MACTERM_RUNTIME_DIR  The folder of the sockets of the server and the sessions
        \\  ZMX_NO_DETACH_KEY    Disables the Ctrl+\ detach key (set to any value)
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(help_text);
    try w.interface.flush();
}

fn printVersion(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("zmx\t\t{s}\nghostty_vt\t{s}\n", .{ version, ghostty_version });
    try w.interface.flush();
}
