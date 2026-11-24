//! The server's clients: a GUI or a CLI on its socket, or a roaming link.
//! Their requests on channel 0, the event batches, and the relay of each
//! pane on a channel of the client's stream (`relay.zig`).

const std = @import("std");
const lib_posix = @import("posix.zig");
const socket = @import("socket.zig");
const runtime = @import("runtime.zig");
const session = @import("session.zig");
const relay = @import("relay.zig");
const conn = @import("conn.zig");
const FrameConn = conn.FrameConn;
const FrameQueue = conn.FrameQueue;
const link_host = @import("link/host.zig");
const protocol = @import("protocol/protocol.zig");
const frame = protocol.frame;
const msgpack = protocol.msgpack;
const m = protocol.messages;
const server = @import("server.zig");
const registry = @import("registry.zig");
const runs = @import("runs.zig");
const model_ipc = @import("model_ipc.zig");
const Server = server.Server;

const frame_max = server.frame_max;

const max_clients = 64;

/// The send buffer of a client's socket (`SO_SNDBUF`).
const peer_sndbuf = 32 * 1024;

/// The most channels that one client can have open.
const max_channels = 256;

/// A client that sends no `hello` this long after it connects is closed, so
/// that idle connections cannot take every place.
pub const hello_ms = 5000;

/// How many event batches the server keeps for `control.resume`.
pub const batch_ring = 256;

/// One sent event batch.
pub const Batch = struct {
    seq: u64,
    /// The encoded message, as it went on channel 0.
    body: []u8,
};

/// A GUI or a CLI on the server's socket.
pub const Peer = struct {
    id: u64,
    /// The key of this client in the ring of request ids (`model_ipc`). It
    /// is `id`, or the key of a lost connection that `control.resume` names.
    client: u64,
    /// The connection to the client. A write sends its `out`, and
    /// `relay.fill` moves frames into it from `control` and the channels.
    conn: FrameConn,
    connected_at: i64,
    /// Channel 0's frames that wait.
    control: FrameQueue = .{},
    channels: std.ArrayList(*Channel) = .empty,
    next_channel: u32 = 1,
    /// The channel that goes first in the next fill (`relay.fill`).
    turn: usize = 0,

    pub fn findChannel(p: *Peer, id: u32) ?*Channel {
        for (p.channels.items) |ch| if (ch.id == id and !ch.closed) return ch;
        return null;
    }

    /// Everything that waits for this client.
    pub fn pending(p: *const Peer) usize {
        var n = p.conn.out.bytes + p.control.bytes;
        for (p.channels.items) |ch| n += ch.q.bytes;
        return n;
    }

    /// What waits for this client and that no skip can drop. The rest has a
    /// cap for each channel (`relay.skip_bytes`).
    pub fn kept(p: *const Peer) usize {
        var n = p.conn.out.bytes + p.control.bytes;
        for (p.channels.items) |ch| n += ch.q.bytes - ch.q.stale().bytes;
        return n;
    }
};

/// A pane that the server relays to a client: the server's own connection to
/// the session, and the frames that wait for the client.
pub const Channel = struct {
    /// The channel number on the client's stream.
    id: u32,
    session: []u8,
    /// The connection to the session. Its fd is -1 when the session closed
    /// it: the channel goes when its last frames went to the client. Its
    /// `out` holds the client's frames to the session, on the session's
    /// pane channel.
    conn: FrameConn,
    q: FrameQueue = .{},
    flow: relay.Flow = .{},
    /// The `channel.open` request that waits for the session's `hello`.
    open_re: ?u64 = null,
    /// The client closed it. Its input that waits still goes to the session,
    /// then the channel goes.
    closed: bool = false,
    /// The client got the session's `exit`, or the channel's stand-in for it.
    exited: bool = false,
    /// The session process, from its `state`: an `exit` is a read only of
    /// the session that sent it, not of a new session of the same id.
    pid: ?i64 = null,

    pub fn deinit(ch: *Channel, gpa: std.mem.Allocator) void {
        ch.conn.deinit(gpa);
        ch.q.deinit(gpa);
        gpa.free(ch.session);
        gpa.destroy(ch);
    }
};

/// Accepts every client in the backlog.
pub fn accept(s: *Server) void {
    var n: usize = 0;
    while (n < max_clients and acceptOne(s)) : (n += 1) {}
}

/// False when the backlog is empty.
pub fn acceptOne(s: *Server) bool {
    const fd = lib_posix.accept(s.listen_fd, null, null, lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC) catch return false;
    addPeer(s, fd);
    return true;
}

pub fn addPeer(s: *Server, fd: i32) void {
    if (!runtime.allowPeer(runtime.peerUid(fd), std.c.getuid())) {
        std.log.warn("server: refused a peer of another user", .{});
        lib_posix.close(fd);
        return;
    }
    if (s.peers.items.len >= max_clients) {
        std.log.warn("server: {d} clients, a new one closed", .{max_clients});
        lib_posix.close(fd);
        return;
    }
    // Output that waits in the kernel goes before channel 0, whatever
    // order the relay chose: keep that buffer small (Linux gives about
    // 200 KiB by default, macOS 8 KiB).
    const sndbuf: c_int = peer_sndbuf;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDBUF, std.mem.asBytes(&sndbuf), @sizeOf(c_int));
    const p = s.gpa.create(Peer) catch {
        lib_posix.close(fd);
        return;
    };
    p.* = .{ .id = s.next_peer, .client = s.next_peer, .conn = .{ .fd = fd, .max_frame = frame_max }, .connected_at = s.now() };
    s.next_peer += 1;
    s.peers.append(s.gpa, p) catch {
        s.gpa.destroy(p);
        lib_posix.close(fd);
        return;
    };
    sendControl(s, p, s.hello());
}

pub fn findPeer(s: *Server, id: u64) ?*Peer {
    for (s.peers.items) |p| if (p.id == id and !p.conn.dead) return p;
    return null;
}

pub fn readPeer(s: *Server, p: *Peer) void {
    if (p.conn.read(s.gpa, &s.arena, .{ s, p }, handlePeerFrame)) |_| p.conn.dead = true;
}

pub fn handlePeerFrame(s: *Server, p: *Peer, f: frame.Frame, arena: std.mem.Allocator) void {
    // After `server.exit`, nothing more is read.
    if (s.exiting) return;
    if (f.channel != frame.control_channel) {
        if (p.conn.greeted) relayToSession(s, p, f);
        return;
    }
    const msg = m.decodeControl(arena, f.body) catch {
        p.conn.dead = true;
        return;
    };

    if (!p.conn.greeted) {
        const theirs = switch (msg) {
            .hello => |h| h,
            else => {
                p.conn.dead = true;
                return;
            },
        };
        switch (m.negotiate(s.hello(), theirs)) {
            .refuse => |r| {
                std.log.info("server: refused a {s} at level {d}: {s}", .{ @tagName(theirs.role), theirs.level, r.reason });
                sendControl(s, p, r);
                p.conn.closing = true;
            },
            .speak => p.conn.greeted = true,
        }
        return;
    }
    switch (msg) {
        .request => |req| handleRequest(s, p, arena, req),
        else => {},
    }
}

pub fn handleRequest(s: *Server, p: *Peer, arena: std.mem.Allocator, req: m.Request) void {
    inline for (m.methods) |M| {
        if (std.mem.eql(u8, req.m, M.name)) {
            // Every connection to this socket is `local` (design/006 §2).
            if (!m.maySend(M, .local)) {
                std.log.warn("server: {s} from a local client, refused", .{M.name});
                return replyError(s, p.id, req.id, .forbidden, "This connection may not send this request.");
            }
            const args = m.decodeArgs(M, arena, req) catch
                return replyError(s, p.id, req.id, .invalid_args, "The arguments do not decode.");
            if (comptime model_ipc.isWrite(M)) return model_ipc.call(s, M, p, req.id, req.a, args);
            return call(s, M, p, req.id, args);
        }
    }
    replyError(s, p.id, req.id, .unknown_method, "The server has no such method.");
}

pub fn call(s: *Server, comptime M: type, p: *Peer, re: u64, args: M.Args) void {
    switch (M) {
        m.SessionCreate => registry.create(s, p, re, args),
        m.SessionList => {
            if (registry.allSettled(s)) return registry.replyList(s, p.id, re);
            registry.wait(s, &s.list_waiters, .{ .peer = p.id, .re = re, .kind = .list });
        },
        m.SessionInfo => {
            const e = registry.findEntry(s, args.id) orelse
                return replyError(s, p.id, re, .not_found, "No session has this id.");
            if (e.listed()) return registry.replyInfo(s, p.id, re, e);
            registry.wait(s, &e.waiters, .{ .peer = p.id, .re = re, .kind = .info });
        },
        m.SessionKill => registry.kill(s, p, re, args.id),
        m.SessionSend => registry.send(s, p, re, args),
        m.SessionKey => registry.sendKey(s, p, re, args),
        m.SessionHistory => registry.readHistory(s, p, re, args),
        m.SessionInspect => registry.readInspect(s, p, re, args.id),
        m.PaneSeen => {
            const e = registry.findEntry(s, args.id) orelse
                return replyError(s, p.id, re, .not_found, "No session has this id.");
            if (e.refused) return replyError(s, p.id, re, .refused, "The session runs a build that this server cannot speak to.");
            if (e.conn.dead or e.exit != null) return replyError(s, p.id, re, .not_found, "No running session has this id.");
            if (!e.listed()) return replyError(s, p.id, re, .starting, "The session is not ready.");
            registry.wait(s, &e.waiters, .{ .peer = p.id, .re = re, .kind = .seen });
            registry.sendEntryPane(s, e, m.Seen, .{});
        },
        m.ServerExit => {
            std.log.info("server: server.exit", .{});
            // On disk before the reply: a newer server that starts after it
            // reads the last state (design/010 §10).
            model_ipc.flush(s);
            // Unlinked before the reply, so that a start that follows the
            // reply finds no server (design/002).
            s.closeListen();
            reply(s, p.id, re, m.ServerExit, .{});
            s.exit_peer = p.id;
            s.exiting = true;
            // It reads nothing more: a bad frame after this request must
            // not close it before the reply goes (`Server.flushFor`).
            p.conn.closing = true;
        },
        m.ControlResume => resumeControl(s, p, re, args),
        m.StateSubscribe => model_ipc.subscribe(s, p, re),
        m.ChannelOpen => openChannel(s, p, re, args.session),
        m.ChannelClose => {
            const ch = p.findChannel(args.channel) orelse
                return replyError(s, p.id, re, .not_found, "No channel has this number.");
            ch.closed = true;
            ch.q.deinit(s.gpa);
            reply(s, p.id, re, m.ChannelClose, .{});
        },
        m.ChannelPause => {
            const ch = p.findChannel(args.channel) orelse
                return replyError(s, p.id, re, .not_found, "No channel has this number.");
            ch.flow.paused = true;
            const open_kept = ch.q.dropStale(s.gpa);
            ch.flow.discard_snapshot = ch.flow.in_snapshot and !open_kept;
            reply(s, p.id, re, m.ChannelPause, .{});
        },
        m.ChannelResume => {
            const ch = p.findChannel(args.channel) orelse
                return replyError(s, p.id, re, .not_found, "No channel has this number.");
            if (ch.flow.paused) {
                ch.flow.paused = false;
                askSnapshot(s, ch, s.now());
            }
            reply(s, p.id, re, m.ChannelResume, .{});
        },
        m.Ping => reply(s, p.id, re, m.Ping, .{}),
        m.CommandRun => runs.runCommand(s, p, re, args),
        m.LinkOpen => linkOpen(s, p, re, args),
        m.LinkClose => {
            if (!s.links.closeKey(args.key_id))
                return replyError(s, p.id, re, .not_found, "No link has this key id.");
            reply(s, p.id, re, m.LinkClose, .{});
        },
        else => replyError(s, p.id, re, .unknown_method, "The server has no such method."),
    }
}

/// The first and last UDP port of a link, from `MACTERM_LINK_PORTS`
/// (`first-last`). Null when the link is off: `MACTERM_LINK=off`, or a
/// range that does not parse (fail closed: a typo must not open a port
/// outside a firewall's range).
pub fn linkPorts() ?[2]u16 {
    if (std.c.getenv("MACTERM_LINK")) |v| if (std.mem.eql(u8, std.mem.span(v), "off")) return null;
    const range = std.c.getenv("MACTERM_LINK_PORTS") orelse
        return .{ link_host.default_first_port, link_host.default_last_port };
    const text = std.mem.span(range);
    const dash = std.mem.findScalar(u8, text, '-') orelse return null;
    const first = std.fmt.parseInt(u16, text[0..dash], 10) catch return null;
    const last = std.fmt.parseInt(u16, text[dash + 1 ..], 10) catch return null;
    if (first == 0 or first > last) return null;
    return .{ first, last };
}

pub fn linkOpen(s: *Server, p: *Peer, re: u64, args: m.LinkOpen.Args) void {
    const ports = linkPorts() orelse
        return replyError(s, p.id, re, .unavailable, "The link is off on this host.");
    if (args.secret.bytes.len != m.link_secret_len)
        return replyError(s, p.id, re, .invalid_args, "The key is not 32 bytes.");
    var seed: u32 = undefined;
    s.io.random(std.mem.asBytes(&seed));
    var key: [32]u8 = args.secret.bytes[0..32].*;
    defer std.crypto.secureZero(u8, &key);
    const opened = s.links.open(p.id, key, args.key_id, s.now(), ports, seed) catch |err| {
        std.log.warn("server: link.open failed: {s}", .{@errorName(err)});
        return switch (err) {
            error.KeyInUse => replyError(s, p.id, re, .invalid_args, "Another link has this key id."),
            error.TooMany => replyError(s, p.id, re, .unavailable, "The server has too many links."),
            else => replyError(s, p.id, re, .unavailable, "The server cannot open a link."),
        };
    };
    s.pending_peers.append(s.gpa, opened.peer_fd) catch {
        lib_posix.close(opened.peer_fd);
        _ = s.links.closeKey(args.key_id);
        return replyError(s, p.id, re, .unavailable, "The server cannot open a link.");
    };
    reply(s, p.id, re, m.LinkOpen, .{ .port = opened.port });
}

pub fn reply(s: *Server, peer: u64, re: u64, comptime M: type, result: M.Result) void {
    const p = findPeer(s, peer) orelse return;
    var out: std.Io.Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    m.encodeResult(&out.writer, re, M, result) catch return;
    sendBody(s, p, out.written());
}

pub fn replyError(s: *Server, peer: u64, re: u64, code: m.ErrorCode, message: []const u8) void {
    const p = findPeer(s, peer) orelse return;
    sendControl(s, p, m.Response{ .re = re, .err = .{ .code = @tagName(code), .message = message } });
}

/// One event is one batch: one consistent state (design/003 §5).
pub fn emit(s: *Server, comptime E: type, value: E) void {
    const args = msgpack.encodeAlloc(s.gpa, value) catch return;
    defer s.gpa.free(args);
    emitBatch(s, &.{.{ .e = E.name, .a = .{ .bytes = args } }}, null);
}

/// The request that caused a batch, and the client that sent it.
pub const Cause = struct { peer: u64, re: u64 };

/// Sends one batch of events to every client. The requester's copy carries
/// `cause`; the ring keeps the copy with none, as every other client gets
/// it.
pub fn emitBatch(s: *Server, ev: []const m.Event, cause: ?Cause) void {
    s.seq += 1;
    const batch: m.EventBatch = .{ .seq = s.seq, .ev = ev };
    const body = msgpack.encodeAlloc(s.gpa, batch) catch {
        // The batch is lost: the ring must not claim to be complete.
        for (s.batches.items) |b| s.gpa.free(b.body);
        s.batches.clearRetainingCapacity();
        return;
    };
    const kept = keepBatch(s, body);
    defer if (!kept) s.gpa.free(body);
    var caused: ?[]u8 = null;
    defer if (caused) |c| s.gpa.free(c);
    if (cause) |c| {
        var with = batch;
        with.cause = c.re;
        caused = msgpack.encodeAlloc(s.gpa, with) catch null;
    }
    for (s.peers.items) |p| if (p.conn.greeted and !p.conn.dead) {
        const own = if (cause) |c| c.peer == p.id else false;
        if (own) {
            // With no memory for the copy with `cause`, the client gets
            // the batch without it: its state is right, only an animation
            // is lost.
            sendBody(s, p, caused orelse body);
        } else sendBody(s, p, body);
    };
}

/// Keeps the batch for `control.resume`, and gives up the oldest ones.
/// The ring owns `body` when this returns true. On an allocation failure
/// the ring is emptied, so that a resume never skips a batch.
pub fn keepBatch(s: *Server, body: []u8) bool {
    s.batches.append(s.gpa, .{ .seq = s.seq, .body = body }) catch {
        for (s.batches.items) |b| s.gpa.free(b.body);
        s.batches.clearRetainingCapacity();
        return false;
    };
    while (s.batches.items.len > batch_ring) {
        s.gpa.free(s.batches.orderedRemove(0).body);
    }
    return true;
}

/// `control.resume`: sends the batches after `args.seq` when the epoch is
/// this server's and the ring still holds every one of them.
pub fn resumeControl(s: *Server, p: *Peer, re: u64, args: m.ControlResume.Args) void {
    // The ring of request ids is of this epoch: an older client key means
    // nothing to it.
    if (args.epoch == s.epoch) if (args.client) |c| {
        p.client = c;
    };
    const held = s.batches.items;
    const complete = args.epoch == s.epoch and args.seq <= s.seq and
        (args.seq == s.seq or (held.len > 0 and held[0].seq <= args.seq + 1));
    if (complete) {
        for (held) |b| if (b.seq > args.seq) sendBody(s, p, b.body);
    }
    reply(s, p.id, re, m.ControlResume, .{ .replayed = complete, .seq = s.seq });
}

pub fn sendControl(s: *Server, p: *Peer, value: anytype) void {
    const body = msgpack.encodeAlloc(s.gpa, value) catch return;
    defer s.gpa.free(body);
    sendBody(s, p, body);
}

pub fn sendBody(s: *Server, p: *Peer, body: []const u8) void {
    p.control.push(s.gpa, frame.control_channel, .msg, body, s.now(), .message) catch {
        p.conn.dead = true;
        return;
    };
    checkPeerCap(s, p);
}

pub fn checkPeerCap(s: *Server, p: *Peer) void {
    _ = s;
    if (p.kept() > session.client_hard_cap) {
        std.log.warn("server: client fd={d} does not read, closed", .{p.conn.fd});
        p.conn.dead = true;
    }
}

pub fn writePeer(s: *Server, p: *Peer) void {
    if (p.conn.out.empty()) {
        var queues: std.ArrayList(*FrameQueue) = .empty;
        defer queues.deinit(s.gpa);
        for (p.channels.items) |ch| queues.append(s.gpa, &ch.q) catch {
            p.conn.dead = true;
            return;
        };
        relay.fill(s.gpa, &p.conn.out, &p.control, queues.items, &p.turn) catch {
            p.conn.dead = true;
            return;
        };
    }
    p.conn.flush(s.gpa) catch {
        p.conn.dead = true;
        return;
    };
    if (p.pending() == 0 and p.conn.closing) p.conn.dead = true;
}

pub fn openChannel(s: *Server, p: *Peer, re: u64, id: []const u8) void {
    const e = registry.findEntry(s, id) orelse return replyError(s, p.id, re, .not_found, "No session has this id.");
    if (e.refused) return replyError(s, p.id, re, .refused, "The session runs a build that this server cannot speak to.");
    if (e.state == null) return replyError(s, p.id, re, .starting, "The session is not ready.");
    if (p.channels.items.len >= max_channels)
        return replyError(s, p.id, re, .busy, "This connection has too many open channels.");
    const path = socket.getSocketPath(s.gpa, s.dir, id) catch
        return replyError(s, p.id, re, .unavailable, "The server is out of memory.");
    defer s.gpa.free(path);
    const fd = registry.connectNonblocking(path) catch |err| {
        std.log.warn("server: cannot connect to session {s} for a channel: {s}", .{ id, @errorName(err) });
        return replyError(s, p.id, re, .unavailable, "The session does not answer.");
    };
    const ch = s.gpa.create(Channel) catch {
        lib_posix.close(fd);
        return replyError(s, p.id, re, .unavailable, "The server is out of memory.");
    };
    ch.* = .{ .id = p.next_channel, .session = s.gpa.dupe(u8, id) catch {
        lib_posix.close(fd);
        s.gpa.destroy(ch);
        return replyError(s, p.id, re, .unavailable, "The server is out of memory.");
    }, .conn = .{ .fd = fd, .max_frame = frame_max } };
    p.channels.append(s.gpa, ch) catch {
        ch.deinit(s.gpa);
        return replyError(s, p.id, re, .unavailable, "The server is out of memory.");
    };
    p.next_channel +%= 1;
    if (p.next_channel == frame.control_channel) p.next_channel = 1;
    // The reply goes when the session's `hello` comes, so that a session
    // that refuses the server gives an error, not a channel that is
    // silent.
    ch.open_re = re;
    sendChannelControl(s, ch, s.hello());
}

/// A frame from the client on a pane channel goes to the session, never
/// dropped. A frame for a channel that is not open is ignored.
pub fn relayToSession(s: *Server, p: *Peer, f: frame.Frame) void {
    const ch = p.findChannel(f.channel) orelse return;
    if (ch.conn.fd < 0) return;
    ch.conn.send(s.gpa, m.pane_channel, f.kind, f.body) catch return channelGone(s, p, ch);
    if (ch.conn.out.bytes > session.client_hard_cap) {
        std.log.warn("server: session {s} does not read its channel, closed", .{ch.session});
        channelGone(s, p, ch);
    }
}

pub fn readChannel(s: *Server, p: *Peer, ch: *Channel) void {
    const t = s.now();
    if (ch.conn.read(s.gpa, &s.arena, .{ s, p, ch, t }, handleChannelFrame)) |end| switch (end) {
        .closed => return channelEnded(s, p, ch),
        .too_large => {
            std.log.warn("server: session {s} sent a frame over 1 MiB on a channel, closed", .{ch.session});
            return channelGone(s, p, ch);
        },
        .bad_frame, .no_memory => return channelGone(s, p, ch),
    };
    if (ch.conn.fd >= 0 and ch.flow.mustSkip(ch.q.stale(), t)) skip(s, ch, t);
    checkPeerCap(s, p);
}

pub fn handleChannelFrame(s: *Server, p: *Peer, ch: *Channel, t: i64, f: frame.Frame, arena: std.mem.Allocator) void {
    if (p.conn.dead) return;
    if (f.channel == frame.control_channel) {
        const msg = m.decodeControl(arena, f.body) catch return channelGone(s, p, ch);
        switch (msg) {
            .hello => |h| if (!ch.conn.greeted) switch (m.negotiate(s.hello(), h)) {
                .speak => {
                    ch.conn.greeted = true;
                    if (ch.open_re) |re| reply(s, p.id, re, m.ChannelOpen, .{ .channel = ch.id, .epoch = h.epoch });
                    ch.open_re = null;
                },
                .refuse => |r| {
                    std.log.info("server: session {s} speaks level {d}, channel closed", .{ ch.session, h.level });
                    sendChannelControl(s, ch, r);
                    ch.conn.flush(s.gpa) catch {};
                    channelGone(s, p, ch);
                },
            },
            .refuse => channelGone(s, p, ch),
            else => {},
        }
        return;
    }
    if (!ch.conn.greeted or f.channel != m.pane_channel) return;
    const class: conn.Class = switch (f.kind) {
        .msg => blk: {
            const msg = msgpack.decodeSlice(m.PaneMessage, arena, f.body) catch return channelGone(s, p, ch);
            if (std.mem.eql(u8, msg.t, m.SnapshotStart.name)) break :blk .snapshot_start;
            if (std.mem.eql(u8, msg.t, m.SnapshotEnd.name)) break :blk .snapshot_end;
            if (std.mem.eql(u8, msg.t, m.State.name)) {
                if (m.decodePane(m.State, arena, msg)) |st| ch.pid = st.pid else |_| {}
            }
            if (std.mem.eql(u8, msg.t, m.Exit.name)) {
                ch.exited = true;
                // The `exit` is in the client's queue, which the end of the
                // session does not drop.
                if (registry.findEntry(s, ch.session)) |e| if (e.state) |st| if (ch.pid == st.pid) registry.statusRead(s, e);
            }
            break :blk .message;
        },
        .bytes => if (ch.flow.in_snapshot) .snapshot else .output,
        _ => return,
    };
    if (ch.flow.classify(class) == .drop) return;
    ch.q.push(s.gpa, ch.id, f.kind, f.body, t, class) catch channelGone(s, p, ch);
}

/// The channel's output is too old or too large: drop it, and show the
/// screen as it is now (design/003 §6).
pub fn skip(s: *Server, ch: *Channel, t: i64) void {
    std.log.info("server: channel {d} (session {s}) fell behind, output dropped", .{ ch.id, ch.session });
    ch.flow.skipped(ch.q.dropStale(s.gpa), t);
    sendRefresh(s, ch);
}

/// Output stops until the session's snapshot starts.
pub fn askSnapshot(s: *Server, ch: *Channel, t: i64) void {
    ch.flow.want_snapshot = true;
    ch.flow.asked_at = t;
    sendRefresh(s, ch);
}

pub fn sendRefresh(s: *Server, ch: *Channel) void {
    var out: std.Io.Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    m.encodePane(&out.writer, m.Refresh, .{}) catch return;
    ch.conn.send(s.gpa, m.pane_channel, .msg, out.written()) catch {
        ch.conn.close();
    };
}

pub fn writeChannel(s: *Server, p: *Peer, ch: *Channel) void {
    ch.conn.flush(s.gpa) catch channelGone(s, p, ch);
}

/// The session closed the channel's connection. The frames that wait
/// still go to the client (a last `exit`), then the channel goes.
/// The session closed its end of the channel with no `exit` (it was
/// killed, or it crashed): the client gets an `exit` with no status, as
/// the end of the channel. A failure of the relay itself (`channelGone`)
/// is not an exit.
pub fn channelEnded(s: *Server, p: *Peer, ch: *Channel) void {
    if (ch.conn.fd >= 0 and ch.conn.greeted and !ch.closed and !ch.exited) {
        ch.exited = true;
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        if (m.encodePane(&out.writer, m.Exit, .{})) {
            ch.q.push(s.gpa, ch.id, .msg, out.written(), s.now(), .message) catch {};
        } else |_| {}
    }
    channelGone(s, p, ch);
}

pub fn channelGone(s: *Server, p: *Peer, ch: *Channel) void {
    if (ch.open_re) |re| replyError(s, p.id, re, .unavailable, "The session closed the connection.");
    ch.open_re = null;
    ch.conn.close();
}

pub fn sendChannelControl(s: *Server, ch: *Channel, value: anytype) void {
    ch.conn.sendControl(s.gpa, value) catch ch.conn.close();
}
