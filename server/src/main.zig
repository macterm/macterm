const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;
const build_options = @import("build_options");
const log = @import("log.zig");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const daemonize = @import("daemonize.zig");
const schema = @import("protocol/schema.zig");
const v2session = @import("session.zig");
const v2server = @import("server.zig");
const v2proxy = @import("proxy.zig");
const runtime = @import("runtime.zig");
const v2attach = @import("attach.zig");
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

    // Needs no config, no log and no session directory: CI runs it.
    if (first_arg != null and std.mem.eql(u8, first_arg.?, "__schema")) {
        return schemaCommand(gpa, io, args.next(), args.next());
    }

    // No log file until a session opens its own: lines go to stderr.
    log.log_system.io = io;

    const cmd = first_arg orelse return help(io);
    if (std.mem.eql(u8, cmd, "session")) {
        const shell = init.environ_map.get("SHELL") orelse "/bin/sh";
        return sessionCommand(gpa, io, init.environ_map, shell, &args);
    }
    if (std.mem.eql(u8, cmd, v2session.reexec_command)) return sessionEntry(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "server")) return serverCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "connect")) return connectCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "proxy")) return proxyCommand(gpa, io, init.environ_map, &args);
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) return printVersion(io);
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) return help(io);
    return printError(io, "unknown command \"{s}\"", .{cmd});
}

/// `session [--cols N] [--rows N] [--cwd DIR] <name> [--] [command...]`: starts
/// a v2 session (session.zig) and returns once its socket accepts
/// connections. Not in `help` yet: the server (issue 0048) runs it.
fn sessionCommand(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, shell: []const u8, args: anytype) !void {
    var opts: v2session.Options = .{ .name = "", .shell = shell };
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    while (args.next()) |arg| {
        if (opts.name.len > 0) {
            if (command.items.len == 0 and std.mem.eql(u8, arg, "--")) continue;
            try command.append(gpa, arg);
        } else if (std.mem.eql(u8, arg, "--cols") or std.mem.eql(u8, arg, "--rows")) {
            const value = args.next() orelse return printError(io, "{s} requires a number", .{arg});
            const n = std.fmt.parseInt(u16, value, 10) catch 0;
            if (n == 0) return printError(io, "{s}: not a size: {s}", .{ arg, value });
            if (arg[2] == 'c') opts.size.cols = n else opts.size.rows = n;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            const dir = args.next() orelse return printError(io, "--cwd requires a directory", .{});
            const handle = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch |err|
                return printError(io, "cannot open directory {s}: {s}", .{ dir, @errorName(err) });
            defer handle.close(io);
            std.process.setCurrentDir(io, handle) catch |err|
                return printError(io, "cannot enter directory {s}: {s}", .{ dir, @errorName(err) });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return printError(io, "unknown option \"{s}\"", .{arg});
        } else {
            opts.name = arg;
        }
    }
    if (opts.name.len == 0) return printError(io, "session name required", .{});
    if (command.items.len > 0) opts.command = command.items;

    const dir = runtime.resolveDir(gpa, env) catch return printError(io, "no runtime directory: set {s}", .{runtime.dir_env});
    defer gpa.free(dir);
    v2session.start(gpa, io, dir, opts) catch |err| switch (err) {
        error.InvalidName => return printError(io, "invalid session name \"{s}\": use letters, digits, '-', '_' and '.', not first", .{opts.name}),
        error.NameTooLong => return printError(io, "session name \"{s}\" is too long for a socket in {s}", .{ opts.name, dir }),
        error.SessionExists => return printError(io, "session \"{s}\" already exists", .{opts.name}),
        error.RuntimeDir => {
            const reason = if (runtime.ensureDir(dir)) |_| "failed the check" else |e| runtime.describe(e);
            return printError(io, "runtime directory {s} {s}", .{ dir, reason });
        },
        else => return printError(io, "cannot start session \"{s}\": {s}", .{ opts.name, @errorName(err) }),
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
/// and runs the command. It becomes `macterm attach` when v1's `attach`
/// goes (design/007 §6).
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

/// The macOS v2 session after its disclaiming re-exec; not a user command.
/// argv is `__session <name> [-- command...]`, the rest rides in
/// `daemonize.reexec_env`, as for `__daemon`.
fn sessionEntry(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, args: anytype) !void {
    const name = args.next() orelse return printError(io, "{s}: session name required", .{v2session.reexec_command});
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    if (args.next()) |sep| {
        if (!std.mem.eql(u8, sep, "--")) return printError(io, "{s}: unexpected argument \"{s}\"", .{ v2session.reexec_command, sep });
        while (args.next()) |arg| try command.append(gpa, arg);
    }
    const state = (try daemonize.takeReexecState(gpa)) orelse
        return printError(io, "{s}: no re-exec state in the environment", .{v2session.reexec_command});
    const dir = try runtime.resolveDir(gpa, env);
    v2session.resumeAfterReexec(dir, .{
        .name = name,
        .command = if (command.items.len > 0) command.items else null,
        .shell = state.shell,
        .size = state.size,
    }, state.server_sock_fd);
}

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

/// `__schema swift | metadata | fixtures | foreground` writes that file of
/// the protocol schema to stdout. `__schema check [old-metadata.json]` checks this build's
/// schema against an older one and exits 1 on a problem (design/003 §3).
/// Hidden: `scripts/protocol.sh` runs it.
fn schemaCommand(gpa: std.mem.Allocator, io: std.Io, what: ?[]const u8, path: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    const kind = what orelse printError(io, "__schema needs swift, metadata, fixtures, foreground or check", .{});
    if (std.mem.eql(u8, kind, "swift")) {
        try schema.writeSwift(w, schema.metadata);
    } else if (std.mem.eql(u8, kind, "metadata")) {
        try schema.writeMetadata(w, schema.metadata);
    } else if (std.mem.eql(u8, kind, "fixtures")) {
        try schema.writeFixtures(arena, w);
    } else if (std.mem.eql(u8, kind, "foreground")) {
        try v2attach.writeForegroundFixtures(w);
    } else if (std.mem.eql(u8, kind, "check")) {
        const old: ?schema.Metadata = if (path) |p| blk: {
            const text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 * 1024 * 1024)) catch |err|
                printError(io, "cannot read {s}: {s}", .{ p, @errorName(err) });
            break :blk std.json.parseFromSliceLeaky(schema.Metadata, arena, text, .{ .ignore_unknown_fields = true }) catch |err|
                printError(io, "cannot parse {s}: {s}", .{ p, @errorName(err) });
        } else null;
        const problems = try schema.check(w, old, schema.metadata);
        try w.flush();
        if (problems > 0) printError(io, "{d} problems in the protocol schema", .{problems});
    } else {
        printError(io, "unknown __schema output {s}", .{kind});
    }
    try w.flush();
}

fn printVersion(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print("zmx\t\t{s}\nghostty_vt\t{s}\n", .{ version, ghostty_version });
    try w.interface.flush();
}
