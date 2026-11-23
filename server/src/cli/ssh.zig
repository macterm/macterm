//! `macterm ssh` (design 011 §2): ghostty's `+ssh` action, as the Swift CLI
//! does it with `SSHWrapper`. It needs no server and no app.
//!
//! 1. Find the destination with `ssh -G` (the `user` and `hostname` keys).
//! 2. Unless the cache has it, install the `xterm-ghostty` entry on the
//!    destination: the embedded source goes to a remote `tic -x -o
//!    ~/.terminfo -` over a `ControlMaster` that ends with the install. A
//!    good install goes into the cache at once, so that a session that ends
//!    with an error does not install again next time.
//! 3. Become the real ssh (`execvp`), with `SetEnv=TERM=…` (`xterm-ghostty`
//!    when the entry is known to be on the host, else `xterm-256color`) and
//!    `SendEnv` for `COLORTERM`, `TERM_PROGRAM` and `TERM_PROGRAM_VERSION`.
//!
//! A failure in step 1 or 2 prints a warning and uses `xterm-256color`: it
//! never stops the connection.
//!
//! The app keeps its Swift `SSHWrapper` for `RemoteTerminfo`. The rules here
//! and there must agree: `fixtures/ssh.json` holds the cases, and
//! `SSHWrapperTests` and the tests below read the same file (no FFI).

const std = @import("std");
const lib_posix = @import("../posix.zig");
const command = @import("command.zig");
const output = @import("output.zig");

/// The entry that the install puts on the host and `SetEnv=TERM=` names.
/// `SSHWrapper.entryName` and `RemoteTerminfo.entryName` are the same.
pub const entry_name = "xterm-ghostty";

/// TERM when the entry is not known to be on the host: every terminfo
/// database has it.
pub const fallback_term = "xterm-256color";

/// The entry as `infocmp -x xterm-ghostty` prints it from the terminfo of
/// the pinned GhosttyKit, without its first line (a comment with the path of
/// the database). `SSHWrapperTests` checks that it is the bundled entry.
pub const terminfo_source = @embedFile("terminfo/xterm-ghostty.terminfo");

// ── The rules (the same as `SSHWrapper`) ────────────────────────────────────

/// The ssh arguments of what the command took. Each shell integration
/// calls `ghostty +ssh <flags> -- "$@"`, and the command keeps that `--`.
/// Given to ssh, it would end ssh's own options: `ssh -p 2222 prod` would
/// connect to a host named `-p`.
pub fn relayedArguments(captured: []const []const u8) []const []const u8 {
    if (captured.len > 0 and std.mem.eql(u8, captured[0], "--")) return captured[1..];
    return captured;
}

/// `ssh -G <args>`: ssh prints its configuration for the arguments (aliases
/// and `~/.ssh/config` applied) and does not connect.
pub fn destinationArgv(arena: std.mem.Allocator, ssh: []const u8, args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    return concat(arena, &.{ &.{ ssh, "-G" }, args });
}

/// `user@hostname` from the output of `ssh -G`: the first `user` and
/// `hostname` lines. Null when one is missing: ghostty then does no
/// install, and does not guess.
pub fn parseDestination(arena: std.mem.Allocator, config_dump: []const u8) error{OutOfMemory}!?[]const u8 {
    var user: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, config_dump, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..space];
        const value = line[space + 1 ..];
        if (value.len == 0) continue;
        if (user == null and std.mem.eql(u8, key, "user")) user = value;
        if (host == null and std.mem.eql(u8, key, "hostname")) host = value;
        if (user != null and host != null) break;
    }
    if (user == null or host == null) return null;
    return try std.fmt.allocPrint(arena, "{s}@{s}", .{ user.?, host.? });
}

/// The remote install command, as ghostty's `+ssh` sends it
/// (ghostty-org/ghostty#15061, #15112): compile from stdin into
/// `~/.terminfo` (`-o`, so that a `tic` that runs as root does not write the
/// system database), then check that `infocmp` finds the entry. Verbose
/// keeps the stderr of `tic`.
///
/// sshd gives the remote command to the host's login shell, and a login
/// shell that is not POSIX (nushell, tcsh) cannot read it, so it goes as
/// `sh -c '<script>'`. The script has no single quote.
pub fn installScript(verbose: bool) []const u8 {
    return if (verbose)
        "sh -c 'tic -x -o ~/.terminfo - && infocmp -x " ++ entry_name ++ " >/dev/null'"
    else
        "sh -c 'tic -x -o ~/.terminfo - 2>/dev/null && infocmp -x " ++ entry_name ++ " >/dev/null 2>&1'";
}

/// The install, with the source on stdin, over a `ControlMaster` for this
/// install only (`ControlPersist=no` removes the socket at the end). The
/// user's own arguments go too, so their port, key and alias apply, and
/// the login can ask for a password as the real one does (no `BatchMode`).
///
/// As in ghostty: when the arguments end in a remote command (`ssh host
/// uptime`), ssh adds the script to it, the install fails, and the
/// connection uses `xterm-256color`.
pub fn installArgv(arena: std.mem.Allocator, ssh: []const u8, control_path: []const u8, args: []const []const u8, verbose: bool) error{OutOfMemory}![]const []const u8 {
    const path_option = try std.fmt.allocPrint(arena, "ControlPath={s}", .{control_path});
    return concat(arena, &.{
        &.{ ssh, "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-o", path_option },
        args,
        &.{installScript(verbose)},
    });
}

/// The ssh that the command becomes. With `term` (`--forward-env`, the
/// default): `SetEnv=TERM=…`, which ssh sends with the pty request, so that
/// no `AcceptEnv` of the server drops it (OpenSSH 8.7 and later), and
/// `SendEnv` requests that the server can refuse. With no `term`: ssh as
/// the user wrote it.
pub fn execArgv(arena: std.mem.Allocator, ssh: []const u8, term: ?[]const u8, args: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const t = term orelse return concat(arena, &.{ &.{ssh}, args });
    return concat(arena, &.{ &.{ssh}, try forwardingOptions(arena, t), args });
}

/// The options that `execArgv` puts before the user's own.
pub fn forwardingOptions(arena: std.mem.Allocator, term: []const u8) error{OutOfMemory}![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "-o", try std.fmt.allocPrint(arena, "SetEnv=TERM={s}", .{term}),
        "-o", "SendEnv=COLORTERM",
        "-o", "SendEnv=TERM_PROGRAM",
        "-o", "SendEnv=TERM_PROGRAM_VERSION",
    });
}

fn concat(arena: std.mem.Allocator, parts: []const []const []const u8) error{OutOfMemory}![]const []const u8 {
    return std.mem.concat(arena, []const u8, parts);
}

// ── The install cache ───────────────────────────────────────────────────────

/// The key of the entry: the first 8 bytes of the SHA-256 of its source, in
/// hex. A GhosttyKit pin that changes the entry changes the key, and each
/// host gets the new entry one time.
pub fn versionKey(source: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

/// One `<destination>\t<version>` line for each host. It is in
/// `~/Library/Caches` on every system and for every build flavor, because
/// it records the state of a host, not of the app.
pub fn cacheFilePath(arena: std.mem.Allocator, home: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/Library/Caches/macterm/ssh-terminfo", .{home});
}

/// The two fields of a cache line: the text before the first tab and the
/// text after it. Null for a line with no tab or an empty field.
fn cacheLine(line: []const u8) ?struct { []const u8, []const u8 } {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    if (tab == 0 or tab + 1 == line.len) return null;
    return .{ line[0..tab], line[tab + 1 ..] };
}

pub fn cacheContains(cache_text: []const u8, destination: []const u8, version: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, cache_text, '\n');
    while (lines.next()) |line| {
        const fields = cacheLine(line) orelse continue;
        if (std.mem.eql(u8, fields[0], destination) and std.mem.eql(u8, fields[1], version)) return true;
    }
    return false;
}

/// The cache text with `destination` at `version`. An older line of the
/// same destination goes.
pub fn cacheUpdating(arena: std.mem.Allocator, cache_text: []const u8, destination: []const u8, version: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, cache_text, '\n');
    while (lines.next()) |line| {
        const first = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        if (std.mem.eql(u8, first, destination)) continue;
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    try out.print(arena, "{s}\t{s}\n", .{ destination, version });
    return out.items;
}

// ── The command ─────────────────────────────────────────────────────────────

pub const Options = struct {
    forward_env: bool = true,
    terminfo: bool = true,
    cache: bool = true,
    ssh: []const u8 = "ssh",
    verbose: bool = false,
};

/// What the command does at the end: become this ssh, or exit.
pub const Plan = union(enum) { exec: []const []const u8, exit: u8 };

/// Where `plan` reads and writes.
pub const Env = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    /// The cache is in its `Library/Caches`. Null: no cache.
    home: ?[]const u8,
    /// The folder of the install's `ControlPath`, with a `/` at the end.
    tmp: []const u8,
    err: *std.Io.Writer,
};

/// Steps 1 and 2. Returns the ssh to become.
pub fn plan(env: Env, options: Options, captured: []const []const u8) error{ OutOfMemory, WriteFailed }!Plan {
    const args = relayedArguments(captured);
    if (args.len == 0) {
        try output.writeError(env.err, "no ssh arguments provided", null);
        return .{ .exit = 2 };
    }
    const term = if (options.terminfo) try settleTerminfo(env, options, args) else fallback_term;
    const argv = try execArgv(env.arena, options.ssh, if (options.forward_env) term else null, args);
    if (options.verbose) try writeVerbose(env, "exec: {s}", .{try std.mem.join(env.arena, " ", argv)});
    return .{ .exec = argv };
}

/// The terminfo step: find the destination, read the cache, install when
/// the cache does not have it. Returns the TERM to give.
fn settleTerminfo(env: Env, options: Options, args: []const []const u8) error{ OutOfMemory, WriteFailed }!([]const u8) {
    const dump = (try runChild(env.arena, try destinationArgv(env.arena, options.ssh, args), .{})) orelse "";
    const destination = (try parseDestination(env.arena, dump)) orelse {
        try writeWarning(env, "could not resolve the ssh destination. Skipping the terminfo install", .{});
        return fallback_term;
    };
    const version = versionKey(terminfo_source);
    const cache_path: ?[]const u8 = if (options.cache) if (env.home) |home| try cacheFilePath(env.arena, home) else null else null;

    if (cache_path) |path| {
        if (cacheContains(try readCache(env, path), destination, &version)) {
            if (options.verbose) try writeVerbose(env, "dest: {s} (cached, install skipped)", .{destination});
            return entry_name;
        }
        if (options.verbose) try writeVerbose(env, "dest: {s} (not cached, will install)", .{destination});
    } else if (options.verbose) try writeVerbose(env, "dest: {s} (cache disabled, will install)", .{destination});

    try env.err.print("Setting up {s} terminfo on {s}...\n", .{ entry_name, destination });
    // The pid makes the path unique among the processes that run now, and
    // `ControlPersist=no` removes the socket at the end.
    const control_path = try std.fmt.allocPrint(env.arena, "{s}macterm-ssh-{x:0>8}", .{ env.tmp, @as(u32, @bitCast(std.c.getpid())) });
    const argv = try installArgv(env.arena, options.ssh, control_path, args, options.verbose);
    if (options.verbose) try writeVerbose(env, "exec: {s}", .{try std.mem.join(env.arena, " ", argv)});
    // Before the child writes to the same stderr.
    try env.err.flush();
    // This is the user's first connection: the login can ask on the tty.
    if ((try runChild(env.arena, argv, .{ .stdin = terminfo_source, .capture = false, .inherit_stderr = options.verbose })) == null) {
        try writeWarning(env, "failed to install terminfo. Continuing with {s}", .{fallback_term});
        return fallback_term;
    }
    if (cache_path) |path| try writeCache(env, path, destination, &version, options.verbose);
    return entry_name;
}

fn readCache(env: Env, path: []const u8) error{OutOfMemory}![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(env.io, path, env.arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => "",
    };
}

fn writeCache(env: Env, path: []const u8, destination: []const u8, version: []const u8, verbose: bool) error{ OutOfMemory, WriteFailed }!void {
    const text = try cacheUpdating(env.arena, try readCache(env, path), destination, version);
    const cwd = std.Io.Dir.cwd();
    const written = write: {
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(env.io, dir) catch |err| break :write err;
        // A file that another process writes at the same time is never
        // half written: the text goes to a new file, which then replaces it.
        var atomic = cwd.createFileAtomic(env.io, path, .{ .replace = true }) catch |err| break :write err;
        defer atomic.deinit(env.io);
        atomic.file.writeStreamingAll(env.io, text) catch |err| break :write err;
        atomic.replace(env.io) catch |err| break :write err;
        break :write {};
    };
    if (written) |_| {
        if (verbose) try writeVerbose(env, "cache: wrote {s}", .{destination});
    } else |err| try writeWarning(env, "unable to write the cache '{s}': {s}", .{ path, @errorName(err) });
}

fn writeVerbose(env: Env, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
    try env.err.print("+ssh: " ++ fmt ++ "\n", args);
}

fn writeWarning(env: Env, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
    try env.err.print("Warning: " ++ fmt ++ "\n", args);
}

/// `true` or `false`, as ArgumentParser reads a `Bool` option. Null for a
/// value that is neither.
pub fn parseBool(value: ?[]const u8, default: bool) ?bool {
    const v = value orelse return default;
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

/// Reads the options of `macterm ssh`, or writes the usage error.
pub fn readOptions(err: *std.Io.Writer, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!?Options {
    var o: Options = .{ .verbose = parsed.flag("--verbose") };
    if (parsed.value("--ssh")) |s| o.ssh = s;
    inline for (.{ .{ "--forward-env", "forward-env", &o.forward_env }, .{ "--terminfo", "terminfo", &o.terminfo }, .{ "--cache", "cache", &o.cache } }) |entry| {
        const value = parsed.value(entry[0]);
        entry[2].* = parseBool(value, entry[2].*) orelse {
            var buf: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "The value '{s}' is invalid for '{s} <{s}>'", .{ value.?, entry[0], entry[1] }) catch "invalid value";
            try command.writeUsageError(err, parsed.path, message);
            return null;
        };
    }
    return o;
}

// ── Child processes ─────────────────────────────────────────────────────────

const Child = struct {
    /// Written to the child's stdin, which is then closed. Null: the child
    /// reads this process's stdin.
    stdin: ?[]const u8 = null,
    /// Read the child's stdout. Else it goes to /dev/null.
    capture: bool = true,
    /// The child writes to this process's stderr. Else to /dev/null.
    inherit_stderr: bool = false,
};

/// Runs `argv` (the program found in `PATH`, as the exec at the end finds
/// it) to its end. Returns its stdout when it exits with 0, else null.
fn runChild(arena: std.mem.Allocator, argv: []const []const u8, child: Child) error{OutOfMemory}!?[]const u8 {
    const argv_z = try argvZ(arena, argv);
    const out = if (child.capture) lib_posix.pipe2(.{ .CLOEXEC = true }) catch return null else null;
    defer if (out) |p| lib_posix.close(p[0]);
    const in = if (child.stdin != null) lib_posix.pipe2(.{ .CLOEXEC = true }) catch return null else null;
    // A child that exits before it reads all of stdin must not end this
    // process with SIGPIPE: the write fails instead.
    var old: lib_posix.Sigaction = undefined;
    lib_posix.sigaction(lib_posix.SIG.PIPE, &.{ .handler = .{ .handler = lib_posix.SIG.IGN }, .mask = lib_posix.sigemptyset(), .flags = 0 }, &old);
    defer lib_posix.sigaction(lib_posix.SIG.PIPE, &old, null);

    const pid = lib_posix.fork() catch {
        if (out) |p| lib_posix.close(p[1]);
        if (in) |p| for (p) |fd| lib_posix.close(fd);
        return null;
    };
    if (pid == 0) {
        lib_posix.sigaction(lib_posix.SIG.PIPE, &default_action, null);
        const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
        if (in) |p| lib_posix.dup2(p[0], 0) catch std.c._exit(127);
        lib_posix.dup2(if (out) |p| p[1] else null_fd, 1) catch std.c._exit(127);
        if (!child.inherit_stderr) lib_posix.dup2(null_fd, 2) catch std.c._exit(127);
        lib_posix.execvpeZ(argv_z[0].?, argv_z, @ptrCast(std.c.environ)) catch {};
        std.c._exit(127);
    }
    if (out) |p| lib_posix.close(p[1]);
    if (in) |p| {
        lib_posix.close(p[0]);
        writeAll(p[1], child.stdin.?);
        lib_posix.close(p[1]);
    }
    var text: std.ArrayList(u8) = .empty;
    if (out) |p| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = lib_posix.read(p[0], &buf) catch break;
            if (n == 0) break;
            try text.appendSlice(arena, buf[0..n]);
        }
    }
    const status = lib_posix.waitpid(pid, 0).status;
    if (!std.c.W.IFEXITED(status) or std.c.W.EXITSTATUS(status) != 0) return null;
    return text.items;
}

fn writeAll(fd: lib_posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = lib_posix.write(fd, rest) catch return;
        rest = rest[n..];
    }
}

const default_action: lib_posix.Sigaction = .{
    .handler = .{ .handler = lib_posix.SIG.DFL },
    .mask = undefined,
    .flags = 0,
};

fn argvZ(arena: std.mem.Allocator, argv: []const []const u8) error{OutOfMemory}![:null]?[*:0]const u8 {
    const list = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, list) |word, *z| z.* = try arena.dupeSentinel(u8, word, 0);
    return list;
}

/// Step 3: this process becomes `argv`. Returns only when the exec fails,
/// with the text of the failure.
pub fn exec(arena: std.mem.Allocator, argv: []const []const u8) error{OutOfMemory}![]const u8 {
    const argv_z = try argvZ(arena, argv);
    // The server ignores SIGPIPE, and an ignored signal stays ignored after
    // exec: ssh gets the default, as a shell does.
    var action = default_action;
    action.mask = lib_posix.sigemptyset();
    lib_posix.sigaction(lib_posix.SIG.PIPE, &action, null);
    const err = lib_posix.execvpeZ(argv_z[0].?, argv_z, @ptrCast(std.c.environ));
    return @errorName(err);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The cases that `SSHWrapperTests` also reads.
pub const Fixtures = struct {
    destination: []const struct { dump: []const u8, destination: ?[]const u8 },
    destination_argv: []const struct { ssh: []const u8, args: []const []const u8, argv: []const []const u8 },
    relayed: []const struct { captured: []const []const u8, args: []const []const u8 },
    exec: []const struct { ssh: []const u8, term: ?[]const u8, args: []const []const u8, argv: []const []const u8 },
    install: []const struct { ssh: []const u8, control_path: []const u8, args: []const []const u8, verbose: bool, argv: []const []const u8 },
    version_key: []const struct { source: []const u8, key: []const u8 },
    cache: []const struct { text: []const u8, destination: []const u8, version: []const u8, contains: bool, updated: []const u8 },
};

pub const fixtures_json = @embedFile("fixtures/ssh.json");

test "the ssh rules pass the shared fixtures" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try std.json.parseFromSliceLeaky(Fixtures, arena, fixtures_json, .{});
    for (f.destination) |c| {
        const got = try parseDestination(arena, c.dump);
        if (c.destination) |want| try testing.expectEqualStrings(want, got.?) else try testing.expect(got == null);
    }
    for (f.destination_argv) |c| try expectWords(c.argv, try destinationArgv(arena, c.ssh, c.args));
    for (f.relayed) |c| try expectWords(c.args, relayedArguments(c.captured));
    for (f.exec) |c| try expectWords(c.argv, try execArgv(arena, c.ssh, c.term, c.args));
    for (f.install) |c| try expectWords(c.argv, try installArgv(arena, c.ssh, c.control_path, c.args, c.verbose));
    for (f.version_key) |c| try testing.expectEqualStrings(c.key, &versionKey(c.source));
    for (f.cache) |c| {
        try testing.expectEqual(c.contains, cacheContains(c.text, c.destination, c.version));
        try testing.expectEqualStrings(c.updated, try cacheUpdating(arena, c.text, c.destination, c.version));
    }
}

fn expectWords(want: []const []const u8, got: []const []const u8) !void {
    testing.expectEqual(want.len, got.len) catch |e| {
        std.debug.print("want {f}\n got {f}\n", .{ std.json.fmt(want, .{}), std.json.fmt(got, .{}) });
        return e;
    };
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
}

test "the install script has no single quote inside its sh -c" {
    for ([_]bool{ true, false }) |verbose| {
        const script = installScript(verbose);
        try testing.expect(std.mem.startsWith(u8, script, "sh -c '") and std.mem.endsWith(u8, script, "'"));
        const inner = script["sh -c '".len .. script.len - 1];
        try testing.expect(std.mem.indexOfAny(u8, inner, "'\n") == null);
    }
}

test "the embedded entry is the source of xterm-ghostty with extended capabilities" {
    try testing.expect(std.mem.startsWith(u8, terminfo_source, entry_name ++ "|"));
    try testing.expect(std.mem.indexOf(u8, terminfo_source, " Tc,") != null);
}

/// A stand-in ssh: `-G` prints a configuration, an install records its
/// arguments and stdin in `dir` and exits with the status in `dir/status`.
fn fakeSsh(io: std.Io, dir: std.Io.Dir, dir_path: []const u8, arena: std.mem.Allocator) ![]const u8 {
    const script = try std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\if [ "$1" = -G ]; then for a; do host=$a; done; [ "$host" = nohost ] && exit 255; printf 'user alice\nhostname %s\nport 22\n' "$host"; exit 0; fi
        \\printf '%s\n' "$@" > '{s}/install-args'
        \\cat > '{s}/install-stdin'
        \\exit "$(cat '{s}/status' 2>/dev/null || echo 0)"
        \\
    , .{ dir_path, dir_path, dir_path });
    try dir.writeFile(io, .{ .sub_path = "ssh", .data = script, .flags = .{ .permissions = .executable_file } });
    return std.fs.path.join(arena, &.{ dir_path, "ssh" });
}

test "ssh installs the entry once, caches the host and gives xterm-ghostty" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const ssh = try fakeSsh(io, tmp.dir, dir_path, arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const env: Env = .{ .arena = arena, .io = io, .home = dir_path, .tmp = "/tmp/", .err = &err.writer };

    const first = try plan(env, .{ .ssh = ssh }, &.{ "--", "-p", "2222", "prod" });
    try expectWords(try execArgv(arena, ssh, entry_name, &.{ "-p", "2222", "prod" }), first.exec);
    try testing.expectEqualStrings("Setting up xterm-ghostty terminfo on alice@prod...\n", err.written());
    try testing.expectEqualStrings(terminfo_source, try tmp.dir.readFileAlloc(io, "install-stdin", arena, .unlimited));
    const install_args = try tmp.dir.readFileAlloc(io, "install-args", arena, .unlimited);
    try testing.expect(std.mem.endsWith(u8, install_args, "-p\n2222\nprod\n" ++ comptime installScript(false) ++ "\n"));
    const version = versionKey(terminfo_source);
    const cache = try tmp.dir.readFileAlloc(io, "Library/Caches/macterm/ssh-terminfo", arena, .unlimited);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "alice@prod\t{s}\n", .{&version}), cache);

    // The second connection reads the cache and installs nothing.
    try tmp.dir.deleteFile(io, "install-stdin");
    err.clearRetainingCapacity();
    const second = try plan(env, .{ .ssh = ssh }, &.{"prod"});
    try expectWords(try execArgv(arena, ssh, entry_name, &.{"prod"}), second.exec);
    try testing.expectEqualStrings("", err.written());
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "install-stdin", .{}));
}

test "ssh falls back to xterm-256color when the install or the destination fails" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const ssh = try fakeSsh(io, tmp.dir, dir_path, arena);
    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = "1\n" });
    var err: std.Io.Writer.Allocating = .init(arena);
    const env: Env = .{ .arena = arena, .io = io, .home = dir_path, .tmp = "/tmp/", .err = &err.writer };

    const failed = try plan(env, .{ .ssh = ssh }, &.{"prod"});
    try expectWords(try execArgv(arena, ssh, fallback_term, &.{"prod"}), failed.exec);
    try testing.expect(std.mem.endsWith(u8, err.written(), "Warning: failed to install terminfo. Continuing with xterm-256color\n"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "Library/Caches/macterm/ssh-terminfo", .{}));

    err.clearRetainingCapacity();
    const unresolved = try plan(env, .{ .ssh = ssh }, &.{"nohost"});
    try expectWords(try execArgv(arena, ssh, fallback_term, &.{"nohost"}), unresolved.exec);
    try testing.expectEqualStrings("Warning: could not resolve the ssh destination. Skipping the terminfo install\n", err.written());

    // No terminfo step, and no forwarding: ssh as the user wrote it.
    err.clearRetainingCapacity();
    const plain = try plan(env, .{ .ssh = ssh, .terminfo = false, .forward_env = false }, &.{ "--", "prod", "uptime" });
    try expectWords(&.{ ssh, "prod", "uptime" }, plain.exec);
    try testing.expectEqualStrings("", err.written());

    const none = try plan(env, .{ .ssh = ssh }, &.{"--"});
    try testing.expectEqual(2, none.exit);
}
