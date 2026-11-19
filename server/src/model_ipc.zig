//! The model on the server's socket (design/010 §2, §3): `state.subscribe`,
//! the requests that change the model, their events, the ring of request
//! ids, and `model.json`.
//!
//! Only a server that the app gave `MACTERM_STATE_DIR` has a model. A host's
//! server never gets the variable, so it answers `state.subscribe` with no
//! model and refuses every model request (`unavailable`), and it writes no
//! file.
//!
//! **The events come from a compare.** Before a request, the server encodes
//! each project, workspace, tab and pane of the model; after it, it encodes
//! them again and sends an event for each one that changed. So the events
//! always match the model, and no request has its own event code. A request
//! that fails changes nothing (`model.zig`) and sends no event.
//!
//! **The file.** The server writes `model.json` 100 ms after the first change
//! that is not on disk, before it answers `server.exit` (so a newer server
//! that starts after the reply reads the last state), and when it stops. A
//! file that the server could not read, or that a newer build wrote, makes
//! the model read-only: no request changes it, and the server never writes
//! over that file.

const std = @import("std");
const lib_posix = @import("posix.zig");
const protocol = @import("protocol/protocol.zig");
const msgpack = protocol.msgpack;
const m = protocol.messages;
const model = @import("model/model.zig");
const file = @import("model/file.zig");
const tree = model.tree;
const server = @import("server.zig");
const peers = @import("peers.zig");
const registry = @import("registry.zig");
const Server = server.Server;
const Peer = peers.Peer;
const Model = model.Model;

/// The folder of `model.json`. The app sets it (design/010 §2).
pub const state_dir_env = "MACTERM_STATE_DIR";

pub const file_name = "model.json";

/// A change goes to disk this long after the first change that is not
/// there yet.
pub const save_delay_ms = 100;

/// How many answers the ring of request ids keeps (design/010 §4).
pub const request_ring = 256;

/// One answer of the ring: what a model request got, for the client that
/// sent it.
const Answer = struct {
    client: u64,
    re: u64,
    method: []const u8,
    /// The encoded response, as it went on channel 0.
    body: []u8,
};

pub const State = struct {
    /// Null when the server has no model.
    model: ?Model = null,
    /// The path of `model.json`.
    path: ?[]u8 = null,
    /// The file did not read, or a newer build wrote it.
    readonly: bool = false,
    /// When the first change that is not on disk came.
    dirty_since: ?i64 = null,
    /// `model.options`: the `rebalance` of a request that does not say.
    auto_tiling: bool = false,
    /// The last `request_ring` answers to model requests, oldest first.
    answers: std.ArrayList(Answer) = .empty,

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        if (st.model) |*mo| mo.deinit();
        if (st.path) |p| gpa.free(p);
        for (st.answers.items) |a| gpa.free(a.body);
        st.answers.deinit(gpa);
        st.* = .{};
    }

    /// The time of the next save, or null.
    pub fn deadline(st: *const State) ?i64 {
        const since = st.dirty_since orelse return null;
        return since + save_delay_ms;
    }
};

// ── Start and save ──────────────────────────────────────────────────────────

/// Reads `model.json` from `MACTERM_STATE_DIR`. With no variable, the
/// server has no model.
pub fn load(s: *Server) void {
    const dir = std.c.getenv(state_dir_env) orelse return;
    loadFrom(s, std.mem.span(dir));
}

pub fn loadFrom(s: *Server, dir_text: []const u8) void {
    const st = &s.model;
    var dir = dir_text;
    while (dir.len > 1 and dir[dir.len - 1] == '/') dir = dir[0 .. dir.len - 1];
    if (dir.len == 0 or dir[0] != '/') {
        std.log.warn("server: {s} is not an absolute path, no model", .{state_dir_env});
        return;
    }
    st.path = std.fs.path.join(s.gpa, &.{ dir, file_name }) catch return;
    var fault: model.Fault = .{};
    st.model = file.load(s.gpa, s.io, st.path.?, &fault) catch |err| blk: {
        // Fail closed: an empty model that no request changes, and no write
        // over the file that did not read.
        switch (err) {
            error.Invalid => std.log.err("server: {s} is not a valid model ({s}), read-only", .{ st.path.?, fault.text() }),
            else => std.log.err("server: cannot read {s}: {s}, read-only", .{ st.path.?, @errorName(err) }),
        }
        st.readonly = true;
        break :blk Model.init(s.gpa);
    };
    std.log.info("server: model from {s}: {d} projects, {d} workspaces", .{ st.path.?, st.model.?.data.projects.len, st.model.?.data.workspaces.len });
}

/// Writes the model now if a change is not on disk. A write that fails is
/// logged; the model stays in memory, and the next change tries again.
pub fn flush(s: *Server) void {
    const st = &s.model;
    if (st.dirty_since == null) return;
    st.dirty_since = null;
    if (st.readonly) return;
    const path = st.path orelse return;
    const mo = &(st.model orelse return);
    ensureParent(path);
    file.save(s.gpa, s.io, mo, path) catch |err| {
        std.log.err("server: cannot write {s}: {s}", .{ path, @errorName(err) });
    };
}

/// Saves when the delay after a change is over.
pub fn timers(s: *Server) void {
    const d = s.model.deadline() orelse return;
    if (s.now() >= d) flush(s);
}

/// The folder of `path`, if it is not there (one level, 0700).
fn ensureParent(path: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{parent}, 0) catch return;
    _ = std.c.mkdir(z.ptr, 0o700);
}

// ── state.subscribe ─────────────────────────────────────────────────────────

pub fn subscribe(s: *Server, p: *Peer, re: u64) void {
    if (registry.allSettled(s)) return replySubscribe(s, p.id, re);
    registry.wait(s, &s.list_waiters, .{ .peer = p.id, .re = re, .kind = .subscribe });
}

pub fn replySubscribe(s: *Server, peer: u64, re: u64) void {
    const p = peers.findPeer(s, peer) orelse return;
    var list = registry.sessions(s) catch return peers.replyError(s, peer, re, .unavailable, "The server is out of memory.");
    defer list.deinit(s.gpa);
    var zoomed: std.ArrayList(m.Zoom) = .empty;
    defer zoomed.deinit(s.gpa);
    if (s.model.model) |*mo| {
        var it = mo.zoomed.iterator();
        while (it.next()) |e| zoomed.append(s.gpa, .{ .tab = e.key_ptr.*, .pane = e.value_ptr.* }) catch
            return peers.replyError(s, peer, re, .unavailable, "The server is out of memory.");
    }
    peers.reply(s, peer, re, m.StateSubscribe, .{
        .epoch = s.epoch,
        .seq = s.seq,
        .model = if (s.model.model) |mo| mo.data else null,
        .zoomed = zoomed.items,
        .readonly = s.model.readonly,
        .sessions = list.items,
        .client = p.client,
    });
}

// ── Requests ────────────────────────────────────────────────────────────────

pub fn isWrite(comptime M: type) bool {
    inline for (m.model_writes) |W| if (W == M) return true;
    return false;
}

/// What a model request did: its result, or an error for the client.
const Outcome = union(enum) {
    ok,
    removed: []const m.RemovedPane,
    err: struct { code: m.ErrorCode, message: []const u8 },
};

fn fail(code: m.ErrorCode, message: []const u8) Outcome {
    return .{ .err = .{ .code = code, .message = message } };
}

/// Handles a request of `m.model_writes`. The ring answers a request that
/// this client sent before, and nothing happens again.
pub fn call(s: *Server, comptime M: type, p: *Peer, re: u64, args: M.Args) void {
    if (findAnswer(s, p.client, re, M.name)) |body| {
        std.log.info("server: {s} sent again, answered from the ring", .{M.name});
        return peers.sendBody(s, p, body);
    }
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    const outcome: Outcome = if (s.model.model == null)
        fail(.unavailable, "This server has no model.")
    else if (s.model.readonly)
        fail(.model_readonly, "The server could not read its model file, so it changes no model.")
    else
        change(s, M, a, p, re, args) catch fail(.unavailable, "The server is out of memory.");

    var out: std.Io.Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    const encoded = switch (outcome) {
        .ok => m.encodeResult(&out.writer, re, M, .{}),
        .removed => |panes| if (M.Result == m.RemovedPanes)
            m.encodeResult(&out.writer, re, M, .{ .panes = panes })
        else
            unreachable,
        .err => |e| msgpack.encode(&out.writer, m.Response{ .re = re, .err = .{ .code = @tagName(e.code), .message = e.message } }),
    };
    encoded catch return;
    peers.sendBody(s, p, out.written());
    keepAnswer(s, p.client, re, M.name, out.written());
}

/// Applies a request to the model and sends its events. The batch goes
/// before the reply, with `cause` on the requester's connection.
fn change(s: *Server, comptime M: type, a: std.mem.Allocator, p: *Peer, re: u64, args: M.Args) !Outcome {
    const mo = &s.model.model.?;
    if (M == m.ModelOptions) {
        s.model.auto_tiling = args.auto_tiling;
        return .ok;
    }
    const before = try Snapshot.take(a, mo);
    const outcome = try apply(s, M, mo, a, args);
    if (outcome == .err) return outcome;
    const now_model = &s.model.model.?;
    const after = try Snapshot.take(a, now_model);
    var events: std.ArrayList(m.Event) = .empty;
    var removed: std.ArrayList(m.RemovedPane) = .empty;
    try diff(a, &before, &after, &events, &removed, M != m.ModelImport);
    s.model.dirty_since = s.model.dirty_since orelse s.now();
    if (events.items.len > 0) peers.emitBatch(s, events.items, .{ .peer = p.id, .re = re });
    for (removed.items) |pane| if (pane.host == null) registry.endSession(s, pane.session);
    return switch (outcome) {
        .removed => .{ .removed = removed.items },
        else => outcome,
    };
}

fn modelError(err: model.Error) Outcome {
    return switch (err) {
        error.NotFound => fail(.not_found, "The model has no object with this id."),
        error.DuplicateId => fail(.duplicate_id, "The model already has an object with this id."),
        error.BadRequest => fail(.invalid_args, "The model cannot do this request."),
        error.OutOfMemory => fail(.unavailable, "The server is out of memory."),
    };
}

fn rebalance(s: *const Server, wanted: ?bool) bool {
    return wanted orelse s.model.auto_tiling;
}

fn apply(s: *Server, comptime M: type, mo: *Model, a: std.mem.Allocator, args: M.Args) !Outcome {
    const removes = M.Result == m.RemovedPanes;
    const done: Outcome = if (removes) .{ .removed = &.{} } else .ok;
    switch (M) {
        m.ProjectCreate => mo.addProject(.{
            .id = args.id,
            .name = args.name,
            .path = args.path,
            .color = args.color,
            .created_at = args.created_at,
            .parent = args.parent,
            .kind = args.kind,
            .sort_order = nextSortOrder(mo, args.parent),
        }) catch |err| return modelError(err),
        m.ProjectSet => {
            const p = mo.findProject(args.id) orelse return modelError(error.NotFound);
            if (args.path) |path| if (p.kind == .group and path.len != 0) return modelError(error.BadRequest);
            if (args.parent) |parent| mo.setParent(args.id, parent) catch |err| return modelError(err);
            const al = mo.arena.allocator();
            if (args.name) |n| p.name = try al.dupe(u8, n);
            if (args.path) |path| p.path = try al.dupe(u8, path);
            if (args.color) |c| p.color = if (c.len == 0) null else try al.dupe(u8, c);
        },
        m.ProjectReorder => mo.reorderProjects(args.parent, args.ids) catch |err| return modelError(err),
        m.ProjectRemove => _ = mo.removeProject(args.id) catch |err| return modelError(err),
        m.WorkspaceCreate => mo.addWorkspace(args.id, args.kind) catch |err| return modelError(err),
        m.WorkspaceRemove => {
            const ws = mo.findWorkspace(args.id) orelse return modelError(error.NotFound);
            if (ws.kind == .project) return modelError(error.BadRequest);
            while (ws.tabs.len > 0) _ = mo.closeTab(ws.tabs[0].id) catch |err| return modelError(err);
            var kept: std.ArrayList(model.Workspace) = .empty;
            for (mo.data.workspaces) |w| if (!w.id.eql(args.id)) try kept.append(mo.arena.allocator(), w);
            mo.data.workspaces = kept.items;
        },
        m.TabCreate => mo.createTab(args.workspace, args.id, if (args.index) |i| @as(usize, i) else null, args.root, args.title, args.focus) catch |err| return modelError(err),
        m.TabClose => _ = mo.closeTab(args.id) catch |err| return modelError(err),
        m.TabSet => mo.renameTab(args.id, args.title) catch |err| return modelError(err),
        m.TabSelect => mo.selectTab(args.workspace, args.id) catch |err| return modelError(err),
        m.TabReorder => {
            const ws = mo.workspaceOfTab(args.id) orelse return modelError(error.NotFound);
            if (!ws.id.eql(args.workspace)) return modelError(error.NotFound);
            mo.reorderTab(args.id, args.index) catch |err| return modelError(err);
        },
        m.TabMove => mo.moveTab(args.id, args.to_workspace, if (args.index) |i| @as(usize, i) else null) catch |err| return modelError(err),
        m.TabMerge => mo.mergeTab(args.src, args.dst, args.target_pane, args.zone, args.split_id, rebalance(s, args.rebalance)) catch |err| return modelError(err),
        m.PaneSplit => {
            const dir = splitDir(s, mo, args.target, args.dir) orelse return fail(.invalid_args, "The split has no direction that this server knows.");
            mo.splitPane(args.tab, args.target, args.new, args.split_id, dir, args.position, args.ratio, args.focus, rebalance(s, args.rebalance)) catch |err| return modelError(err);
        },
        m.PaneClose => _ = mo.closePane(args.id, rebalance(s, args.rebalance)) catch |err| return modelError(err),
        m.PaneMove => mo.movePane(args.id, args.dest, args.zone, args.split_id, rebalance(s, args.rebalance)) catch |err| return modelError(err),
        m.PaneSeparate => mo.separatePane(args.id, args.tab_id, args.workspace) catch |err| return modelError(err),
        m.PaneFocus => mo.focusPane(args.id) catch |err| return modelError(err),
        m.PaneZoom => mo.zoom(args.tab, args.pane) catch |err| return modelError(err),
        m.SplitRatio => {
            if (!std.math.isFinite(args.ratio)) return modelError(error.BadRequest);
            mo.setRatio(args.id, args.ratio) catch |err| return modelError(err);
        },
        m.SelectSet => {
            // Check both before a change: a request changes all or nothing.
            const ws: ?*model.Workspace = if (args.tab) |t| (mo.workspaceOfTab(t) orelse return modelError(error.NotFound)) else null;
            if (args.project) |id| {
                const p = mo.findProject(id) orelse return modelError(error.NotFound);
                if (p.kind == .group) return modelError(error.BadRequest);
                if (ws) |w| if (!w.id.eql(.ofProject(id))) return modelError(error.BadRequest);
                mo.selectProject(id) catch |err| return modelError(err);
            }
            if (ws) |w| mo.selectTab(w.id, args.tab.?) catch |err| return modelError(err);
        },
        m.ModelImport => return importModel(s, a, args),
        else => @compileError("not a model request: " ++ M.name),
    }
    return done;
}

/// The `sort_order` after the last child of `parent`.
fn nextSortOrder(mo: *const Model, parent: ?model.ProjectId) i64 {
    var next: i64 = 0;
    for (mo.data.projects) |*p| {
        const at = mo.parentOf(p);
        const same = if (at == null or parent == null or parent.?.isEmpty())
            at == null and (parent == null or parent.?.isEmpty())
        else
            at.?.eql(parent.?);
        if (same) next = @max(next, p.sort_order + 1);
    }
    return next;
}

/// The direction of a new split. `auto` reads the size of the target's
/// session: a cell is about twice as high as it is wide, as v1 compares
/// the pixel size (`SplitDirection.auto`).
fn splitDir(s: *Server, mo: *const Model, target: model.PaneId, dir: m.SplitDir) ?tree.Dir {
    return switch (dir) {
        .horizontal => .horizontal,
        .vertical => .vertical,
        .unknown => null,
        .auto => {
            const pane = mo.findPane(target) orelse return .horizontal;
            const e = registry.findEntry(s, pane.session) orelse return .horizontal;
            const st = e.state orelse return .horizontal;
            return if (@as(u32, st.rows) * 2 > st.cols) .vertical else .horizontal;
        },
    };
}

/// `model.import`: the client's model in place of this one, once.
fn importModel(s: *Server, a: std.mem.Allocator, args: m.ModelImport.Args) !Outcome {
    const st = &s.model;
    if (st.model.?.data.imported_v1) return fail(.refused, "The model already holds an import.");
    // Through JSON: the file's reader copies, validates and refuses a newer
    // version, so an import is checked as `model.json` is.
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(args.model, .{}, &json.writer);
    var fault: model.Fault = .{};
    var fresh = file.parse(s.gpa, json.written(), &fault) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return fail(.invalid_args, try std.fmt.allocPrint(a, "The model is not valid: {s}", .{fault.text()})),
        error.NewerVersion => return fail(.invalid_args, "The model has a version that this server does not know."),
        error.Syntax => return fail(.invalid_args, "The model does not decode."),
    };
    fresh.data.imported_v1 = true;
    // The panes of the old model stay in the scratch snapshot, which holds
    // copies: the old arena can go.
    st.model.?.deinit();
    st.model = fresh;
    std.log.info("server: model imported from {s}: {d} projects", .{ args.source, fresh.data.projects.len });
    return .ok;
}

// ── The compare ─────────────────────────────────────────────────────────────

/// Each object of the model, encoded, by id. Copies, so the model can
/// change (or go) after it.
const Snapshot = struct {
    projects: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Parent id ("" for the top level) to the encoded order of its children.
    orders: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Workspace id to its encoded `TabOrder`.
    workspaces: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    workspace_kinds: std.StringHashMapUnmanaged(model.Kind) = .empty,
    /// Tab id to its encoded `TabChanged`.
    tabs: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    tab_workspaces: std.StringHashMapUnmanaged([]const u8) = .empty,
    panes: std.StringArrayHashMapUnmanaged(m.RemovedPane) = .empty,
    selection: []const u8 = "",

    fn take(a: std.mem.Allocator, mo: *const Model) !Snapshot {
        var snap: Snapshot = .{};
        for (mo.data.projects) |*p| {
            try snap.projects.put(a, try a.dupe(u8, p.id.text), try msgpack.encodeAlloc(a, m.ProjectChanged{ .project = p.* }));
        }
        // The order of each parent's children.
        var parents: std.StringArrayHashMapUnmanaged(void) = .empty;
        try parents.put(a, "", {});
        for (mo.data.projects) |*p| if (p.kind == .group) try parents.put(a, try a.dupe(u8, p.id.text), {});
        for (parents.keys()) |parent| {
            const ids = try childOrder(a, mo, parent);
            const value: m.ProjectOrder = .{ .parent = if (parent.len == 0) null else .of(parent), .ids = ids };
            try snap.orders.put(a, parent, try msgpack.encodeAlloc(a, value));
        }
        for (mo.data.workspaces) |*w| {
            const ids = try a.alloc(model.TabId, w.tabs.len);
            for (w.tabs, ids) |t, *id| id.* = t.id;
            const key = try a.dupe(u8, w.id.text);
            try snap.workspaces.put(a, key, try msgpack.encodeAlloc(a, m.TabOrder{ .workspace = w.id, .kind = w.kind, .ids = ids, .active_tab = w.active_tab }));
            try snap.workspace_kinds.put(a, key, w.kind);
            for (w.tabs) |*t| {
                const tkey = try a.dupe(u8, t.id.text);
                try snap.tabs.put(a, tkey, try msgpack.encodeAlloc(a, m.TabChanged{ .workspace = w.id, .tab = t.*, .zoomed = mo.zoomedPane(t.id) }));
                try snap.tab_workspaces.put(a, tkey, key);
                var list: std.ArrayList(*const model.Pane) = .empty;
                try tree.collectPanes(a, &t.root, &list);
                for (list.items) |pane| try snap.panes.put(a, try a.dupe(u8, pane.id.text), .{
                    .id = .of(try a.dupe(u8, pane.id.text)),
                    .session = try a.dupe(u8, pane.session),
                    .host = if (pane.host) |h| try a.dupe(u8, h) else null,
                });
            }
        }
        snap.selection = try msgpack.encodeAlloc(a, m.SelectionChanged{ .active_project = mo.data.selection.active_project });
        return snap;
    }

    fn childOrder(a: std.mem.Allocator, mo: *const Model, parent: []const u8) ![]const model.ProjectId {
        var list: std.ArrayList(*const model.Project) = .empty;
        for (mo.data.projects) |*p| {
            const at = mo.parentOf(p);
            const same = if (at) |x| std.mem.eql(u8, x.text, parent) else parent.len == 0;
            if (same) try list.append(a, p);
        }
        std.mem.sort(*const model.Project, list.items, {}, struct {
            fn less(_: void, x: *const model.Project, y: *const model.Project) bool {
                return x.sort_order < y.sort_order;
            }
        }.less);
        const ids = try a.alloc(model.ProjectId, list.items.len);
        for (list.items, ids) |p, *id| id.* = .of(try a.dupe(u8, p.id.text));
        return ids;
    }
};

fn event(a: std.mem.Allocator, comptime E: type, bytes: []const u8) !m.Event {
    return .{ .e = E.name, .a = .{ .bytes = try a.dupe(u8, bytes) } };
}

fn eventOf(a: std.mem.Allocator, value: anytype) !m.Event {
    const E = @TypeOf(value);
    return .{ .e = E.name, .a = .{ .bytes = try msgpack.encodeAlloc(a, value) } };
}

/// The events from `before` to `after`, in an order that a client can apply
/// one by one: what is made or changed first, then what went. `removed`
/// gets each pane that left the model (none for an import: its old panes
/// are not the user's to end).
fn diff(
    a: std.mem.Allocator,
    before: *const Snapshot,
    after: *const Snapshot,
    events: *std.ArrayList(m.Event),
    removed: *std.ArrayList(m.RemovedPane),
    end_panes: bool,
) !void {
    for (after.projects.keys(), after.projects.values()) |id, bytes| {
        const old = before.projects.get(id);
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.ProjectChanged, bytes));
    }
    for (after.orders.keys(), after.orders.values()) |id, bytes| {
        const old = before.orders.get(id);
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.ProjectOrder, bytes));
    }
    for (after.workspaces.keys(), after.workspaces.values()) |id, bytes| {
        const old = before.workspaces.get(id);
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.TabOrder, bytes));
    }
    for (after.tabs.keys(), after.tabs.values()) |id, bytes| {
        const old = before.tabs.get(id);
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.TabChanged, bytes));
    }
    for (before.tabs.keys()) |id| if (!after.tabs.contains(id)) {
        const ws = before.tab_workspaces.get(id).?;
        // The tab of a workspace that went with it: `workspace.remove` or
        // `project.remove` says it.
        if (!after.workspaces.contains(ws)) continue;
        try events.append(a, try eventOf(a, m.TabRemoved{ .workspace = .of(ws), .id = .of(id) }));
    };
    for (before.workspaces.keys()) |id| if (!after.workspaces.contains(id)) {
        if (before.workspace_kinds.get(id).? == .project) continue;
        try events.append(a, try eventOf(a, m.WorkspaceRemoved{ .id = .of(id) }));
    };
    for (before.projects.keys()) |id| if (!after.projects.contains(id)) {
        try events.append(a, try eventOf(a, m.ProjectRemoved{ .id = .of(id) }));
    };
    if (!std.mem.eql(u8, before.selection, after.selection)) try events.append(a, try event(a, m.SelectionChanged, after.selection));
    if (!end_panes) return;
    for (before.panes.keys(), before.panes.values()) |id, pane| if (!after.panes.contains(id)) {
        try removed.append(a, pane);
        try events.append(a, try eventOf(a, m.PaneRemoved{ .id = pane.id, .session = pane.session, .host = pane.host }));
    };
}

// ── The ring of request ids ─────────────────────────────────────────────────

fn findAnswer(s: *Server, client: u64, re: u64, method: []const u8) ?[]const u8 {
    for (s.model.answers.items) |ans| {
        if (ans.client == client and ans.re == re and std.mem.eql(u8, ans.method, method)) return ans.body;
    }
    return null;
}

fn keepAnswer(s: *Server, client: u64, re: u64, method: []const u8, body: []const u8) void {
    const st = &s.model;
    const copy = s.gpa.dupe(u8, body) catch return;
    st.answers.append(s.gpa, .{ .client = client, .re = re, .method = method, .body = copy }) catch {
        s.gpa.free(copy);
        return;
    };
    while (st.answers.items.len > request_ring) s.gpa.free(st.answers.orderedRemove(0).body);
}
