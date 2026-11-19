//! The server's registry of sessions: its connection to each session
//! process, the start of a new one (`session.create`), `session.kill`, the
//! lists, and the removal of server files that no session runs.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cross = @import("cross");
const lib_posix = @import("posix.zig");
const signal = @import("signal.zig");
const socket = @import("socket.zig");
const runtime = @import("runtime.zig");
const session = @import("session.zig");
const conn = @import("conn.zig");
const FrameConn = conn.FrameConn;
const protocol = @import("protocol/protocol.zig");
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const m = protocol.messages;
const server = @import("server.zig");
const runs = @import("runs.zig");
const model_ipc = @import("model_ipc.zig");
const peers = @import("peers.zig");
const chord = @import("chord.zig");
const Server = server.Server;

const Peer = peers.Peer;
const settle_ms = server.settle_ms;
const kill_grace_ms = server.kill_grace_ms;
const frame_max = server.frame_max;

/// A server file of another build younger than this stays (`pruneBuilds`).
const fresh_build_ms = 60_000;

/// A request that waits for a session: a create, a kill, or an info or a list
/// before the state came.
pub const Waiter = struct {
    peer: u64,
    re: u64,
    kind: enum { create, info, kill, list, seen, history, inspect, subscribe },
};

/// The server's connection to one session process.
pub const Entry = struct {
    id: []u8,
    /// The connection to the session process. It is `greeted` when both
    /// hellos are in and the levels meet, closed after a refusal (the
    /// session and the server have no common level), and `dead` when the
    /// session process ended.
    conn: FrameConn,
    connected_at: i64,
    build: []u8 = &.{},
    /// The session's build key, from its `hello`. Null when it sent none, or
    /// one that is not a key.
    build_key: ?[]u8 = null,
    level: u32 = 0,
    refused: bool = false,
    state: ?State = null,
    /// The session's attention flags, from its last `attention` message.
    attention: m.Attention = .{},
    exit: ?session.ExitStatus = null,
    /// The `session.exit` event went out.
    announced: bool = false,
    /// The server sent `take`.
    taken: bool = false,
    /// A client sent `session.kill`: the server takes the exit status.
    killing: bool = false,
    /// When SIGKILL goes, if the session has not ended.
    kill_deadline: ?i64 = null,
    waiters: std.ArrayList(Waiter) = .empty,

    const State = struct {
        pid: i64,
        shell_pid: i64,
        pty_buf: [128]u8 = @splat(0),
        pty_len: usize = 0,
        cols: u16,
        rows: u16,
        clients: ?u16 = null,
    };

    /// Its state or its refusal is in, or it was silent too long.
    pub fn settled(e: *const Entry, now: i64) bool {
        return e.state != null or e.refused or now - e.connected_at >= settle_ms;
    }

    /// The server can say something true about it.
    pub fn listed(e: *const Entry) bool {
        return !e.conn.dead and (e.state != null or e.refused);
    }

    pub fn info(e: *const Entry) m.Session {
        var out: m.Session = .{
            .id = e.id,
            .state = if (e.refused) .refused else if (e.exit != null) .exited else .running,
            .build = e.build,
            .level = e.level,
            .build_key = e.build_key,
        };
        if (e.state) |*st| {
            out.pid = st.pid;
            out.shell_pid = st.shell_pid;
            out.pty = .{ .bytes = st.pty_buf[0..st.pty_len] };
            out.cols = st.cols;
            out.rows = st.rows;
            out.clients = st.clients;
        }
        out.unseen = e.attention.unseen;
        out.failed = e.attention.failed;
        out.bell = e.attention.bell;
        if (e.exit) |x| {
            out.code = x.code;
            out.signal = x.signal;
        }
        return out;
    }
};

/// A session process that has not answered yet (`registry.spawn`).
pub const Spawn = struct {
    pid: lib_posix.pid_t,
    id: []u8,
    /// The server's end of the socket pair: the spec goes out on it, and the
    /// session's answer comes back on it.
    fd: i32,
    /// The encoded spec, and how much of it went out.
    spec: []u8,
    sent: usize = 0,
    answer: std.ArrayList(u8) = .empty,
    /// The session closed its end: `finishSpawns` answers the waiters.
    done: bool = false,
    started_at: i64,
    waiters: std.ArrayList(Waiter) = .empty,

    pub fn events(sp: *const Spawn) i16 {
        var ev: i16 = lib_posix.POLL.IN;
        if (sp.sent < sp.spec.len) ev |= lib_posix.POLL.OUT;
        return ev;
    }
};

/// Connects to every session socket in the directory. A socket that
/// refuses the connection is left as it is: a session that starts with
/// that name removes it.
pub fn discover(s: *Server) void {
    var dir = std.Io.Dir.openDirAbsolute(s.io, s.dir, .{ .iterate = true }) catch return;
    defer dir.close(s.io);
    var it = dir.iterate();
    while (it.next(s.io) catch null) |entry| {
        if (entry.kind != .unix_domain_socket or !session.validName(entry.name)) continue;
        connectEntry(s, entry.name) catch |err|
            std.log.info("server: session {s} does not answer: {s}", .{ entry.name, @errorName(err) });
    }
}

pub fn connectEntry(s: *Server, id: []const u8) !void {
    const path = try socket.getSocketPath(s.gpa, s.dir, id);
    defer s.gpa.free(path);
    const fd = try connectNonblocking(path);
    errdefer lib_posix.close(fd);
    const e = try s.gpa.create(Entry);
    errdefer s.gpa.destroy(e);
    e.* = .{ .id = try s.gpa.dupe(u8, id), .conn = .{ .fd = fd, .max_frame = frame_max }, .connected_at = s.now() };
    errdefer s.gpa.free(e.id);
    try s.entries.append(s.gpa, e);
    sendEntryControl(s, e, s.hello());
}

pub fn findEntry(s: *Server, id: []const u8) ?*Entry {
    for (s.entries.items) |e| if (!e.conn.dead and std.mem.eql(u8, e.id, id)) return e;
    return null;
}

pub fn readEntry(s: *Server, e: *Entry) void {
    const end = e.conn.read(s.gpa, &s.arena, .{ s, e }, handleEntryFrame) orelse return;
    switch (end) {
        .closed, .no_memory => entryGone(s, e),
        .too_large => brokenEntry(s, e, "a frame over 1 MiB"),
        .bad_frame => brokenEntry(s, e, "a bad frame"),
    }
}

pub fn handleEntryFrame(s: *Server, e: *Entry, f: frame.Frame, arena: std.mem.Allocator) void {
    if (f.channel == frame.control_channel) {
        const msg = m.decodeControl(arena, f.body) catch return brokenEntry(s, e, "a bad message");
        switch (msg) {
            .hello => |h| {
                if (e.conn.greeted or e.refused) return;
                e.build = s.gpa.dupe(u8, buildName(h.build)) catch return entryGone(s, e);
                if (keyOf(h.build_key)) |k| e.build_key = s.gpa.dupe(u8, k) catch return entryGone(s, e);
                e.level = h.level;
                switch (m.negotiate(s.hello(), h)) {
                    .speak => e.conn.greeted = true,
                    .refuse => |r| {
                        std.log.info("server: session {s} speaks level {d}, refused", .{ e.id, h.level });
                        // One try: a session that already left needs no refusal.
                        sendEntryControl(s, e, r);
                        e.conn.flush(s.gpa) catch {};
                        refuseEntry(s, e);
                    },
                }
            },
            .refuse => |r| {
                std.log.info("server: session {s} refused the server: {s}", .{ e.id, r.reason });
                refuseEntry(s, e);
            },
            else => {},
        }
        return;
    }
    if (!e.conn.greeted or f.channel != m.pane_channel or f.kind != .msg) return;
    const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return brokenEntry(s, e, "a bad message");
    if (std.mem.eql(u8, msg.t, m.State.name)) {
        const st = m.decodePane(m.State, arena, msg) catch return brokenEntry(s, e, "a bad state");
        // The server may SIGKILL this pid. 0, 1 and -1 would reach a
        // process group or every process of the user, and a session's pid
        // never changes: fail closed.
        if (!validPid(st.pid) or !validPid(st.shell_pid))
            return brokenEntry(s, e, "a pid that the server cannot signal");
        if (e.state) |old| if (old.pid != st.pid or old.shell_pid != st.shell_pid)
            return brokenEntry(s, e, "a pid other than its first");
        const first = e.state == null;
        var state: Entry.State = .{ .pid = st.pid, .shell_pid = st.shell_pid, .cols = st.cols, .rows = st.rows, .clients = st.clients };
        state.pty_len = @min(st.pty.bytes.len, state.pty_buf.len);
        @memcpy(state.pty_buf[0..state.pty_len], st.pty.bytes[0..state.pty_len]);
        e.state = state;
        if (first) settle(s, e);
    } else if (std.mem.eql(u8, msg.t, m.Attention.name)) {
        const a = m.decodePane(m.Attention, arena, msg) catch return brokenEntry(s, e, "a bad attention");
        const changed = !std.meta.eql(e.attention, a);
        e.attention = a;
        if (changed) peers.emit(s, m.PaneAttention, .{ .id = e.id, .unseen = a.unseen, .failed = a.failed, .bell = a.bell });
        // Only `Watch.seen` sends all flags clear after a change, so this
        // is the answer to `Seen`: the event is out, and the requests
        // that wait for it get their replies. A flag that was already on
        // its way does not answer them.
        if (a.unseen or a.failed or a.bell) return;
        var i: usize = 0;
        while (i < e.waiters.items.len) {
            const w = e.waiters.items[i];
            if (w.kind != .seen) {
                i += 1;
                continue;
            }
            _ = e.waiters.orderedRemove(i);
            peers.reply(s, w.peer, w.re, m.PaneSeen, .{});
        }
    } else if (std.mem.eql(u8, msg.t, m.History.name)) {
        const h = m.decodePane(m.History, arena, msg) catch return brokenEntry(s, e, "a bad history");
        const w = takeWaiter(e, .history) orelse return;
        peers.reply(s, w.peer, w.re, m.SessionHistory, .{ .text = h.text, .truncated = h.truncated });
    } else if (std.mem.eql(u8, msg.t, m.Inspect.name)) {
        const i = m.decodePane(m.Inspect, arena, msg) catch return brokenEntry(s, e, "a bad inspect");
        const w = takeWaiter(e, .inspect) orelse return;
        peers.reply(s, w.peer, w.re, m.SessionInspect, .{ .terminal = i.terminal });
    } else if (std.mem.eql(u8, msg.t, m.Exit.name)) {
        const x = m.decodePane(m.Exit, arena, msg) catch return brokenEntry(s, e, "a bad exit");
        if (e.exit != null) return;
        e.exit = .{ .code = x.code, .signal = x.signal };
        std.log.info("server: session {s} exited code={?d} signal={?d}", .{ e.id, x.code, x.signal });
        announce(s, e);
        if (e.killing) take(s, e);
    }
    // `lead` and later messages: not the server's.
}

/// The session's state is in: the requests that wait for it get it.
pub fn settle(s: *Server, e: *Entry) void {
    const waiters = e.waiters.toOwnedSlice(s.gpa) catch return;
    defer s.gpa.free(waiters);
    for (waiters) |w| switch (w.kind) {
        .create => peers.reply(s, w.peer, w.re, m.SessionCreate, .{ .session = e.info() }),
        .info => peers.reply(s, w.peer, w.re, m.SessionInfo, .{ .session = e.info() }),
        .kill, .list, .seen, .subscribe => wait(s, &e.waiters, w),
        // A session asked for its text or state answers, unless it was
        // refused: then its connection is closed.
        .history, .inspect => if (e.refused)
            peers.replyError(s, w.peer, w.re, .refused, "The session runs a build that this server cannot speak to.")
        else
            wait(s, &e.waiters, w),
    };
    answerLists(s);
}

/// The first waiter of `kind`, out of the list. The session answers
/// `history_read` and `inspect_read` in order.
fn takeWaiter(e: *Entry, kind: @FieldType(Waiter, "kind")) ?Waiter {
    for (e.waiters.items, 0..) |w, i| if (w.kind == kind) return e.waiters.orderedRemove(i);
    return null;
}

/// A session that breaks the protocol. Its connection closes, and it is
/// listed as `refused`: the server can say nothing true of it. No exit
/// goes out, because nothing says that it ended.
pub fn brokenEntry(s: *Server, e: *Entry, what: []const u8) void {
    std.log.warn("server: session {s} sent {s}, closed", .{ e.id, what });
    refuseEntry(s, e);
}

pub fn refuseEntry(s: *Server, e: *Entry) void {
    e.refused = true;
    e.state = null;
    e.conn.close();
    settle(s, e);
}

pub fn announce(s: *Server, e: *Entry) void {
    if (e.announced) return;
    e.announced = true;
    const x = e.exit orelse session.ExitStatus{};
    peers.emit(s, m.SessionExit, .{ .id = e.id, .code = x.code, .signal = x.signal });
}

pub fn take(s: *Server, e: *Entry) void {
    if (e.taken) return;
    e.taken = true;
    sendEntryPane(s, e, m.Take, .{});
}

/// The session's connection closed: the session process ended.
pub fn entryGone(s: *Server, e: *Entry) void {
    if (e.conn.dead) return;
    e.conn.dead = true;
    s.prune_due = true;
    if (e.state != null) announce(s, e);
    std.log.info("server: session {s} is gone", .{e.id});
    for (e.waiters.items) |w| switch (w.kind) {
        .kill => peers.reply(s, w.peer, w.re, m.SessionKill, .{}),
        .create => peers.replyError(s, w.peer, w.re, .start_failed, "The session ended before it was ready."),
        .info, .list, .seen, .history, .inspect, .subscribe => peers.replyError(s, w.peer, w.re, .not_found, "No session has this id."),
    };
    e.waiters.clearRetainingCapacity();
    answerLists(s);
}

pub fn writeEntry(s: *Server, e: *Entry) void {
    e.conn.flush(s.gpa) catch entryGone(s, e);
}

pub fn sendEntryControl(s: *Server, e: *Entry, value: anytype) void {
    e.conn.sendControl(s.gpa, value) catch entryGone(s, e);
}

pub fn sendEntryPane(s: *Server, e: *Entry, comptime M: type, value: M) void {
    e.conn.sendPane(s.gpa, M, value) catch entryGone(s, e);
}

/// Starts this binary as `__session <id>` with one `posix_spawn`: the
/// leader of a new session (`SETSID`), and on macOS its own responsible
/// process (the disclaim, server/AGENTS.md) that gets only the fds of
/// the file actions (`CLOEXEC_DEFAULT`). On Linux every fd of the server
/// is close-on-exec. The spec, one msgpack `SessionCreate.Args`, goes on
/// a socket pair at `session.spec_fd`; the session answers on it when
/// its socket listens (`session.run`). stdin, stdout and stderr are
/// /dev/null. The size is cut to `session.max_cells`, as a session cuts
/// a resize.
pub fn spawn(s: *Server, id: []const u8, args: m.SessionCreate.Args) !*Spawn {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const id_z = try arena.dupeSentinel(u8, id, 0);
    const argv = [_:null]?[*:0]const u8{ s.exe.ptr, session.command_name, id_z.ptr };
    const envp = try sessionEnv(s, arena, args.env);
    var spec_args = args;
    spec_args.cols = @min(args.cols, session.max_cells);
    spec_args.rows = @min(args.rows, session.max_cells);
    // The environment is the process's own (`envp`).
    spec_args.env = null;
    const spec = try msgpack.encodeAlloc(s.gpa, spec_args);
    errdefer s.gpa.free(spec);

    // No SOCK_CLOEXEC: macOS's socketpair refuses it. The server has one
    // thread, so no other spawn can start before `fcntl` sets the flag.
    var pair: [2]i32 = undefined;
    if (std.c.socketpair(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM, 0, &pair) != 0) return error.SocketPair;
    errdefer lib_posix.close(pair[0]);
    defer lib_posix.close(pair[1]);
    for (pair) |fd| _ = try lib_posix.fcntl(fd, lib_posix.F.SETFD, std.c.FD_CLOEXEC);
    const flags = try lib_posix.fcntl(pair[0], lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(pair[0], lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);

    // Before the spawn: a child that `children` does not hold is never reaped.
    try s.children.ensureUnusedCapacity(s.gpa, 1);
    const pid = try spawnSession(s.exe, &argv, envp, pair[1]);
    s.children.appendAssumeCapacity(pid);
    errdefer lib_posix.kill(pid, lib_posix.SIG.KILL) catch {};

    const sp = try s.gpa.create(Spawn);
    errdefer s.gpa.destroy(sp);
    sp.* = .{ .pid = pid, .id = try s.gpa.dupe(u8, id), .fd = pair[0], .spec = spec, .started_at = s.now() };
    errdefer s.gpa.free(sp.id);
    try s.spawns.append(s.gpa, sp);
    std.log.info("server: starting session {s} pid={d}", .{ id, pid });
    return sp;
}

/// The environment of a new session: the client's entries, or the
/// server's own environment when it sent none. The runtime directory is
/// always the server's, so that the session listens where the server
/// looks.
pub fn sessionEnv(s: *const Server, arena: std.mem.Allocator, env: ?[]const msgpack.Bin) ![*:null]const ?[*:0]const u8 {
    const entries = env orelse return @ptrCast(std.c.environ);
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (entries) |entry| {
        if (std.mem.startsWith(u8, entry.bytes, runtime.dir_env ++ "=")) continue;
        try list.append(arena, (try arena.dupeSentinel(u8, entry.bytes, 0)).ptr);
    }
    try list.append(arena, (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ runtime.dir_env, s.dir }, 0)).ptr);
    try list.append(arena, null);
    return @ptrCast(list.items.ptr);
}

/// Reaps the session processes that exited. The server's only other
/// children are the commands of `command.run` (`reapRuns`).
pub fn reapChildren(s: *Server) void {
    var i: usize = 0;
    while (i < s.children.items.len) {
        const pid = s.children.items[i];
        if (lib_posix.waitpid(pid, std.c.W.NOHANG).pid == pid) {
            _ = s.children.swapRemove(i);
        } else i += 1;
    }
}

/// Sends the rest of the spec. After the last byte, the server shuts its
/// side for writes, so that the session reads EOF.
pub fn writeSpawn(s: *Server, sp: *Spawn) void {
    _ = s;
    const n = lib_posix.write(sp.fd, sp.spec[sp.sent..]) catch |err| switch (err) {
        error.WouldBlock => return,
        // The session is gone: its answer is the EOF.
        else => {
            sp.sent = sp.spec.len;
            return;
        },
    };
    sp.sent += n;
    if (sp.sent == sp.spec.len) _ = std.c.shutdown(sp.fd, std.c.SHUT.WR);
}

/// Reads the answer. EOF ends it: the session answered and closed its
/// end, or it exited.
pub fn readSpawn(s: *Server, sp: *Spawn) void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = lib_posix.read(sp.fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => 0,
        };
        if (n == 0) {
            sp.done = true;
            return;
        }
        // More than any error text: the rest is dropped.
        const room = 1024 -| sp.answer.items.len;
        sp.answer.appendSlice(s.gpa, buf[0..@min(n, room)]) catch {};
    }
}

/// Answers and frees each start that ended. Called after the poll loop
/// walked `spawns`.
pub fn finishSpawns(s: *Server) void {
    var i: usize = 0;
    while (i < s.spawns.items.len) {
        const sp = s.spawns.items[i];
        if (!sp.done) {
            i += 1;
            continue;
        }
        _ = s.spawns.orderedRemove(i);
        spawnDone(s, sp);
        lib_posix.close(sp.fd);
        sp.answer.deinit(s.gpa);
        sp.waiters.deinit(s.gpa);
        s.gpa.free(sp.spec);
        s.gpa.free(sp.id);
        s.gpa.destroy(sp);
    }
}

/// The session answered. With `session.ready_answer`, it listens. Else a
/// session of this id may already run (one that the server did not
/// start): the server uses it, so that the same id finds the same
/// session.
pub fn spawnDone(s: *Server, sp: *Spawn) void {
    const ready = std.mem.eql(u8, sp.answer.items, session.ready_answer);
    if (connectEntry(s, sp.id)) |_| {
        const e = findEntry(s, sp.id).?;
        e.waiters.appendSlice(s.gpa, sp.waiters.items) catch
            for (sp.waiters.items) |w| peers.replyError(s, w.peer, w.re, .start_failed, "The server is out of memory.");
        return;
    } else |err| if (ready)
        std.log.warn("server: session {s} started but does not answer: {s}", .{ sp.id, @errorName(err) });
    const text = if (ready) errorText("") else errorText(sp.answer.items);
    std.log.warn("server: session {s} did not start: {s}", .{ sp.id, text });
    for (sp.waiters.items) |w| peers.replyError(s, w.peer, w.re, .start_failed, text);
}

pub fn create(s: *Server, p: *Peer, re: u64, args: m.SessionCreate.Args) void {
    if (!session.validName(args.id))
        return peers.replyError(s, p.id, re, .invalid_args, "A session id can have only letters, digits, '-', '_' and '.'. It cannot start with '.' or '-'.");
    if (args.cwd) |cwd| if (cwd.bytes.len == 0 or cwd.bytes[0] != '/' or std.mem.findScalar(u8, cwd.bytes, 0) != null)
        return peers.replyError(s, p.id, re, .invalid_args, "The folder must be an absolute path.");
    if (args.command) |command| for (command) |arg| if (std.mem.findScalar(u8, arg.bytes, 0) != null)
        return peers.replyError(s, p.id, re, .invalid_args, "A command argument cannot hold a NUL byte.");
    if (args.env) |env| for (env) |entry| if (std.mem.findScalar(u8, entry.bytes, 0) != null or std.mem.findScalar(u8, entry.bytes, '=') == null)
        return peers.replyError(s, p.id, re, .invalid_args, "An environment entry must be NAME=value with no NUL byte.");
    if (args.cols == 0 or args.rows == 0)
        return peers.replyError(s, p.id, re, .invalid_args, "The size must be at least 1 by 1.");
    const waiter: Waiter = .{ .peer = p.id, .re = re, .kind = .create };
    // The same id again: the session that the first request started.
    if (findEntry(s, args.id)) |e| {
        // A session whose shell exited is not given out as a new one:
        // the client ends it (`session.kill`) and asks again.
        if (e.exit != null) return peers.replyError(s, p.id, re, .exited, "The session's shell exited. End the session first.");
        if (e.listed()) return peers.reply(s, p.id, re, m.SessionCreate, .{ .session = e.info() });
        return wait(s, &e.waiters, waiter);
    }
    for (s.spawns.items) |sp| if (std.mem.eql(u8, sp.id, args.id)) return wait(s, &sp.waiters, waiter);
    const sp = spawn(s, args.id, args) catch |err| {
        std.log.warn("server: cannot start session {s}: {s}", .{ args.id, @errorName(err) });
        return peers.replyError(s, p.id, re, .start_failed, "The server cannot start a process.");
    };
    wait(s, &sp.waiters, waiter);
}

pub fn kill(s: *Server, p: *Peer, re: u64, id: []const u8) void {
    const e = findEntry(s, id) orelse return peers.replyError(s, p.id, re, .not_found, "No session has this id.");
    if (e.refused) return peers.replyError(s, p.id, re, .refused, "The session runs a build that this server cannot speak to.");
    if (e.state == null) return peers.replyError(s, p.id, re, .starting, "The session is not ready.");
    wait(s, &e.waiters, .{ .peer = p.id, .re = re, .kind = .kill });
    endEntry(s, e);
}

/// Ends the session of a pane that left the model (`model_ipc`). Nobody
/// waits for it. A session that the server does not know, or cannot speak
/// to, stays as it is.
pub fn endSession(s: *Server, id: []const u8) void {
    const e = findEntry(s, id) orelse return;
    if (e.refused or e.state == null) return;
    endEntry(s, e);
}

fn endEntry(s: *Server, e: *Entry) void {
    const st = e.state.?;
    if (e.killing) return;
    e.killing = true;
    e.kill_deadline = s.now() + kill_grace_ms;
    if (e.exit != null) {
        take(s, e);
    } else {
        // The session ends its shell itself: SIGHUP to the shell's process
        // group, then SIGKILL (`Session.end`). It alone knows if the shell
        // was reaped, so it never signals a pid that is used again.
        std.log.info("server: kill session {s} pid={d}", .{ e.id, st.pid });
        sendEntryPane(s, e, m.End, .{});
    }
}

/// The session that a request about its terminal names, or null after the
/// error reply. `running`: the shell must not have exited (input).
fn terminalEntry(s: *Server, p: *Peer, re: u64, id: []const u8, running: bool) ?*Entry {
    const e = findEntry(s, id) orelse {
        peers.replyError(s, p.id, re, .not_found, "No session has this id.");
        return null;
    };
    if (e.refused) {
        peers.replyError(s, p.id, re, .refused, "The session runs a build that this server cannot speak to.");
        return null;
    }
    if (!e.listed()) {
        peers.replyError(s, p.id, re, .starting, "The session is not ready.");
        return null;
    }
    if (running and e.exit != null) {
        peers.replyError(s, p.id, re, .exited, "The session's shell exited.");
        return null;
    }
    return e;
}

/// `session.send`: the text goes to the session as input of a client that
/// does not show the pane, so the leader stays.
pub fn send(s: *Server, p: *Peer, re: u64, args: m.SessionSend.Args) void {
    if (args.text.bytes.len > m.send_max)
        return peers.replyError(s, p.id, re, .invalid_args, "The text is over 64 KiB.");
    const e = terminalEntry(s, p, re, args.id, true) orelse return;
    if (args.text.bytes.len > 0) e.conn.send(s.gpa, m.pane_channel, .bytes, args.text.bytes) catch return lostEntry(s, p, re, e);
    if (args.submit) e.conn.send(s.gpa, m.pane_channel, .bytes, "\n") catch return lostEntry(s, p, re, e);
    peers.reply(s, p.id, re, m.SessionSend, .{});
}

/// The session's connection failed during a request that waits for no
/// answer of the session: the request gets its reply here.
fn lostEntry(s: *Server, p: *Peer, re: u64, e: *Entry) void {
    entryGone(s, e);
    peers.replyError(s, p.id, re, .not_found, "No session has this id.");
}

/// `session.key`: the session parses and encodes the chord itself. The
/// server parses it too, so that a chord that does not parse gets an error.
pub fn sendKey(s: *Server, p: *Peer, re: u64, args: m.SessionKey.Args) void {
    if (chord.parse(args.chord) == null)
        return peers.replyError(s, p.id, re, .invalid_args, "The key combination does not parse.");
    const e = terminalEntry(s, p, re, args.id, true) orelse return;
    e.conn.sendPane(s.gpa, m.Key, .{ .chord = args.chord }) catch return lostEntry(s, p, re, e);
    peers.reply(s, p.id, re, m.SessionKey, .{});
}

/// `session.history`: the reply goes when the session's `history` comes.
pub fn readHistory(s: *Server, p: *Peer, re: u64, args: m.SessionHistory.Args) void {
    const e = terminalEntry(s, p, re, args.id, false) orelse return;
    wait(s, &e.waiters, .{ .peer = p.id, .re = re, .kind = .history });
    sendEntryPane(s, e, m.HistoryRead, .{ .scrollback = args.scrollback });
}

/// `session.inspect`: the reply goes when the session's `inspect` comes.
pub fn readInspect(s: *Server, p: *Peer, re: u64, id: []const u8) void {
    const e = terminalEntry(s, p, re, id, false) orelse return;
    wait(s, &e.waiters, .{ .peer = p.id, .re = re, .kind = .inspect });
    sendEntryPane(s, e, m.InspectRead, .{});
}

/// Adds a waiter, or answers it at once when there is no memory for it.
pub fn wait(s: *Server, list: *std.ArrayList(Waiter), w: Waiter) void {
    list.append(s.gpa, w) catch peers.replyError(s, w.peer, w.re, .unavailable, "The server is out of memory.");
}

/// A refused session has no connection. Each list and each idle check
/// connects to its socket again, so that one that ended is not listed.
pub fn checkRefused(s: *Server) void {
    for (s.entries.items) |e| {
        if (!e.refused or e.conn.dead) continue;
        const path = socket.getSocketPath(s.gpa, s.dir, e.id) catch continue;
        defer s.gpa.free(path);
        if (connectNonblocking(path)) |fd| lib_posix.close(fd) else |err| switch (err) {
            error.WouldBlock => {},
            else => e.conn.dead = true,
        }
    }
}

pub fn allSettled(s: *const Server) bool {
    const t = s.now();
    for (s.entries.items) |e| if (!e.conn.dead and !e.settled(t)) return false;
    return true;
}

pub fn answerLists(s: *Server) void {
    if (s.list_waiters.items.len == 0 or !allSettled(s)) return;
    const waiters = s.list_waiters.toOwnedSlice(s.gpa) catch return;
    defer s.gpa.free(waiters);
    for (waiters) |w| switch (w.kind) {
        .subscribe => model_ipc.replySubscribe(s, w.peer, w.re),
        else => replyList(s, w.peer, w.re),
    };
}

pub fn replyList(s: *Server, peer: u64, re: u64) void {
    var list = sessions(s) catch return;
    defer list.deinit(s.gpa);
    peers.reply(s, peer, re, m.SessionList, .{ .sessions = list.items });
}

/// Every session that the server can say something true of, by id. The
/// caller frees the list.
pub fn sessions(s: *Server) error{OutOfMemory}!std.ArrayList(m.Session) {
    checkRefused(s);
    var list: std.ArrayList(m.Session) = .empty;
    errdefer list.deinit(s.gpa);
    for (s.entries.items) |e| if (e.listed()) try list.append(s.gpa, e.info());
    std.mem.sortUnstable(m.Session, list.items, {}, struct {
        fn less(_: void, a: m.Session, b: m.Session) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);
    return list;
}

/// On a host, removes the file of each server build that no session
/// runs (design/002, design/005 step 5). The app installs each build as
/// `macterm-<key>` in one folder, and a session keeps the build that
/// started it, so a file goes when the last session of its build ends.
/// The server never removes its own file.
///
/// It fails closed: it does nothing unless the server runs from such a
/// file (not the Mac's bundle, not a file that was replaced), nothing
/// while a session's build has no key, and it keeps a file of the last
/// minute (`fresh_build_ms`), whose proxy may still come.
pub fn pruneBuilds(s: *Server) void {
    const own = keyOf(build_options.key) orelse return;
    const folder = std.fs.path.dirname(s.exe) orelse return;
    if (!isBuildFile(std.fs.path.basename(s.exe), own)) return;
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(s.gpa);
    for (s.entries.items) |e| {
        if (e.conn.dead) continue;
        keys.append(s.gpa, e.build_key orelse return) catch return;
    }
    var dir = std.Io.Dir.openDirAbsolute(s.io, folder, .{ .iterate = true }) catch return;
    defer dir.close(s.io);
    const now_ms = std.Io.Timestamp.now(s.io, .real).toMilliseconds();
    var it = dir.iterate();
    while (it.next(s.io) catch null) |entry| {
        if (entry.kind != .file or !staleBuild(entry.name, own, keys.items)) continue;
        // A build that an app just installed: its proxy has not started
        // yet, so no session reports it.
        const stat = dir.statFile(s.io, entry.name, .{}) catch continue;
        if (now_ms - stat.mtime.toMilliseconds() < fresh_build_ms) continue;
        dir.deleteFile(s.io, entry.name) catch |err| {
            std.log.warn("server: cannot remove {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        std.log.info("server: removed {s}, which no session runs", .{entry.name});
    }
}

extern "c" fn responsibility_spawnattrs_setdisclaim(attr: *cross.posix_spawnattr_t, disclaim: c_int) c_int;

/// The one `posix_spawn` of a session process (`registry.spawn`). `spec_fd` is
/// the session's end of the socket pair. It becomes `session.spec_fd`.
///
/// The disclaim makes the session its own responsible process on macOS, for
/// its whole life (macterm#419). Without it, the session belongs to the app
/// that started the server. After that app quits, a program that Apple did
/// not sign gets EHOSTUNREACH on the local network, with no prompt. The
/// disclaim exists only as a spawn attribute (server/AGENTS.md).
fn spawnSession(exe: [:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, spec_fd: i32) !lib_posix.pid_t {
    var attr: cross.posix_spawnattr_t = undefined;
    if (cross.posix_spawnattr_init(&attr) != 0) return error.SpawnAttr;
    defer _ = cross.posix_spawnattr_destroy(&attr);
    var flags: c_int = cross.POSIX_SPAWN_SETSID;
    if (comptime builtin.os.tag.isDarwin()) flags |= cross.POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (cross.posix_spawnattr_setflags(&attr, @intCast(flags)) != 0) return error.SpawnAttr;
    if (comptime builtin.os.tag.isDarwin()) {
        if (responsibility_spawnattrs_setdisclaim(&attr, 1) != 0) return error.SpawnAttr;
    }

    var actions: cross.posix_spawn_file_actions_t = undefined;
    if (cross.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnActions;
    defer _ = cross.posix_spawn_file_actions_destroy(&actions);
    if (cross.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", @bitCast(lib_posix.O{ .ACCMODE = .RDWR }), 0) != 0 or
        cross.posix_spawn_file_actions_adddup2(&actions, 0, 1) != 0 or
        cross.posix_spawn_file_actions_adddup2(&actions, 0, 2) != 0 or
        cross.posix_spawn_file_actions_adddup2(&actions, spec_fd, session.spec_fd) != 0)
        return error.SpawnActions;

    var pid: cross.pid_t = undefined;
    const rc = cross.posix_spawn(&pid, exe.ptr, &actions, &attr, @ptrCast(@constCast(argv)), @ptrCast(@constCast(envp)));
    if (rc != 0) {
        std.log.warn("server: posix_spawn failed rc={d}", .{rc});
        return error.SpawnFailed;
    }
    return pid;
}

/// A connect that fails with `error.WouldBlock` when the session's backlog
/// is full, so that a stuck session never stops the server.
pub fn connectNonblocking(path: []const u8) !i32 {
    var addr = try lib_posix.initUnix(path);
    const fd = try lib_posix.socket(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM | lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC, 0);
    errdefer lib_posix.close(fd);
    try lib_posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// A session's build as the server keeps it: at most 64 bytes of printable
/// ASCII, or `unknown`.
pub fn buildName(build: []const u8) []const u8 {
    if (build.len == 0 or build.len > 64) return "unknown";
    for (build) |c| if (c < 0x20 or c > 0x7e) return "unknown";
    return build;
}

/// A build key (`hello.build_key`, `scripts/build-server.sh`) when it is
/// one: lowercase hex, at most 40 characters. Null for anything else.
pub fn keyOf(key: ?[]const u8) ?[]const u8 {
    const k = key orelse return null;
    return if (validKey(k)) k else null;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 40) return false;
    for (key) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// `macterm-<key>`: the name of the server file of the build `key` on a host.
fn isBuildFile(name: []const u8, key: []const u8) bool {
    const prefix = "macterm-";
    return std.mem.startsWith(u8, name, prefix) and std.mem.eql(u8, name[prefix.len..], key);
}

/// A server file of another build than `own` that no session runs. A temp
/// file of an install (`.macterm-…`) is not one.
fn staleBuild(name: []const u8, own: []const u8, running: []const []const u8) bool {
    const prefix = "macterm-";
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const key = name[prefix.len..];
    if (!validKey(key) or std.mem.eql(u8, key, own)) return false;
    for (running) |k| if (std.mem.eql(u8, k, key)) return false;
    return true;
}

/// A pid that the server may signal: above 1, and a `pid_t`.
pub fn validPid(pid: i64) bool {
    return pid > 1 and pid <= std.math.maxInt(lib_posix.pid_t);
}

/// The text of a session's failed answer, for the error reply: its first
/// line without an `error: ` prefix. Text that is not UTF-8 is replaced.
fn errorText(stderr: []const u8) []const u8 {
    var line = std.mem.trim(u8, stderr, " \r\n");
    if (std.mem.findScalar(u8, line, '\n')) |i| line = line[0..i];
    if (std.mem.startsWith(u8, line, "error: ")) line = line["error: ".len..];
    if (line.len == 0 or !std.unicode.utf8ValidateSlice(line)) return "The session did not start.";
    return line;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the error text is the first line without its prefix" {
    try testing.expectEqualStrings("session \"a\" already exists", errorText("error: session \"a\" already exists\n"));
    try testing.expectEqualStrings("one", errorText("one\ntwo\n"));
    try testing.expectEqualStrings("The session did not start.", errorText(""));
    try testing.expectEqualStrings("The session did not start.", errorText("error: \xff\n"));
}

test "the server signals no pid that reaches a group or every process" {
    try testing.expect(validPid(2));
    try testing.expect(!validPid(1));
    try testing.expect(!validPid(0));
    try testing.expect(!validPid(-1));
    try testing.expect(!validPid(-500));
    try testing.expect(!validPid(@as(i64, std.math.maxInt(lib_posix.pid_t)) + 1));
}

test "a build key is only lowercase hex" {
    try testing.expectEqualStrings("2705a118fde2c903", keyOf("2705a118fde2c903").?);
    try testing.expect(keyOf(null) == null);
    try testing.expect(keyOf("") == null);
    try testing.expect(keyOf("ABC") == null);
    try testing.expect(keyOf("a/b") == null);
    try testing.expect(keyOf("1.0.1+thdxg.abc") == null);
}

test "a server file goes only when it is another build that no session runs" {
    const running = [_][]const u8{"bbbb"};
    try testing.expect(staleBuild("macterm-cccc", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-aaaa", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-bbbb", "aaaa", &running));
    try testing.expect(!staleBuild(".macterm-cccc.123.456", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-cccc.old", "aaaa", &running));
    try testing.expect(!staleBuild("zmx", "aaaa", &running));
    try testing.expect(!staleBuild("macterm-", "aaaa", &running));
    try testing.expect(isBuildFile("macterm-aaaa", "aaaa"));
    try testing.expect(!isBuildFile("zmx", "aaaa"));
    try testing.expect(!isBuildFile("macterm-aaaa (deleted)", "aaaa"));
}

test "a session's build is kept only as short printable text" {
    try testing.expectEqualStrings("1.0.1+thdxg.abc", buildName("1.0.1+thdxg.abc"));
    try testing.expectEqualStrings("unknown", buildName(""));
    try testing.expectEqualStrings("unknown", buildName("a\x1b[2Jb"));
    const long: [65]u8 = @splat('x');
    try testing.expectEqualStrings("unknown", buildName(&long));
}
