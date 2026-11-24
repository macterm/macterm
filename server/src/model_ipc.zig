//! The model on the server's socket (design/010 §2, §3): `state.subscribe`,
//! the model requests and their events, the ring of request ids, and
//! `model.json`.
//!
//! The events come from a compare: the server encodes each object of the
//! model before and after a request, and sends an event for each one that
//! changed. So the events always match the model.

const std = @import("std");
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
    /// The hash of the request's arguments: the same id with other
    /// arguments is a new request.
    args: u64,
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
    std.log.info("server: model from {s}: {d} projects", .{ st.path.?, st.model.?.data.projects.len });
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
        // Try again after the delay.
        st.dirty_since = s.now();
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
    registry.listRead(s);
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
pub fn call(s: *Server, comptime M: type, p: *Peer, re: u64, raw: ?msgpack.Raw, args: M.Args) void {
    const hash = std.hash.Wyhash.hash(0, if (raw) |r| r.bytes else "");
    if (findAnswer(s, p.client, re, M.name, hash)) |body| {
        std.log.info("server: {s} sent again, answered from the ring", .{M.name});
        return peers.sendBody(s, p, body);
    }
    var scratch: std.heap.ArenaAllocator = .init(s.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    const outcome: Outcome = if (s.model.model == null)
        fail(.unavailable, "This server has no model.")
    else if (s.model.readonly and M != m.ModelOptions)
        fail(.model_readonly, "The model file did not read. The model is read-only.")
    else
        change(s, M, a, p, re, args) catch fail(.unavailable, "The server is out of memory.");

    var out: std.Io.Writer.Allocating = .init(s.gpa);
    defer out.deinit();
    const encoded = switch (outcome) {
        .ok => m.encodeResult(&out.writer, re, M, .{}),
        .removed => |panes| if (@hasField(M.Result, "panes"))
            m.encodeResult(&out.writer, re, M, .{ .panes = panes })
        else
            unreachable,
        .err => |e| msgpack.encode(&out.writer, m.Response{ .re = re, .err = .{ .code = @tagName(e.code), .message = e.message } }),
    };
    encoded catch return peers.replyError(s, p.id, re, .unavailable, "The server is out of memory.");
    peers.sendBody(s, p, out.written());
    // A drag sends many ratios, and each one is complete in itself: they
    // would push the answers that matter out of the ring. A failure for
    // lack of memory can work when sent again.
    const transient = outcome == .err and outcome.err.code == .unavailable;
    if (M != m.SplitRatio and !transient) keepAnswer(s, p.client, re, M.name, hash, out.written());
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
    try diff(a, &before, &after, &events, &removed, M != m.ModelImport and M != m.ModelReplace);
    // The app sends a replace after each save, mostly with no change: such
    // a replace writes no file.
    if (M != m.ModelReplace or events.items.len > 0) s.model.dirty_since = s.model.dirty_since orelse s.now();
    if (events.items.len > 0) peers.emitBatch(s, events.items, .{ .peer = p.id, .re = re });
    // A session that a pane of the model still names stays (fail closed).
    for (removed.items) |pane| if (pane.host == null and !after.sessions.contains(pane.session)) registry.endSession(s, pane.session);
    return switch (outcome) {
        .removed => .{ .removed = removed.items },
        else => outcome,
    };
}

fn modelError(err: model.Error) Outcome {
    return switch (err) {
        error.NotFound => fail(.not_found, "No object has this id."),
        error.DuplicateId => fail(.duplicate_id, "An object has this id."),
        error.BadRequest => fail(.invalid_args, "The model refuses this change."),
        error.Refused => fail(.refused, "The project does not allow this change."),
        error.OutOfMemory => fail(.unavailable, "The server is out of memory."),
    };
}

fn rebalance(s: *const Server, wanted: ?bool) bool {
    return wanted orelse s.model.auto_tiling;
}

fn apply(s: *Server, comptime M: type, mo: *Model, a: std.mem.Allocator, args: M.Args) !Outcome {
    const removes = @hasField(M.Result, "panes");
    const done: Outcome = if (removes) .{ .removed = &.{} } else .ok;
    switch (M) {
        m.ProjectCreate => mo.addProject(.{
            .id = args.id,
            .name = args.name,
            .path = args.path,
            .color = args.color,
            .created_at = args.created_at,
            .parent = args.parent,
            .sort_order = nextSortOrder(mo, args.parent),
            .sidebar = args.sidebar,
            .single_tab = args.single_tab,
            .removable = args.removable,
            .alias = args.alias,
        }) catch |err| return modelError(err),
        m.ProjectSet => {
            const p = mo.findProject(args.id) orelse return modelError(error.NotFound);
            if (args.parent) |parent| mo.setParent(args.id, parent) catch |err| return modelError(err);
            const al = mo.arena.allocator();
            if (args.name) |n| p.name = try al.dupe(u8, n);
            if (args.path) |path| p.path = try al.dupe(u8, path);
            if (args.color) |c| p.color = if (c.len == 0) null else try al.dupe(u8, c);
        },
        m.ProjectReorder => mo.reorderProjects(args.parent, args.ids) catch |err| return modelError(err),
        m.ProjectRemove => _ = mo.removeProject(args.id) catch |err| return modelError(err),
        m.TabCreate => mo.createTab(args.project, args.id, if (args.index) |i| @as(usize, i) else null, args.root, args.title, args.focus) catch |err| return modelError(err),
        m.TabClose => _ = mo.closeTab(args.id) catch |err| return modelError(err),
        m.TabSet => mo.renameTab(args.id, args.title) catch |err| return modelError(err),
        m.TabSelect => mo.selectTab(args.project, args.id) catch |err| return modelError(err),
        m.TabReorder => {
            const p = mo.projectOfTab(args.id) orelse return modelError(error.NotFound);
            if (!p.id.eql(args.project)) return modelError(error.NotFound);
            mo.reorderTab(args.id, args.index) catch |err| return modelError(err);
        },
        m.TabMove => mo.moveTab(args.id, args.to_project, if (args.index) |i| @as(usize, i) else null) catch |err| return modelError(err),
        m.TabMerge => mo.mergeTab(args.src, args.dst, args.target_pane, args.zone, args.split_id, rebalance(s, args.rebalance)) catch |err| return modelError(err),
        m.PaneSplit => {
            const dir = splitDir(s, mo, args.target, args.dir) orelse return fail(.invalid_args, "Unknown split direction.");
            mo.splitPane(args.tab, args.target, args.new, args.split_id, dir, args.position, args.ratio, args.focus, rebalance(s, args.rebalance)) catch |err| return modelError(err);
        },
        m.PaneClose => _ = mo.closePane(args.id, rebalance(s, args.rebalance)) catch |err| return modelError(err),
        m.PaneMove => mo.movePane(args.id, args.dest, args.zone, args.split_id, rebalance(s, args.rebalance)) catch |err| return modelError(err),
        m.PaneSeparate => mo.separatePane(args.id, args.tab_id, args.project) catch |err| return modelError(err),
        m.PaneFocus => mo.focusPane(args.id) catch |err| return modelError(err),
        m.PaneZoom => mo.zoom(args.tab, args.pane) catch |err| return modelError(err),
        m.SplitRatio => {
            if (!std.math.isFinite(args.ratio)) return modelError(error.BadRequest);
            mo.setRatio(args.id, args.ratio) catch |err| return modelError(err);
        },
        m.SelectSet => {
            // Check both before a change: a request changes all or nothing.
            const holder: ?*model.Project = if (args.tab) |t| (mo.projectOfTab(t) orelse return modelError(error.NotFound)) else null;
            if (args.project) |id| {
                const p = mo.findProject(id) orelse return modelError(error.NotFound);
                if (p.sidebar == .none) return modelError(error.Refused);
                if (holder) |h| if (!h.id.eql(id)) return modelError(error.BadRequest);
                mo.selectProject(id) catch |err| return modelError(err);
            }
            if (holder) |h| mo.selectTab(h.id, args.tab.?) catch |err| return modelError(err);
        },
        m.ModelImport => return putModel(s, a, args.model, .{ .import = args.source }),
        m.ModelReplace => return putModel(s, a, args.model, .replace),
        else => @compileError("not a model request: " ++ M.name),
    }
    return done;
}

/// The `sort_order` after the last `tree` child of `parent`.
fn nextSortOrder(mo: *const Model, parent: ?model.ProjectId) i64 {
    var next: i64 = 0;
    for (mo.data.projects) |*p| {
        if (p.sidebar != .tree) continue;
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

/// `model.import` (once, and the model gets `imported_v1`) and
/// `model.replace` (the shadow stage, design/010 §9 step 3): the client's
/// model in place of this one. Both are refused once the model has
/// `imported_v1`.
fn putModel(s: *Server, a: std.mem.Allocator, data: model.ModelData, how: union(enum) { import: []const u8, replace }) !Outcome {
    const st = &s.model;
    if (st.model.?.data.imported_v1) return fail(.refused, "The model has an import.");
    // Through JSON: the file's reader copies, validates and refuses a newer
    // version, so the model is checked as `model.json` is.
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(data, .{}, &json.writer);
    var fault: model.Fault = .{};
    var fresh = file.parse(s.gpa, json.written(), &fault) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return fail(.invalid_args, try std.fmt.allocPrint(a, "The model is not valid: {s}", .{fault.text()})),
        error.NewerVersion => return fail(.invalid_args, "The model version is newer than this server."),
        error.Syntax => return fail(.invalid_args, "The model does not decode."),
    };
    fresh.data.imported_v1 = how == .import;
    // The panes of the old model stay in the scratch snapshot, which holds
    // copies: the old arena can go.
    st.model.?.deinit();
    st.model = fresh;
    switch (how) {
        .import => |source| std.log.info("server: model imported from {s}: {d} projects", .{ source, fresh.data.projects.len }),
        .replace => {},
    }
    return .ok;
}

// ── The compare ─────────────────────────────────────────────────────────────

/// Each object of the model, encoded, by id. Copies, so the model can
/// change (or go) after it.
const Snapshot = struct {
    projects: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Parent id ("" for the top level) to the encoded order of its children.
    /// Every project is a parent.
    orders: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// The parents in `orders` that hold no project.
    empty_orders: std.StringHashMapUnmanaged(void) = .empty,
    /// Project id to its encoded `TabOrder`.
    tab_orders: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// The projects in `tab_orders` that hold no tab.
    no_tabs: std.StringHashMapUnmanaged(void) = .empty,
    /// Tab id to its encoded `TabChanged`.
    tabs: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    tab_projects: std.StringHashMapUnmanaged([]const u8) = .empty,
    panes: std.StringArrayHashMapUnmanaged(m.RemovedPane) = .empty,
    /// The sessions of the local panes.
    sessions: std.StringHashMapUnmanaged(void) = .empty,
    selection: []const u8 = "",

    fn take(a: std.mem.Allocator, mo: *const Model) !Snapshot {
        var snap: Snapshot = .{};
        for (mo.data.projects) |*p| {
            try snap.projects.put(a, try a.dupe(u8, p.id.text), try msgpack.encodeAlloc(a, m.ProjectChanged{ .project = .of(p.*) }));
        }
        // The order of each parent's children. Only a `tree` project is a
        // parent or a child.
        var parents: std.StringArrayHashMapUnmanaged(void) = .empty;
        try parents.put(a, "", {});
        for (mo.data.projects) |*p| if (p.sidebar == .tree) try parents.put(a, try a.dupe(u8, p.id.text), {});
        for (parents.keys()) |parent| {
            const ids = try childOrder(a, mo, parent);
            const value: m.ProjectOrder = .{ .parent = if (parent.len == 0) null else .of(parent), .ids = ids };
            try snap.orders.put(a, parent, try msgpack.encodeAlloc(a, value));
            if (ids.len == 0) try snap.empty_orders.put(a, parent, {});
        }
        for (mo.data.projects) |*p| {
            const ids = try a.alloc(model.TabId, p.tabs.len);
            for (p.tabs, ids) |t, *id| id.* = t.id;
            const key = try a.dupe(u8, p.id.text);
            try snap.tab_orders.put(a, key, try msgpack.encodeAlloc(a, m.TabOrder{ .project = p.id, .ids = ids, .active_tab = p.active_tab }));
            if (p.tabs.len == 0) try snap.no_tabs.put(a, key, {});
            for (p.tabs) |*t| {
                const tkey = try a.dupe(u8, t.id.text);
                try snap.tabs.put(a, tkey, try msgpack.encodeAlloc(a, m.TabChanged{ .project = p.id, .tab = t.*, .zoomed = mo.zoomedPane(t.id) }));
                try snap.tab_projects.put(a, tkey, key);
                var list: std.ArrayList(*const model.Pane) = .empty;
                try tree.collectPanes(a, &t.root, &list);
                for (list.items) |pane| {
                    const session = try a.dupe(u8, pane.session);
                    try snap.panes.put(a, try a.dupe(u8, pane.id.text), .{
                        .id = .of(try a.dupe(u8, pane.id.text)),
                        .session = session,
                        .host = if (pane.host) |h| try a.dupe(u8, h) else null,
                    });
                    if (pane.host == null) try snap.sessions.put(a, session, {});
                }
            }
        }
        snap.selection = try msgpack.encodeAlloc(a, m.SelectionChanged{ .active_project = mo.data.selection.active_project });
        return snap;
    }

    fn childOrder(a: std.mem.Allocator, mo: *const Model, parent: []const u8) ![]const model.ProjectId {
        var list: std.ArrayList(*const model.Project) = .empty;
        for (mo.data.projects) |*p| {
            if (p.sidebar != .tree) continue;
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
        // A new project holds no project yet: its `project.set` says enough.
        if (old == null and after.empty_orders.contains(id)) continue;
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.ProjectOrder, bytes));
    }
    for (after.tab_orders.keys(), after.tab_orders.values()) |id, bytes| {
        const old = before.tab_orders.get(id);
        // A new project holds no tab yet: its `project.set` says enough.
        if (old == null and after.no_tabs.contains(id)) continue;
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.TabOrder, bytes));
    }
    for (after.tabs.keys(), after.tabs.values()) |id, bytes| {
        const old = before.tabs.get(id);
        if (old == null or !std.mem.eql(u8, old.?, bytes)) try events.append(a, try event(a, m.TabChanged, bytes));
    }
    for (before.tabs.keys()) |id| if (!after.tabs.contains(id)) {
        const project = before.tab_projects.get(id).?;
        // The tab of a project that went with it: `project.remove` says it.
        if (!after.projects.contains(project)) continue;
        try events.append(a, try eventOf(a, m.TabRemoved{ .project = .of(project), .id = .of(id) }));
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

fn findAnswer(s: *Server, client: u64, re: u64, method: []const u8, args: u64) ?[]const u8 {
    for (s.model.answers.items) |ans| {
        if (ans.client == client and ans.re == re and ans.args == args and std.mem.eql(u8, ans.method, method)) return ans.body;
    }
    return null;
}

fn keepAnswer(s: *Server, client: u64, re: u64, method: []const u8, args: u64, body: []const u8) void {
    const st = &s.model;
    const copy = s.gpa.dupe(u8, body) catch return;
    st.answers.append(s.gpa, .{ .client = client, .re = re, .method = method, .args = args, .body = copy }) catch {
        s.gpa.free(copy);
        return;
    };
    while (st.answers.items.len > request_ring) s.gpa.free(st.answers.orderedRemove(0).body);
}
