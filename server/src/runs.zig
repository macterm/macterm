//! `command.run`: a command that the server runs to its end, for the app's
//! background reads of a host (0058).

const std = @import("std");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const session = @import("session.zig");
const conn = @import("conn.zig");
const protocol = @import("protocol/protocol.zig");
const m = protocol.messages;
const server = @import("server.zig");
const peers = @import("peers.zig");
const Server = server.Server;
const Peer = peers.Peer;

/// The most commands that run at one time.
const max_runs = 16;

/// A `command.run` child. The reply goes when its stdout gave EOF and the
/// child was reaped.
pub const Run = struct {
    pid: lib_posix.pid_t,
    peer: u64,
    re: u64,
    /// The read end of the child's stdout. -1 after EOF.
    out_fd: i32,
    output: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    deadline: i64,
    timed_out: bool = false,
    status: ?session.ExitStatus = null,

    pub fn done(r: *const Run) bool {
        return r.out_fd < 0 and r.status != null;
    }
};

pub fn runCommand(s: *Server, p: *Peer, re: u64, args: m.CommandRun.Args) void {
    if (args.argv.len == 0 or args.argv[0].bytes.len == 0 or args.argv[0].bytes[0] != '/')
        return peers.replyError(s, p.id, re, .invalid_args, "The program must be an absolute path.");
    for (args.argv) |arg| if (std.mem.findScalar(u8, arg.bytes, 0) != null)
        return peers.replyError(s, p.id, re, .invalid_args, "A command argument cannot hold a NUL byte.");
    if (args.cwd) |cwd| if (cwd.bytes.len == 0 or cwd.bytes[0] != '/' or std.mem.findScalar(u8, cwd.bytes, 0) != null)
        return peers.replyError(s, p.id, re, .invalid_args, "The folder must be an absolute path.");
    if (args.timeout_ms == 0 or args.timeout_ms > m.run_timeout_max_ms)
        return peers.replyError(s, p.id, re, .invalid_args, "The time limit must be from 1 ms to 60 s.");
    if (s.runs.items.len >= max_runs)
        return peers.replyError(s, p.id, re, .busy, "Too many commands run now.");
    startRun(s, p.id, re, args) catch |err| {
        std.log.warn("server: cannot run a command: {s}", .{@errorName(err)});
        peers.replyError(s, p.id, re, .start_failed, "The server cannot start a process.");
    };
}

/// Forks the command in a process group of its own, with stdout on a
/// pipe. stdin and stderr are the server's `/dev/null` (`detachStdio`).
pub fn startRun(s: *Server, peer: u64, re: u64, args: m.CommandRun.Args) !void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    for (args.argv) |arg| try argv.append(arena, (try arena.dupeSentinel(u8, arg.bytes, 0)).ptr);
    try argv.append(arena, null);
    const cwd: ?[*:0]const u8 = if (args.cwd) |c| (try arena.dupeSentinel(u8, c.bytes, 0)).ptr else null;

    // Only the read end is non-blocking: a command that writes to a
    // non-blocking stdout fails on a full pipe.
    const pipe = try lib_posix.pipe2(.{ .CLOEXEC = true });
    errdefer lib_posix.close(pipe[0]);
    errdefer lib_posix.close(pipe[1]);
    const flags = try lib_posix.fcntl(pipe[0], lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(pipe[0], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);
    const r = try s.gpa.create(Run);
    errdefer s.gpa.destroy(r);
    r.* = .{ .pid = 0, .peer = peer, .re = re, .out_fd = pipe[0], .deadline = s.now() + args.timeout_ms };
    try s.runs.append(s.gpa, r);
    errdefer _ = s.runs.pop();

    // `main` ignores SIGPIPE, and that survives exec: the command gets
    // the default, as a session's shell does (`pty.zig`).
    const dfl: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.DFL },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    const pid = try lib_posix.fork();
    if (pid == 0) {
        lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);
        _ = std.c.setpgid(0, 0);
        lib_posix.dup2(pipe[1], lib_posix.STDOUT_FILENO) catch std.c._exit(127);
        if (cwd) |c| if (std.c.chdir(c) != 0) std.c._exit(126);
        _ = std.c.execve(argv.items[0].?, @ptrCast(argv.items.ptr), @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    lib_posix.close(pipe[1]);
    r.pid = pid;
    // The parent too, so that a SIGKILL at the deadline finds the group
    // even before the child ran its own `setpgid`.
    _ = std.c.setpgid(pid, pid);
}

/// Reads what the command wrote. Past `m.run_output_max` it reads and
/// drops, so that the command never blocks on a full pipe.
pub fn readRun(s: *Server, r: *Run) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = lib_posix.read(r.out_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => 0,
        };
        if (n == 0) {
            lib_posix.close(r.out_fd);
            r.out_fd = -1;
            // `timers` answers it: the poll loop still walks `runs`.
            return;
        }
        const room = m.run_output_max - r.output.items.len;
        if (n > room) r.truncated = true;
        r.output.appendSlice(s.gpa, buf[0..@min(n, room)]) catch {
            r.truncated = true;
        };
    }
}

pub fn reapRuns(s: *Server) void {
    for (s.runs.items) |r| {
        if (r.status != null) continue;
        const res = lib_posix.waitpid(r.pid, std.c.W.NOHANG);
        if (res.pid == r.pid) r.status = session.ExitStatus.fromWait(res.status);
    }
}

/// Answers and frees each command that ended. Only `timers` calls it,
/// after the poll loop walked `runs`.
pub fn finishRuns(s: *Server) void {
    var i: usize = 0;
    while (i < s.runs.items.len) {
        const r = s.runs.items[i];
        if (!r.done()) {
            i += 1;
            continue;
        }
        _ = s.runs.orderedRemove(i);
        if (r.timed_out) {
            peers.replyError(s, r.peer, r.re, .timeout, "The command did not end in time.");
        } else {
            const st = r.status.?;
            peers.reply(s, r.peer, r.re, m.CommandRun, .{
                .output = .{ .bytes = r.output.items },
                .truncated = r.truncated,
                .code = st.code,
                .signal = st.signal,
            });
        }
        r.output.deinit(s.gpa);
        s.gpa.destroy(r);
    }
}
