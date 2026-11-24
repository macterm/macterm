//! `macterm server` (design/001, design/002, design/003 §4, design/006 §1).
//!
//! One for each user and machine. It holds the registry of sessions and
//! serves channel 0 to the GUI and the CLI: `session.create`, `list`,
//! `info`, `kill`, `server.exit`, `ping`, `command.run` (a command run to
//! its end, for the app's background reads of a host, 0058), and the
//! `session.exit` event. It holds no pty. The app reaches each pane through
//! a channel of its one connection to the server, on the Mac and on a host
//! (`channel.open`, `close`, `pause`, `resume`; `relay.zig`).
//!
//! It stores nothing. Each session process holds its state and its exit
//! status, and keeps the status until a client reads it (`statusRead`) or
//! sends `session.kill`. So a
//! new server, after a crash or an update, reads every session again from
//! its socket and loses nothing.
//!
//! This file has the start, the loop and the exit. `registry.zig` has the
//! sessions, `peers.zig` the clients and their channels, `runs.zig`
//! `command.run`, and `conn.zig` the connection and the poll list that they
//! all use.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const socket = @import("socket.zig");
const runtime = @import("runtime.zig");
const session = @import("session.zig");
const relay = @import("relay.zig");
const conn = @import("conn.zig");
const link_host = @import("link/host.zig");
const protocol = @import("protocol/protocol.zig");
const frame = protocol.frame;
const m = protocol.messages;
const registry = @import("registry.zig");
const runs = @import("runs.zig");
const peers = @import("peers.zig");
const model_ipc = @import("model_ipc.zig");

const Peer = peers.Peer;
const Entry = registry.Entry;
const Spawn = registry.Spawn;
const Waiter = registry.Waiter;
const Batch = peers.Batch;
const Channel = peers.Channel;
const Run = runs.Run;

/// The server's socket in the runtime directory. A session name cannot start
/// with a dot, so no session can take it.
pub const socket_name = ".server";

/// With no session and no client for this long, the server exits. The app or
/// the CLI starts it again when its socket does not answer (design/001, A).
pub const idle_exit_ms = 5000;

/// A session process that does not end this long after `session.kill` gets
/// SIGKILL. The session itself gives its shell 0.5 s after SIGHUP.
pub const kill_grace_ms = 3000;

/// A session process that does not answer this long after it started gets
/// SIGKILL, and the create fails.
pub const spawn_ms = 10_000;

/// A session that does not send its state this long after the connect is
/// left out of the lists that wait for it. It is listed when it answers.
pub const settle_ms = 2000;

/// The longest frame body that a client or a session may send.
pub const frame_max = 1024 * 1024;

/// The `server` command. Starts the server and returns once its socket
/// accepts connections. `error.AlreadyRunning` when a server answers.
///
/// The forked server binds and listens itself, so that a peer's credentials
/// (`SO_PEERCRED`, `LOCAL_PEERPID`) name the server and not this caller. It
/// reports the result on a pipe.
pub fn start(gpa: std.mem.Allocator, dir: []const u8) !void {
    runtime.ensureDir(dir) catch return error.RuntimeDir;
    const path = try socket.getSocketPath(gpa, dir, socket_name);
    defer gpa.free(path);

    const pipe = try lib_posix.pipe2(.{ .CLOEXEC = true });
    const pid = lib_posix.fork() catch |err| {
        lib_posix.close(pipe[0]);
        lib_posix.close(pipe[1]);
        return err;
    };
    if (pid > 0) {
        lib_posix.close(pipe[1]);
        defer lib_posix.close(pipe[0]);
        var result: [1]u8 = .{@backingInt(Started.failed)};
        _ = lib_posix.read(pipe[0], &result) catch 0;
        return switch (@as(Started, @fromBackingInt(@intCast(result[0])))) {
            .listening => {},
            .already_running => error.AlreadyRunning,
            .failed => error.StartFailed,
        };
    }
    lib_posix.close(pipe[0]);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bound = if (selfExe(&exe_buf)) |_| bindOnce(dir, path) else |err| err;
    const fds = bound catch |err| {
        const result: Started = if (err == error.AlreadyRunning) .already_running else .failed;
        if (result == .failed) std.log.err("server: cannot start on {s}: {s}", .{ path, @errorName(err) });
        _ = lib_posix.write(pipe[1], &.{@backingInt(result)}) catch {};
        std.c._exit(0);
    };
    _ = lib_posix.write(pipe[1], &.{@backingInt(Started.listening)}) catch {};
    // The server: no terminal, no stdio, and no fd of the caller.
    _ = lib_posix.setsid() catch {};
    detachStdio();
    var fd: i32 = 3;
    while (fd < 256) : (fd += 1) {
        if (fd != fds.listen and fd != fds.lock) _ = std.c.close(fd);
    }
    serveAndExit(dir, fds);
}

const Started = enum(u8) { listening, already_running, failed };

/// The file that a server holds locked for its whole life. Only the holder
/// binds or unlinks the socket, so a start never takes the socket of a live
/// server, also when that server's backlog is full and a connect is refused.
pub const lock_name = ".server.lock";

const Bound = struct { listen: i32, lock: i32 };

fn bindOnce(dir: []const u8, path: []const u8) !Bound {
    const lock_fd = try takeServerLock(dir, path);
    errdefer lib_posix.close(lock_fd);
    // No server runs: a socket here is a crashed server's.
    session.unlinkSocket(dir, socket_name);
    return .{ .listen = try session.bindSocket(path), .lock = lock_fd };
}

/// `error.AlreadyRunning` when a server holds the lock. A server that exits
/// unlinks its socket and then lets the lock go, so while the socket does
/// not answer, the start waits up to 1 s for the lock.
fn takeServerLock(dir: []const u8, path: []const u8) !i32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, lock_name }, 0);
    const fd = std.c.open(lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.LockFailed;
    errdefer lib_posix.close(fd);
    var tries: u32 = 0;
    while (std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB) != 0) : (tries += 1) {
        if (std.c._errno().* != @backingInt(std.c.E.AGAIN)) return error.LockFailed;
        if (tries >= 100) return error.AlreadyRunning;
        if (socket.connectSession(path)) |fd_live| {
            lib_posix.close(fd_live);
            return error.AlreadyRunning;
        } else |_| {}
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return fd;
}

fn detachStdio() void {
    const devnull = lib_posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    inline for (.{ lib_posix.STDIN_FILENO, lib_posix.STDOUT_FILENO, lib_posix.STDERR_FILENO }) |n|
        lib_posix.dup2(devnull, n) catch {};
    if (devnull > 2) lib_posix.close(devnull);
}

fn serveAndExit(dir: []const u8, fds: Bound) noreturn {
    // After a fork: no allocator or io of the parent.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const gpa = std.heap.c_allocator;
    session.openLog(io, dir, socket_name);
    var server = Server.init(gpa, io, dir, fds) catch |err| {
        std.log.err("server: start failed: {s}", .{@errorName(err)});
        session.unlinkSocket(dir, socket_name);
        std.process.exit(1);
    };
    // After `init` read the path of this binary, which can be relative.
    // The server lock is held: the unlink at a failed `init` above is safe.
    // Not the folder of the process that started the server: a session with
    // no folder starts in the home folder, and no volume stays busy.
    const home = lib_posix.getenv("HOME") orelse "/";
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&home_buf, "{s}", .{home}, 0)) |h| {
        if (std.c.chdir(h.ptr) != 0) _ = std.c.chdir("/");
    } else |_| _ = std.c.chdir("/");
    server.run() catch |err| std.log.err("server: loop failed: {s}", .{@errorName(err)});
    server.shutdown();
    std.log.info("server ended", .{});
    std.process.exit(0);
}

/// What each fd of the server's loop is.
const Source = union(enum) {
    signal,
    listen,
    peer: *Peer,
    entry: *Entry,
    channel: struct { peer: *Peer, ch: *Channel },
    run: *Run,
    spawn: *Spawn,
    /// The fds of `Server.links`, which `link_host.Host.handle` reads.
    link,
};

const Reactor = conn.Reactor(Source);

pub const Server = struct {
    gpa: std.mem.Allocator,
    /// For the frame that a handler decodes. Reset after each frame.
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    dir: []const u8,
    listen_fd: i32,
    /// The server lock (`lock_name`), held until the socket is unlinked.
    lock_fd: i32,
    epoch: u64,
    /// Counts event batches in this epoch.
    seq: u64 = 0,
    /// The last `batch_ring` batches, encoded, oldest first: what a client
    /// that lost its link gets again (`control.resume`, design/003 §7).
    batches: std.ArrayList(Batch) = .empty,
    next_peer: u64 = 1,
    peers: std.ArrayList(*Peer) = .empty,
    entries: std.ArrayList(*Entry) = .empty,
    spawns: std.ArrayList(*Spawn) = .empty,
    /// The session processes that the server started and has not reaped.
    /// They are its children until it exits.
    children: std.ArrayList(lib_posix.pid_t) = .empty,
    runs: std.ArrayList(*Run) = .empty,
    /// `session.list` requests that wait until every session settled.
    list_waiters: std.ArrayList(Waiter) = .empty,
    exe_buf: [std.fs.max_path_bytes]u8 = undefined,
    exe: [:0]const u8 = "",
    /// The client that sent `server.exit`.
    exit_peer: ?u64 = null,
    exiting: bool = false,
    idle_since: ?i64 = null,
    /// A session ended or the server started: look for server files that
    /// no session runs, once every session settled (`pruneBuilds`).
    prune_due: bool = true,
    /// The tag of the last `wait` sent to a session (`registry.startWait`).
    wait_tag: u64 = 0,
    /// The roaming links (`link.open`, design/009).
    links: link_host.Host,
    /// Socket pair ends of new links. Each becomes a client at the end of the
    /// loop pass, because a request cannot add to `peers` while the loop
    /// walks it.
    pending_peers: std.ArrayList(i32) = .empty,
    /// The model, when the app gave a state folder (`model_ipc.zig`).
    model: model_ipc.State = .{},

    pub fn init(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, fds: Bound) !Server {
        var epoch: u64 = undefined;
        io.random(std.mem.asBytes(&epoch));
        var s: Server = .{ .gpa = gpa, .io = io, .dir = dir, .listen_fd = fds.listen, .lock_fd = fds.lock, .epoch = epoch, .arena = .init(gpa), .links = link_host.Host.init(gpa) };
        _ = try selfExe(&s.exe_buf);
        return s;
    }

    pub fn now(s: *const Server) i64 {
        return std.Io.Timestamp.now(s.io, .awake).toMilliseconds();
    }

    pub fn hello(s: *const Server) m.Hello {
        return .{
            .level = m.level,
            .min_level = m.min_level,
            .build = build_options.version,
            .build_key = build_options.key,
            .role = .server,
            .epoch = s.epoch,
            .caps = &.{"udp-link"},
        };
    }

    pub fn run(s: *Server) !void {
        // `init` copied the struct: the slice must point into this copy.
        const exe_len = std.mem.findScalar(u8, &s.exe_buf, 0) orelse return error.ExecutablePathUnknown;
        s.exe = s.exe_buf[0..exe_len :0];
        try signal.openSignalPipe();
        signal.installWakeHandler(@backingInt(lib_posix.SIG.TERM));
        signal.installWakeHandler(@backingInt(lib_posix.SIG.CHLD));
        std.log.info("server started pid={d} epoch={x}", .{ std.c.getpid(), s.epoch });
        registry.discover(s);
        model_ipc.load(s);

        var reactor: Reactor = .{};
        defer reactor.deinit(s.gpa);
        while (!s.exiting) {
            if (s.idleExpired()) return;
            reactor.clear();
            try reactor.add(s.gpa, signal.sig_pipe[0], lib_posix.POLL.IN, .signal);
            try reactor.add(s.gpa, s.listen_fd, lib_posix.POLL.IN, .listen);
            for (s.peers.items) |p| try reactor.add(s.gpa, p.conn.fd, p.conn.events(p.pending() > 0), .{ .peer = p });
            for (s.entries.items) |e| try reactor.add(s.gpa, e.conn.fd, e.conn.events(false), .{ .entry = e });
            for (s.peers.items) |p| for (p.channels.items) |ch| if (ch.conn.fd >= 0) {
                // A closed channel reads nothing more: it only sends its input.
                const events: i16 = if (!ch.closed) ch.conn.events(false) else if (!ch.conn.out.empty()) lib_posix.POLL.OUT else 0;
                try reactor.add(s.gpa, ch.conn.fd, events, .{ .channel = .{ .peer = p, .ch = ch } });
            };
            for (s.runs.items) |r| try reactor.add(s.gpa, r.out_fd, lib_posix.POLL.IN, .{ .run = r });
            for (s.spawns.items) |sp| try reactor.add(s.gpa, sp.fd, sp.events(), .{ .spawn = sp });
            const link_start = reactor.fds.items.len;
            try s.links.pollFds(&reactor.fds, s.gpa);
            try reactor.tag(s.gpa, .link);

            try reactor.poll(s.pollTimeout());

            for (reactor.fds.items, reactor.sources.items) |pfd, source| switch (source) {
                .signal => if (pfd.revents & lib_posix.POLL.IN != 0) {
                    signal.drainSignalPipe() catch {
                        std.log.info("server: SIGTERM", .{});
                        return;
                    };
                    registry.reapChildren(s);
                    runs.reapRuns(s);
                },
                .listen => if (pfd.revents & lib_posix.POLL.IN != 0) peers.accept(s),
                .peer => |p| {
                    if (p.conn.dead) continue;
                    if (pfd.revents & lib_posix.POLL.IN != 0) peers.readPeer(s, p);
                    if (!p.conn.dead and pfd.revents & lib_posix.POLL.OUT != 0) peers.writePeer(s, p);
                    if (!p.conn.dead and conn.hungUp(pfd.revents)) p.conn.dead = true;
                },
                .entry => |e| {
                    if (e.conn.dead or e.conn.fd < 0) continue;
                    if (pfd.revents & lib_posix.POLL.IN != 0) registry.readEntry(s, e);
                    // A refusal closes the connection in `readEntry`.
                    if (e.conn.fd < 0) continue;
                    if (!e.conn.dead and pfd.revents & lib_posix.POLL.OUT != 0) registry.writeEntry(s, e);
                    if (!e.conn.dead and conn.hungUp(pfd.revents)) registry.entryGone(s, e);
                },
                .channel => |c| {
                    if (c.peer.conn.dead or c.ch.conn.fd < 0) continue;
                    if (!c.ch.closed and pfd.revents & lib_posix.POLL.IN != 0) peers.readChannel(s, c.peer, c.ch);
                    if (c.ch.conn.fd < 0 or c.peer.conn.dead) continue;
                    if (pfd.revents & lib_posix.POLL.OUT != 0) peers.writeChannel(s, c.peer, c.ch);
                    if (c.ch.conn.fd >= 0 and conn.hungUp(pfd.revents)) peers.channelEnded(s, c.peer, c.ch);
                },
                .run => |r| if (r.out_fd >= 0 and pfd.revents != 0) runs.readRun(s, r),
                .spawn => |sp| {
                    if (!sp.done and pfd.revents & lib_posix.POLL.OUT != 0) registry.writeSpawn(s, sp);
                    if (!sp.done and pfd.revents & ~@as(i16, lib_posix.POLL.OUT) != 0) registry.readSpawn(s, sp);
                },
                .link => {},
            };
            registry.finishSpawns(s);
            s.links.handle(reactor.fds.items[link_start..], s.now());
            for (s.pending_peers.items) |fd| peers.addPeer(s, fd);
            s.pending_peers.clearRetainingCapacity();
            s.timers();
            s.sweep();
            if (s.prune_due and registry.allSettled(s)) {
                s.prune_due = false;
                registry.pruneBuilds(s);
            }
        }
        // `server.exit`: the reply goes out before the server closes, for at
        // most 1 s. Other clients' queues are dropped.
        if (peers.findPeer(s, s.exit_peer orelse return)) |p| s.flushFor(p, 1000);
    }

    pub fn flushFor(s: *Server, p: *Peer, ms: i64) void {
        const deadline = s.now() + ms;
        while (p.conn.out.bytes + p.control.bytes > 0 and !p.conn.dead) {
            const left = deadline - s.now();
            if (left <= 0) return;
            var pfd = [_]lib_posix.pollfd{.{ .fd = p.conn.fd, .events = lib_posix.POLL.OUT, .revents = 0 }};
            _ = lib_posix.poll(&pfd, @intCast(left)) catch return;
            peers.writePeer(s, p);
        }
    }

    /// The time until the next deadline, or -1 for none.
    pub fn pollTimeout(s: *const Server) i32 {
        const t = s.now();
        var next: ?i64 = s.model.deadline();
        if (s.idle_since) |since| next = @min(next orelse since + idle_exit_ms, since + idle_exit_ms);
        for (s.spawns.items) |sp| {
            const d = sp.started_at + spawn_ms;
            next = @min(next orelse d, d);
        }
        for (s.runs.items) |r| if (!r.timed_out) {
            next = @min(next orelse r.deadline, r.deadline);
        };
        for (s.peers.items) |p| if (!p.conn.greeted) {
            const d = p.connected_at + peers.hello_ms;
            next = @min(next orelse d, d);
        };
        for (s.entries.items) |e| {
            if (e.kill_deadline) |d| next = @min(next orelse d, d);
            if (registry.waitDeadline(e)) |d| next = @min(next orelse d, d);
            if (!e.settled(t)) {
                const d = e.connected_at + settle_ms;
                next = @min(next orelse d, d);
            }
        }
        for (s.peers.items) |p| for (p.channels.items) |ch| if (ch.conn.fd >= 0 and !ch.closed) {
            if (ch.flow.deadline(ch.q.stale())) |d| next = @min(next orelse d, d);
        };
        const d = next orelse return s.links.timeout(t);
        const own: i32 = @intCast(std.math.clamp(d - t, 0, std.math.maxInt(i32)));
        const link = s.links.timeout(t);
        return if (link >= 0) @min(own, link) else own;
    }

    /// True when the server has had no session, no client and no start in
    /// flight for `idle_exit_ms`, and no client waits in the backlog.
    pub fn idleExpired(s: *Server) bool {
        // A refused session has no connection: see if it still runs.
        if (s.peers.items.len == 0 and s.spawns.items.len == 0) registry.checkRefused(s);
        const idle = s.peers.items.len == 0 and s.entries.items.len == 0 and s.spawns.items.len == 0 and s.runs.items.len == 0;
        if (!idle) {
            s.idle_since = null;
            return false;
        }
        const t = s.now();
        const since = s.idle_since orelse {
            s.idle_since = t;
            return false;
        };
        if (t - since < idle_exit_ms) return false;
        // A client in the backlog is accepted, and the server stays. One that
        // connects after the close gets EOF before `hello`: it starts a
        // server and connects again.
        peers.accept(s);
        if (s.peers.items.len > 0) {
            s.idle_since = null;
            return false;
        }
        std.log.info("server: no session and no client, exiting", .{});
        s.closeListen();
        return true;
    }

    /// Closes the socket, unlinks it, then lets the server lock go. Only the
    /// holder of the lock unlinks, so the socket that goes is this server's.
    /// A start after this finds no server and starts one.
    pub fn closeListen(s: *Server) void {
        if (s.listen_fd < 0) return;
        lib_posix.close(s.listen_fd);
        s.listen_fd = -1;
        session.unlinkSocket(s.dir, socket_name);
        lib_posix.close(s.lock_fd);
        s.lock_fd = -1;
    }

    /// Closes everything. Sessions see a client leave and keep running. The
    /// model goes to disk first: at `server.exit`, at SIGTERM, and when the
    /// server is idle (design/010 §2).
    pub fn shutdown(s: *Server) void {
        model_ipc.flush(s);
        s.links.deinit();
        s.closeListen();
        for (s.peers.items) |p| {
            p.conn.close();
            for (p.channels.items) |ch| ch.conn.close();
        }
        for (s.entries.items) |e| e.conn.close();
        for (s.runs.items) |r| lib_posix.kill(-r.pid, lib_posix.SIG.KILL) catch {};
    }

    pub fn timers(s: *Server) void {
        const t = s.now();
        for (s.entries.items) |e| {
            if (e.conn.dead) continue;
            if (e.kill_deadline) |d| if (t >= d) {
                std.log.warn("server: session {s} did not end, SIGKILL", .{e.id});
                // The pid is the first that the session reported (`validPid`).
                // The pty closes with it, and the kernel hangs up the shell.
                if (e.state) |st| lib_posix.kill(@intCast(st.pid), lib_posix.SIG.KILL) catch {};
                e.kill_deadline = null;
            };
            registry.expireWaits(s, e, t);
            if (!e.settled(t)) continue;
            // A session that never answered: an info that waits for it gets
            // nothing true to show.
            if (e.state == null and !e.refused and e.waiters.items.len > 0) {
                const waiters = e.waiters.toOwnedSlice(s.gpa) catch continue;
                defer s.gpa.free(waiters);
                for (waiters) |w| switch (w.kind) {
                    .create => peers.replyError(s, w.peer, w.re, .start_failed, "The session does not answer."),
                    .info, .list, .seen, .history, .inspect, .subscribe, .wait => peers.replyError(s, w.peer, w.re, .not_found, "The session does not answer."),
                    .typing => {
                        if (w.input) |i| i.deinit(s.gpa);
                        peers.replyError(s, w.peer, w.re, .not_found, "The session does not answer.");
                    },
                    .kill => registry.wait(s, &e.waiters, w),
                };
            }
        }
        for (s.peers.items) |p| for (p.channels.items) |ch| {
            if (ch.conn.fd < 0 or ch.closed) continue;
            if (ch.flow.mustSkip(ch.q.stale(), t)) peers.skip(s, ch, t) else if (ch.flow.mustAskAgain(t)) peers.askSnapshot(s, ch, t);
        };
        for (s.peers.items) |p| if (!p.conn.greeted and !p.conn.dead and t - p.connected_at >= peers.hello_ms) {
            std.log.info("server: a client sent no hello, closed", .{});
            p.conn.dead = true;
        };
        for (s.spawns.items) |sp| if (t >= sp.started_at + spawn_ms and sp.started_at >= 0) {
            std.log.warn("server: session {s} start takes too long, SIGKILL", .{sp.id});
            // Not a pid that was reaped: the system can give it to another process.
            if (std.mem.findScalar(lib_posix.pid_t, s.children.items, sp.pid) != null)
                lib_posix.kill(sp.pid, lib_posix.SIG.KILL) catch {};
            // Once: its end of the socket pair closes, and the create fails.
            sp.started_at = -1;
        };
        for (s.runs.items) |r| if (!r.timed_out and t >= r.deadline) {
            std.log.warn("server: a command ran too long, SIGKILL", .{});
            r.timed_out = true;
            // The process group: a child of the command can hold stdout too.
            lib_posix.kill(-r.pid, lib_posix.SIG.KILL) catch {};
            if (r.out_fd >= 0) lib_posix.close(r.out_fd);
            r.out_fd = -1;
        };
        runs.finishRuns(s);
        registry.answerLists(s);
        model_ipc.timers(s);
    }

    pub fn sweep(s: *Server) void {
        defer s.links.reap();
        var i: usize = 0;
        while (i < s.peers.items.len) {
            const p = s.peers.items[i];
            if (p.conn.dead) {
                registry.cancelWaits(s, p.id);
                // Nobody waits for its commands: they end now, and free
                // their places (`max_runs`).
                for (s.runs.items) |r| if (r.peer == p.id and !r.timed_out) {
                    r.timed_out = true;
                    lib_posix.kill(-r.pid, lib_posix.SIG.KILL) catch {};
                    if (r.out_fd >= 0) lib_posix.close(r.out_fd);
                    r.out_fd = -1;
                };
                p.conn.deinit(s.gpa);
                p.control.deinit(s.gpa);
                for (p.channels.items) |ch| ch.deinit(s.gpa);
                p.channels.deinit(s.gpa);
                s.gpa.destroy(p);
                _ = s.peers.orderedRemove(i);
            } else {
                // A channel that the client closed goes when its input went
                // to the session. A channel whose session left goes when its
                // last frames went to the client.
                var j: usize = 0;
                while (j < p.channels.items.len) {
                    const ch = p.channels.items[j];
                    if (if (ch.closed) ch.conn.fd < 0 or ch.conn.out.bytes == 0 else ch.conn.fd < 0 and ch.q.empty()) {
                        ch.deinit(s.gpa);
                        _ = p.channels.orderedRemove(j);
                        if (p.turn > j) p.turn -= 1;
                    } else j += 1;
                }
                if (p.channels.items.len > 0) p.turn %= p.channels.items.len else p.turn = 0;
                i += 1;
            }
        }
        i = 0;
        while (i < s.entries.items.len) {
            const e = s.entries.items[i];
            if (e.conn.dead) {
                // A create that waits for this session to go starts now.
                registry.startReplacements(s, e);
                e.replacing.deinit(s.gpa);
                e.conn.deinit(s.gpa);
                for (e.waiters.items) |w| if (w.input) |input| input.deinit(s.gpa);
                e.waiters.deinit(s.gpa);
                s.gpa.free(e.build);
                if (e.build_key) |k| s.gpa.free(k);
                s.gpa.free(e.id);
                s.gpa.destroy(e);
                _ = s.entries.orderedRemove(i);
            } else i += 1;
        }
    }
};

/// The absolute path of this binary, to start sessions with.
fn selfExe(buf: *[std.fs.max_path_bytes]u8) ![:0]const u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        // It can be relative to the folder at start.
        var raw: [std.fs.max_path_bytes]u8 = undefined;
        var len: u32 = raw.len;
        if (std.c._NSGetExecutablePath(&raw, &len) != 0) return error.ExecutablePathTooLong;
        if (std.c.realpath(@ptrCast(&raw), buf) == null) return error.ExecutablePathUnknown;
        const n = std.mem.findScalar(u8, buf, 0) orelse return error.ExecutablePathTooLong;
        return buf[0..n :0];
    }
    const n = std.c.readlink("/proc/self/exe", buf, buf.len - 1);
    if (n <= 0) return error.ExecutablePathUnknown;
    buf[@intCast(n)] = 0;
    return buf[0..@intCast(n) :0];
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the server's socket name is no session name" {
    try testing.expect(!session.validName(socket_name));
    try testing.expect(!session.validName(lock_name));
}
