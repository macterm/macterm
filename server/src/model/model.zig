//! The model on the Mac server (design/010 §1, §11): projects, their tabs
//! and the split trees of the tabs, and the operations that change them.
//!
//! `ModelData` is what goes to disk (`file.zig`). `Model` is `ModelData` plus
//! the state that stays in memory: the zoomed pane of each tab, the focus
//! history of each tab, and the tab history of each project.
//!
//! **Every operation checks first and changes after.** An operation that
//! returns an error leaves the model as it was (design/010 §7), so a caller
//! never sees half of a change (out of memory is the one exception). Inputs are copied into the
//! model's arena, so a caller keeps its own memory.
//!
//! A changed list or a removed tab leaves its old memory in the arena, so
//! each edit costs some bytes. `compact` copies the model into a new arena
//! and frees the old one; `file.save` calls it, so the memory follows the
//! size of the model and not the count of edits.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const tree = @import("tree.zig");
const ids = @import("ids.zig");

pub const SplitNode = tree.SplitNode;
pub const Pane = tree.Pane;
pub const ProjectId = ids.ProjectId;
pub const TabId = ids.TabId;
pub const PaneId = ids.PaneId;
pub const SplitId = ids.SplitId;

/// The version of the file that this build writes (design/010 §2). Version
/// 1 had a list of workspaces apart from the projects; `file.zig` still
/// reads it (design/010 §11).
pub const version: u32 = 2;

/// Where the sidebar draws a project (design/010 §11, §2).
pub const ProjectSidebar = enum {
    /// A row of the project tree.
    tree,
    /// Its tabs are rows above the tree, with no project row (Pinned).
    top,
    /// Its tabs are rows below the tree, with no project row (Scratch Tabs).
    bottom,
    /// No window draws it (the quick terminal, a widget).
    none,
};

pub const Tab = struct {
    id: TabId,
    custom_title: ?[]const u8 = null,
    root: SplitNode,
    focused: ?PaneId = null,
};

/// One project: a row of the tree, or a hidden project (Pinned, Scratch
/// Tabs, the quick terminal, a widget). The capability fields (`sidebar`,
/// `single_tab`, `removable`, `alias`) are set by `project.create` and never
/// change. The rules that hold between projects are in `validate`.
pub const Project = struct {
    id: ProjectId,
    name: []const u8,
    /// A local path, or `user@host:dir`. Can be empty (design/013, "Ethan
    /// chose B" §1).
    path: []const u8,
    color: ?[]const u8 = null,
    /// Orders the children of one parent.
    sort_order: i64 = 0,
    /// Unix time in milliseconds.
    created_at: i64 = 0,
    /// The project that holds this one. Null or empty is the top level.
    /// A project can hold tabs and projects at the same time. `Model.parentOf`
    /// reads an unknown parent as the top level. The file stays valid
    /// (design/013, "Ethan chose B" §1).
    parent: ?ProjectId = null,
    sidebar: ProjectSidebar = .tree,
    /// The project holds at most one tab.
    single_tab: bool = false,
    /// `project.remove` may remove it.
    removable: bool = true,
    /// The one short word that finds this project (`pinned`, `scratch`,
    /// `quick`). Unique in the model.
    alias: ?[]const u8 = null,
    tabs: []Tab = &.{},
    active_tab: ?TabId = null,

    /// Reads a project of `model.json`, and drops the `kind` that an older
    /// build wrote: the parser refuses an unknown key. Only the token
    /// parsers call it (`parseFromSlice`), not `parseFromValue`.
    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Project {
        const InFile = struct {
            id: ProjectId,
            name: []const u8,
            path: []const u8,
            color: ?[]const u8 = null,
            sort_order: i64 = 0,
            created_at: i64 = 0,
            parent: ?ProjectId = null,
            sidebar: ProjectSidebar = .tree,
            single_tab: bool = false,
            removable: bool = true,
            alias: ?[]const u8 = null,
            tabs: []Tab = &.{},
            active_tab: ?TabId = null,
            kind: ?enum { project, group } = null,
        };
        const f = try std.json.innerParse(InFile, a, source, options);
        return .{
            .id = f.id,
            .name = f.name,
            .path = f.path,
            .color = f.color,
            .sort_order = f.sort_order,
            .created_at = f.created_at,
            .parent = f.parent,
            .sidebar = f.sidebar,
            .single_tab = f.single_tab,
            .removable = f.removable,
            .alias = f.alias,
            .tabs = f.tabs,
            .active_tab = f.active_tab,
        };
    }

    fn hasTab(p: *const Project, id: TabId) bool {
        for (p.tabs) |t| if (t.id.eql(id)) return true;
        return false;
    }

    fn tabIndex(p: *const Project, id: TabId) usize {
        for (p.tabs, 0..) |t, i| if (t.id.eql(id)) return i;
        unreachable;
    }

    /// A `single_tab` project with its one tab.
    fn isFull(p: *const Project) bool {
        return p.single_tab and p.tabs.len > 0;
    }
};

pub const Selection = struct {
    active_project: ?ProjectId = null,
};

/// What `model.json` holds. The protocol carries it too (`state.subscribe`,
/// `model.import`), so its name is unique in the schema: Swift has its own
/// `Data`.
pub const ModelData = struct {
    version: u32 = version,
    epoch_hint: u64 = 0,
    imported_v1: bool = false,
    projects: []Project = &.{},
    selection: Selection = .{},
};

pub const Error = error{
    OutOfMemory,
    /// An id in the request is not in the model.
    NotFound,
    /// A new id is already in use.
    DuplicateId,
    /// The request cannot be done to this model (the same pane as source and
    /// target, a pane that is not in the tab, ...).
    BadRequest,
    /// A capability field of the project refuses the change: a second tab
    /// in a `single_tab` project, the removal of a project that is not
    /// `removable`, the selection of a project that no window draws.
    Refused,
};

/// The most recent ids first, with no duplicates.
fn Recency(comptime Id: type) type {
    return struct {
        items: std.ArrayList(Id) = .empty,
        limit: usize,

        const Self = @This();

        fn push(r: *Self, a: Allocator, id: Id) Error!void {
            r.remove(id);
            try r.items.insert(a, 0, id);
            if (r.items.items.len > r.limit) r.items.shrinkRetainingCapacity(r.limit);
        }

        fn remove(r: *Self, id: Id) void {
            var i: usize = 0;
            while (i < r.items.items.len) {
                if (r.items.items[i].eql(id)) _ = r.items.orderedRemove(i) else i += 1;
            }
        }

        /// Takes the newest id for which `valid` holds, and drops the ids
        /// that it passed.
        fn popValid(r: *Self, ctx: anytype, valid: anytype) ?Id {
            while (r.items.items.len > 0) {
                const top = r.items.orderedRemove(0);
                if (valid(ctx, top)) return top;
            }
            return null;
        }

        /// A copy in `a`, with every id copied.
        fn clone(r: Self, a: Allocator) Allocator.Error!Self {
            var out: Self = .{ .limit = r.limit };
            try out.items.ensureTotalCapacityPrecise(a, r.items.items.len);
            for (r.items.items) |id| out.items.appendAssumeCapacity(try id.dupe(a));
            return out;
        }
    };
}

pub const pane_history_limit = 20;
pub const tab_history_limit = 50;

pub const CloseResult = enum { pane_removed, tab_closed };

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    data: ModelData = .{},
    /// Tab id to its zoomed pane id.
    zoomed: ids.Map(TabId, PaneId) = .empty,
    /// Tab id to its earlier focus, newest first (design/010 §1).
    pane_history: ids.Map(TabId, Recency(PaneId)) = .empty,
    /// Project id to its earlier active tabs, newest first.
    tab_history: ids.Map(ProjectId, Recency(TabId)) = .empty,

    pub fn init(gpa: Allocator) Model {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(m: *Model) void {
        m.arena.deinit();
        m.* = undefined;
    }

    fn alloc(m: *Model) Allocator {
        return m.arena.allocator();
    }

    /// Copies the model, the zoom and the histories included, into a new
    /// arena, and frees the old one. Every pointer and slice into the model
    /// is invalid after it, the panes that `closeTab` and the other
    /// operations return included. Out of memory leaves the model as it was.
    pub fn compact(m: *Model) Allocator.Error!void {
        var fresh: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        errdefer fresh.deinit();
        const a = fresh.allocator();
        const data = try cloneData(a, m.data);
        var zoomed: ids.Map(TabId, PaneId) = .empty;
        var it = m.zoomed.iterator();
        while (it.next()) |e| try zoomed.put(a, try e.key_ptr.dupe(a), try e.value_ptr.dupe(a));
        const pane_history = try cloneHistory(TabId, PaneId, a, m.pane_history);
        const tab_history = try cloneHistory(ProjectId, TabId, a, m.tab_history);
        m.arena.deinit();
        m.* = .{
            .arena = fresh,
            .data = data,
            .zoomed = zoomed,
            .pane_history = pane_history,
            .tab_history = tab_history,
        };
    }

    // ── Lookup ──────────────────────────────────────────────────────────────

    const TabLoc = struct { project: *Project, index: usize };

    pub fn findProject(m: *const Model, id: ProjectId) ?*Project {
        for (m.data.projects) |*p| if (p.id.eql(id)) return p;
        return null;
    }

    pub fn findAlias(m: *const Model, alias: []const u8) ?*Project {
        for (m.data.projects) |*p| if (p.alias) |x| if (std.mem.eql(u8, x, alias)) return p;
        return null;
    }

    fn locateTab(m: *const Model, tab_id: TabId) ?TabLoc {
        for (m.data.projects) |*p| {
            for (p.tabs, 0..) |t, i| if (t.id.eql(tab_id)) return .{ .project = p, .index = i };
        }
        return null;
    }

    pub fn findTab(m: *const Model, tab_id: TabId) ?*Tab {
        const loc = m.locateTab(tab_id) orelse return null;
        return &loc.project.tabs[loc.index];
    }

    /// The tab that holds pane `pane_id`.
    pub fn findPaneTab(m: *const Model, pane_id: PaneId) ?*Tab {
        for (m.data.projects) |*p| {
            for (p.tabs) |*t| if (tree.contains(&t.root, pane_id)) return t;
        }
        return null;
    }

    pub fn findPane(m: *const Model, pane_id: PaneId) ?*const Pane {
        const t = m.findPaneTab(pane_id) orelse return null;
        return tree.findPane(&t.root, pane_id);
    }

    /// The project that holds tab `tab_id`.
    pub fn projectOfTab(m: *const Model, tab_id: TabId) ?*Project {
        return (m.locateTab(tab_id) orelse return null).project;
    }

    pub fn zoomedPane(m: *const Model, tab_id: TabId) ?PaneId {
        return m.zoomed.get(tab_id);
    }

    /// True when a pane or a split has this id. Panes and splits share one
    /// namespace, as `validate` checks it.
    fn nodeIdInUse(m: *const Model, text: []const u8) bool {
        for (m.data.projects) |*p| {
            for (p.tabs) |*t| if (tree.hasNodeId(&t.root, text)) return true;
        }
        return false;
    }

    /// Fails with `DuplicateId` when a pane or a split of `node` has an id
    /// that the model has, or that the node has twice.
    fn checkFreshIds(m: *Model, node: *const SplitNode, other: ?*const SplitNode) Error!void {
        // Scratch memory: a check leaves nothing in the model's arena.
        var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        defer scratch.deinit();
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        try m.checkFreshIn(scratch.allocator(), node, &seen, other);
    }

    fn checkFreshIn(
        m: *Model,
        a: Allocator,
        node: *const SplitNode,
        seen: *std.StringHashMapUnmanaged(void),
        ignoring: ?*const SplitNode,
    ) Error!void {
        const id = switch (node.*) {
            .pane => |p| p.id.text,
            .split => |s| s.id.text,
        };
        if (id.len == 0) return error.BadRequest;
        const gop = try seen.getOrPut(a, id);
        if (gop.found_existing) return error.DuplicateId;
        // An id that the model has is fresh only inside `ignoring` (the tree
        // that this one replaces).
        if (m.nodeIdInUse(id) and (ignoring == null or !tree.hasNodeId(ignoring.?, id))) {
            return error.DuplicateId;
        }
        switch (node.*) {
            .pane => |p| if (p.session.len == 0) return error.BadRequest,
            .split => |s| {
                if (!(s.ratio > 0 and s.ratio < 1)) return error.BadRequest;
                try m.checkFreshIn(a, &s.first, seen, ignoring);
                try m.checkFreshIn(a, &s.second, seen, ignoring);
            },
        }
    }

    // ── Projects ────────────────────────────────────────────────────────────

    /// Adds a project with no tabs (`p.tabs` and `p.active_tab` are not
    /// read). Its capability fields must keep the rules of `validate`: a
    /// unique `alias`, and a parent only for a `tree` project, in a `tree`
    /// project.
    pub fn addProject(m: *Model, p: Project) Error!void {
        const a = m.alloc();
        if (p.id.isEmpty()) return error.BadRequest;
        if (m.findProject(p.id) != null) return error.DuplicateId;
        if (p.alias) |x| {
            if (x.len == 0) return error.BadRequest;
            if (m.findAlias(x) != null) return error.DuplicateId;
        }
        const parent = topLevelIfEmpty(p.parent);
        if (parent) |g| {
            if (p.sidebar != .tree) return error.BadRequest;
            const holder = m.findProject(g) orelse return error.BadRequest;
            if (holder.sidebar != .tree) return error.BadRequest;
        }
        const copy: Project = .{
            .id = try p.id.dupe(a),
            .name = try a.dupe(u8, p.name),
            .path = try a.dupe(u8, p.path),
            .color = try dupeText(a, p.color),
            .sort_order = p.sort_order,
            .created_at = p.created_at,
            .parent = try dupeId(a, parent),
            .sidebar = p.sidebar,
            .single_tab = p.single_tab,
            .removable = p.removable,
            .alias = try dupeText(a, p.alias),
        };
        m.data.projects = try appendOne(Project, a, m.data.projects, copy);
    }

    /// The project that holds `p`, or null for the top level. An unknown
    /// parent reads as the top level. When `p` is on a loop of parents, `p`
    /// reads as the top level.
    pub fn parentOf(m: *const Model, p: *const Project) ?ProjectId {
        return parentIn(m.data.projects, p);
    }

    /// Moves a `tree` project into the `tree` project `parent`, or to the
    /// top level when null. A project cannot go into itself or into a
    /// project that it holds.
    pub fn setParent(m: *Model, id: ProjectId, parent: ?ProjectId) Error!void {
        const a = m.alloc();
        const p = m.findProject(id) orelse return error.NotFound;
        const wanted = topLevelIfEmpty(parent);
        if (wanted) |g| {
            if (p.sidebar != .tree) return error.BadRequest;
            const holder = m.findProject(g) orelse return error.BadRequest;
            if (holder.sidebar != .tree) return error.BadRequest;
            // The parents as the file has them, so that a loop is seen too.
            var at: ?ProjectId = g;
            var steps: usize = 0;
            while (at) |x| : (steps += 1) {
                if (x.eql(id)) return error.BadRequest;
                if (steps > m.data.projects.len) break;
                const up = m.findProject(x) orelse break;
                at = topLevelIfEmpty(up.parent);
            }
        }
        p.parent = try dupeId(a, wanted);
    }

    /// Sets the order of the `tree` children of `parent` (the top level
    /// when null). `order` must hold each child once, and nothing else. A
    /// hidden project has no place in an order.
    pub fn reorderProjects(m: *Model, parent: ?ProjectId, order: []const ProjectId) Error!void {
        const wanted = topLevelIfEmpty(parent);
        if (wanted) |g| {
            if (m.findProject(g) == null) return error.NotFound;
        }
        var children: usize = 0;
        for (m.data.projects) |*p| {
            if (p.sidebar == .tree and sameParent(m.parentOf(p), wanted)) children += 1;
        }
        if (order.len != children) return error.BadRequest;
        for (order, 0..) |id, i| {
            const p = m.findProject(id) orelse return error.NotFound;
            if (p.sidebar != .tree or !sameParent(m.parentOf(p), wanted)) return error.BadRequest;
            for (order[0..i]) |earlier| if (earlier.eql(id)) return error.BadRequest;
        }
        for (order, 0..) |id, i| m.findProject(id).?.sort_order = @intCast(i);
    }

    fn sameParent(x: ?ProjectId, y: ?ProjectId) bool {
        if (x == null or y == null) return x == null and y == null;
        return x.?.eql(y.?);
    }

    /// Removes a project with its tabs. A project that holds projects is
    /// refused (`BadRequest`): the caller moves or removes them first. A
    /// project that is not `removable` is `Refused`. Returns the panes that
    /// left the model (the caller ends their sessions).
    pub fn removeProject(m: *Model, id: ProjectId) Error![]const Pane {
        const a = m.alloc();
        const pi = indexOf(Project, m.data.projects, id) orelse return error.NotFound;
        if (!m.data.projects[pi].removable) return error.Refused;
        for (m.data.projects) |*p| {
            if (m.parentOf(p)) |g| if (g.eql(id)) return error.BadRequest;
        }
        var gone: std.ArrayList(Pane) = .empty;
        for (m.data.projects[pi].tabs) |*t| try appendPanes(a, &t.root, &gone);
        const projects = try removeAt(Project, a, m.data.projects, pi);
        for (m.data.projects[pi].tabs) |t| m.forgetTab(t.id);
        _ = m.tab_history.remove(id);
        m.data.projects = projects;
        if (m.data.selection.active_project) |sel| {
            if (sel.eql(id)) m.data.selection.active_project = null;
        }
        return gone.items;
    }

    /// A project with `sidebar: none` cannot be selected (`Refused`): no
    /// window draws it.
    pub fn selectProject(m: *Model, id: ?ProjectId) Error!void {
        const a = m.alloc();
        if (id) |wanted| {
            const p = m.findProject(wanted) orelse return error.NotFound;
            if (p.sidebar == .none) return error.Refused;
            m.data.selection.active_project = try wanted.dupe(a);
        } else {
            m.data.selection.active_project = null;
        }
    }

    // ── Tabs ────────────────────────────────────────────────────────────────

    /// Makes a tab in project `project_id` at `index` (at the end when null
    /// or too big). `root` is copied. The tab's focus is the first pane.
    /// With `focus`, or when the project has no active tab, it becomes the
    /// active tab. A full `single_tab` project is `Refused`.
    pub fn createTab(
        m: *Model,
        project_id: ProjectId,
        tab_id: TabId,
        index: ?usize,
        root: SplitNode,
        title: ?[]const u8,
        focus: bool,
    ) Error!void {
        const a = m.alloc();
        const p = m.findProject(project_id) orelse return error.NotFound;
        if (tab_id.isEmpty()) return error.BadRequest;
        if (m.locateTab(tab_id) != null) return error.DuplicateId;
        if (p.isFull()) return error.Refused;
        try m.checkFreshIds(&root, null);
        var copy = try tree.clone(a, root);
        const tab: Tab = .{
            .id = try tab_id.dupe(a),
            .custom_title = if (title) |t| try a.dupe(u8, t) else null,
            .root = copy,
            .focused = tree.firstPane(&copy).id,
        };
        const at = @min(index orelse p.tabs.len, p.tabs.len);
        p.tabs = try insertAt(Tab, a, p.tabs, at, tab);
        if (focus or p.active_tab == null) try m.activate(p, tab.id);
    }

    /// Closes a tab. Returns its panes: they left the model.
    pub fn closeTab(m: *Model, tab_id: TabId) Error![]const Pane {
        const a = m.alloc();
        const loc = m.locateTab(tab_id) orelse return error.NotFound;
        var gone: std.ArrayList(Pane) = .empty;
        try appendPanes(a, &loc.project.tabs[loc.index].root, &gone);
        try m.detachTab(loc);
        return gone.items;
    }

    /// Takes the tab out of its project and picks the next active tab (the
    /// newest of the history that is still there, else the last tab).
    fn detachTab(m: *Model, loc: TabLoc) Error!void {
        const a = m.alloc();
        const p = loc.project;
        const id = p.tabs[loc.index].id;
        p.tabs = try removeAt(Tab, a, p.tabs, loc.index);
        m.forgetTab(id);
        if (m.tab_history.getPtr(p.id)) |h| h.remove(id);
        const was_active = p.active_tab != null and p.active_tab.?.eql(id);
        if (!was_active) return;
        if (m.tab_history.getPtr(p.id)) |h| {
            if (h.popValid(p, projectHasTab)) |prev| {
                p.active_tab = prev;
                return;
            }
        }
        p.active_tab = if (p.tabs.len > 0) p.tabs[p.tabs.len - 1].id else null;
    }

    fn projectHasTab(p: *const Project, id: TabId) bool {
        return p.hasTab(id);
    }

    fn forgetTab(m: *Model, id: TabId) void {
        _ = m.zoomed.remove(id);
        _ = m.pane_history.remove(id);
    }

    fn activate(m: *Model, p: *Project, tab_id: TabId) Error!void {
        const a = m.alloc();
        if (p.active_tab) |cur| {
            if (!cur.eql(tab_id)) {
                const gop = try m.tab_history.getOrPut(a, p.id);
                if (!gop.found_existing) gop.value_ptr.* = .{ .limit = tab_history_limit };
                try gop.value_ptr.push(a, cur);
            }
        }
        p.active_tab = tab_id;
    }

    pub fn selectTab(m: *Model, project_id: ProjectId, tab_id: TabId) Error!void {
        const p = m.findProject(project_id) orelse return error.NotFound;
        if (!p.hasTab(tab_id)) return error.NotFound;
        try m.activate(p, p.tabs[p.tabIndex(tab_id)].id);
    }

    pub fn renameTab(m: *Model, tab_id: TabId, title: ?[]const u8) Error!void {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        tab.custom_title = if (title) |t| try a.dupe(u8, t) else null;
    }

    /// Moves a tab inside its project to `index` (clamped).
    pub fn reorderTab(m: *Model, tab_id: TabId, index: usize) Error!void {
        const a = m.alloc();
        const loc = m.locateTab(tab_id) orelse return error.NotFound;
        const tab = loc.project.tabs[loc.index];
        const without = try removeAt(Tab, a, loc.project.tabs, loc.index);
        loc.project.tabs = try insertAt(Tab, a, without, @min(index, without.len), tab);
    }

    /// Moves a tab to another project (Pinned and Scratch Tabs included)
    /// and selects it there. Its panes keep their sessions. A full
    /// `single_tab` project is `Refused`.
    pub fn moveTab(m: *Model, tab_id: TabId, to_project: ProjectId, index: ?usize) Error!void {
        const a = m.alloc();
        const loc = m.locateTab(tab_id) orelse return error.NotFound;
        const dst = m.findProject(to_project) orelse return error.NotFound;
        if (dst == loc.project) return error.BadRequest;
        if (dst.isFull()) return error.Refused;
        const tab = loc.project.tabs[loc.index];
        // Grow the destination first: the only step that can fail after the
        // checks. Nothing has changed if it does.
        const at = @min(index orelse dst.tabs.len, dst.tabs.len);
        const grown = try insertAt(Tab, a, dst.tabs, at, tab);
        const zoomed = m.zoomed.get(tab.id);
        const history = m.pane_history.get(tab.id);
        try m.detachTab(loc);
        dst.tabs = grown;
        if (zoomed) |z| try m.zoomed.put(a, tab.id, z);
        if (history) |h| try m.pane_history.put(a, tab.id, h);
        try m.activate(dst, tab.id);
    }

    // ── Panes ───────────────────────────────────────────────────────────────

    /// Splits pane `target` of a tab: the new pane goes at `position`. The
    /// split's ratio is `ratio` (0.5 when null). With `focus`, the new pane
    /// gets the focus and any zoom ends. With `rebalance`, every ratio of the
    /// tab is even after the split.
    pub fn splitPane(
        m: *Model,
        tab_id: TabId,
        target: PaneId,
        new_pane: Pane,
        split_id: SplitId,
        dir: tree.Dir,
        position: tree.Position,
        ratio: ?f64,
        focus: bool,
        rebalance: bool,
    ) Error!void {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        if (!tree.contains(&tab.root, target)) return error.NotFound;
        if (new_pane.id.isEmpty() or split_id.isEmpty()) return error.BadRequest;
        if (new_pane.session.len == 0) return error.BadRequest;
        if (std.mem.eql(u8, new_pane.id.text, split_id.text)) return error.DuplicateId;
        if (m.nodeIdInUse(new_pane.id.text) or m.nodeIdInUse(split_id.text)) return error.DuplicateId;
        const pane = try tree.clonePane(a, new_pane);
        const sid = try split_id.dupe(a);
        _ = try tree.insertBeside(a, &tab.root, target, .{ .pane = pane }, sid, dir, position);
        if (ratio) |r| _ = tree.setRatio(&tab.root, sid, r);
        if (rebalance) tree.rebalance(&tab.root);
        if (focus) {
            _ = m.zoomed.remove(tab.id);
            try m.focusIn(tab, pane.id);
        }
    }

    /// Closes pane `pane_id`. The last pane of a tab closes the tab. The
    /// next focus is the newest earlier focus that is still in the tab, else
    /// the first pane. With `rebalance`, every ratio is even after.
    pub fn closePane(m: *Model, pane_id: PaneId, rebalance: bool) Error!CloseResult {
        const tab = m.findPaneTab(pane_id) orelse return error.NotFound;
        if (tree.paneCount(&tab.root) <= 1) {
            _ = try m.closeTab(tab.id);
            return .tab_closed;
        }
        try m.takeOut(tab, pane_id);
        if (rebalance) tree.rebalance(&tab.root);
        return .pane_removed;
    }

    /// Removes a pane from a tab with two panes or more, and fixes the
    /// tab's zoom and focus. Cannot fail after its one allocation.
    fn takeOut(m: *Model, tab: *Tab, pane_id: PaneId) Error!void {
        const a = m.alloc();
        // Reserve the history first: the allocation is the only failure.
        const gop = try m.pane_history.getOrPut(a, tab.id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .limit = pane_history_limit };
        const removal = tree.remove(&tab.root, pane_id);
        std.debug.assert(removal == .removed);
        if (m.zoomed.get(tab.id)) |z| {
            if (z.eql(pane_id)) _ = m.zoomed.remove(tab.id);
        }
        gop.value_ptr.remove(pane_id);
        if (tab.focused != null and tab.focused.?.eql(pane_id)) {
            const next = gop.value_ptr.popValid(&tab.root, treeHas);
            tab.focused = next orelse tree.firstPane(&tab.root).id;
        }
    }

    fn treeHas(root: *const SplitNode, id: PaneId) bool {
        return tree.contains(root, id);
    }

    /// Focuses a pane. Another pane's zoom ends (v1 `focusPane`).
    pub fn focusPane(m: *Model, pane_id: PaneId) Error!void {
        const tab = m.findPaneTab(pane_id) orelse return error.NotFound;
        try m.focusIn(tab, pane_id);
    }

    fn focusIn(m: *Model, tab: *Tab, pane_id: PaneId) Error!void {
        const a = m.alloc();
        const id = tree.findPane(&tab.root, pane_id).?.id;
        if (tab.focused != null and tab.focused.?.eql(id)) return;
        const gop = try m.pane_history.getOrPut(a, tab.id);
        if (!gop.found_existing) gop.value_ptr.* = .{ .limit = pane_history_limit };
        if (tab.focused) |cur| try gop.value_ptr.push(a, cur);
        gop.value_ptr.remove(id);
        if (m.zoomed.get(tab.id)) |z| {
            if (!z.eql(id)) _ = m.zoomed.remove(tab.id);
        }
        tab.focused = id;
    }

    /// Focuses the next pane in tree order (the previous one with
    /// `backward`), wrapping. Returns the pane that has the focus.
    pub fn focusNext(m: *Model, tab_id: TabId, backward: bool) Error!PaneId {
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        const cur = tab.focused orelse tree.firstPane(&tab.root).id;
        var scratch: std.heap.ArenaAllocator = .init(m.arena.child_allocator);
        defer scratch.deinit();
        const next = (try tree.nextPane(scratch.allocator(), &tab.root, cur, backward)) orelse return error.BadRequest;
        try m.focusIn(tab, next);
        return tab.focused.?;
    }

    /// Zooms a pane of the tab, or with null ends the zoom. A zoomed pane
    /// has the focus.
    pub fn zoom(m: *Model, tab_id: TabId, pane_id: ?PaneId) Error!void {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        const id = pane_id orelse {
            _ = m.zoomed.remove(tab.id);
            return;
        };
        const pane = tree.findPane(&tab.root, id) orelse return error.NotFound;
        try m.focusIn(tab, pane.id);
        try m.zoomed.put(a, tab.id, pane.id);
    }

    pub fn setRatio(m: *Model, split_id: SplitId, ratio: f64) Error!void {
        for (m.data.projects) |*p| {
            for (p.tabs) |*t| if (tree.setRatio(&t.root, split_id, ratio)) return;
        }
        return error.NotFound;
    }

    pub fn rebalanceTab(m: *Model, tab_id: TabId) Error!void {
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        tree.rebalance(&tab.root);
    }

    /// Swaps the places of two panes of one tab. The focus stays on its pane
    /// (it moves with the pane).
    pub fn swapPanes(m: *Model, x: PaneId, y: PaneId) Error!void {
        const tab = m.findPaneTab(x) orelse return error.NotFound;
        if (!tree.contains(&tab.root, y)) return error.BadRequest;
        if (!tree.swap(&tab.root, x, y)) return error.BadRequest;
    }

    pub fn setAttention(m: *Model, pane_id: PaneId, attention: tree.ModelAttention) Error!void {
        const tab = m.findPaneTab(pane_id) orelse return error.NotFound;
        tree.findPaneMut(&tab.root, pane_id).?.attention = attention;
    }

    /// Moves pane `pane_id` next to pane `dest` on `zone`, in the same tab
    /// or in another. When it is the last pane of its tab, that tab closes.
    /// The moved pane gets the focus.
    pub fn movePane(
        m: *Model,
        pane_id: PaneId,
        dest: PaneId,
        zone: tree.Zone,
        split_id: SplitId,
        rebalance: bool,
    ) Error!void {
        const a = m.alloc();
        if (pane_id.eql(dest)) return error.BadRequest;
        const src = m.findPaneTab(pane_id) orelse return error.NotFound;
        const dst = m.findPaneTab(dest) orelse return error.NotFound;
        if (split_id.isEmpty()) return error.BadRequest;
        if (m.nodeIdInUse(split_id.text)) return error.DuplicateId;
        const pane = tree.findPane(&src.root, pane_id).?.*;
        const sid = try split_id.dupe(a);
        const src_id = src.id;
        const dst_id = dst.id;
        if (src == dst) {
            try m.takeOut(src, pane_id);
        } else if (tree.paneCount(&src.root) <= 1) {
            // `closeTab` can fail only on memory; nothing has changed then.
            _ = try m.closeTab(src_id);
        } else {
            try m.takeOut(src, pane_id);
        }
        const into = m.findTab(dst_id).?;
        _ = try tree.insertBeside(a, &into.root, dest, .{ .pane = pane }, sid, zone.dir(), zone.position());
        _ = m.zoomed.remove(dst_id);
        if (rebalance) tree.rebalance(&into.root);
        try m.focusIn(into, pane_id);
    }

    /// Moves pane `pane_id` out of its tab into a new tab `tab_id`, in
    /// project `project_id` (the pane's own when null), after the source tab
    /// when it is in the same project. The tab of one pane cannot be
    /// separated. A full `single_tab` project is `Refused`.
    pub fn separatePane(m: *Model, pane_id: PaneId, tab_id: TabId, project_id: ?ProjectId) Error!void {
        const a = m.alloc();
        const src = m.findPaneTab(pane_id) orelse return error.NotFound;
        if (tree.paneCount(&src.root) <= 1) return error.BadRequest;
        if (tab_id.isEmpty()) return error.BadRequest;
        if (m.locateTab(tab_id) != null) return error.DuplicateId;
        const src_loc = m.locateTab(src.id).?;
        const p = if (project_id) |id| (m.findProject(id) orelse return error.NotFound) else src_loc.project;
        if (p.isFull()) return error.Refused;
        const pane = tree.findPane(&src.root, pane_id).?.*;
        const at = if (p == src_loc.project) src_loc.index + 1 else p.tabs.len;
        const new_tab: Tab = .{ .id = try tab_id.dupe(a), .root = .{ .pane = pane }, .focused = pane.id };
        // Take the pane out first: `src` points into `p.tabs`, and a copy of
        // that slice made before the change would hold the old tab.
        try m.takeOut(src, pane_id);
        p.tabs = try insertAt(Tab, a, p.tabs, at, new_tab);
        try m.activate(p, new_tab.id);
    }

    /// Puts the whole tree of tab `src_id` into tab `dst_id`, next to pane
    /// `target` on `zone`, or, with a null `target`, at the edge of the tab.
    /// The source tab closes with no pane lost. The first pane of the
    /// merged tree gets the focus, and any zoom of the destination ends.
    pub fn mergeTab(
        m: *Model,
        src_id: TabId,
        dst_id: TabId,
        target: ?PaneId,
        zone: tree.Zone,
        split_id: SplitId,
        rebalance: bool,
    ) Error!void {
        const a = m.alloc();
        if (src_id.eql(dst_id)) return error.BadRequest;
        const src_loc = m.locateTab(src_id) orelse return error.NotFound;
        const dst0 = m.findTab(dst_id) orelse return error.NotFound;
        if (target) |t| if (!tree.contains(&dst0.root, t)) return error.NotFound;
        if (split_id.isEmpty()) return error.BadRequest;
        if (m.nodeIdInUse(split_id.text)) return error.DuplicateId;
        const sid = try split_id.dupe(a);
        const moved = src_loc.project.tabs[src_loc.index].root;
        try m.detachTab(src_loc);
        const dst = m.findTab(dst_id).?;
        if (target) |t| {
            _ = try tree.insertBeside(a, &dst.root, t, moved, sid, zone.dir(), zone.position());
        } else {
            try tree.insertAtRoot(a, &dst.root, moved, sid, zone.dir(), zone.position());
        }
        _ = m.zoomed.remove(dst_id);
        if (rebalance) tree.rebalance(&dst.root);
        try m.focusIn(dst, tree.firstPane(&moved).id);
    }

    /// Splits pane `source` into a `rows` x `columns` grid (see
    /// `tree.makeGrid`). Returns the new panes' ids. The source gets the
    /// focus. The new ids come from `gen`; a new id that is in use fails with
    /// `DuplicateId` and changes nothing.
    pub fn makeGrid(
        m: *Model,
        tab_id: TabId,
        source: PaneId,
        rows: usize,
        columns: usize,
        gen: anytype,
    ) ![]const PaneId {
        const a = m.alloc();
        const tab = m.findTab(tab_id) orelse return error.NotFound;
        if (!tree.contains(&tab.root, source)) return error.NotFound;
        var trial = try tree.clone(a, tab.root);
        const created = try tree.makeGrid(a, &trial, source, rows, columns, gen);
        if (created.items.len == 0) return error.BadRequest;
        try m.checkFreshIds(&trial, &tab.root);
        tab.root = trial;
        _ = m.zoomed.remove(tab.id);
        try m.focusIn(tab, source);
        return created.items;
    }

    // ── Panes that left ─────────────────────────────────────────────────────

    fn appendPanes(a: Allocator, node: *const SplitNode, out: *std.ArrayList(Pane)) Error!void {
        var list: std.ArrayList(*const Pane) = .empty;
        try tree.collectPanes(a, node, &list);
        for (list.items) |p| try out.append(a, p.*);
    }
};

// ── Parents ─────────────────────────────────────────────────────────────────

fn topLevelIfEmpty(id: ?ProjectId) ?ProjectId {
    const x = id orelse return null;
    return if (x.isEmpty()) null else x;
}

fn findIn(projects: []const Project, id: ProjectId) ?*const Project {
    for (projects) |*p| if (p.id.eql(id)) return p;
    return null;
}

/// `Model.parentOf` over a list of projects, so that `validate` reads the
/// tree as the model does.
fn parentIn(projects: []const Project, p: *const Project) ?ProjectId {
    const first = topLevelIfEmpty(p.parent) orelse return null;
    if (findIn(projects, first) == null) return null;
    var at = first;
    var steps: usize = 0;
    while (steps <= projects.len) : (steps += 1) {
        if (at.eql(p.id)) return null;
        const up = findIn(projects, at).?;
        at = topLevelIfEmpty(up.parent) orelse return first;
        if (findIn(projects, at) == null) return first;
    }
    // A loop above the parent that does not hold `p`.
    return first;
}

// ── Copies for `compact` ───────────────────────────────────────────────────

fn cloneData(a: Allocator, d: ModelData) Allocator.Error!ModelData {
    const projects = try a.alloc(Project, d.projects.len);
    for (d.projects, projects) |p, *out| {
        const tabs = try a.alloc(Tab, p.tabs.len);
        for (p.tabs, tabs) |t, *tab| tab.* = .{
            .id = try t.id.dupe(a),
            .custom_title = try dupeText(a, t.custom_title),
            .root = try tree.clone(a, t.root),
            .focused = try dupeId(a, t.focused),
        };
        out.* = .{
            .id = try p.id.dupe(a),
            .name = try a.dupe(u8, p.name),
            .path = try a.dupe(u8, p.path),
            .color = try dupeText(a, p.color),
            .sort_order = p.sort_order,
            .created_at = p.created_at,
            .parent = try dupeId(a, p.parent),
            .sidebar = p.sidebar,
            .single_tab = p.single_tab,
            .removable = p.removable,
            .alias = try dupeText(a, p.alias),
            .tabs = tabs,
            .active_tab = try dupeId(a, p.active_tab),
        };
    }
    return .{
        .version = d.version,
        .epoch_hint = d.epoch_hint,
        .imported_v1 = d.imported_v1,
        .projects = projects,
        .selection = .{ .active_project = try dupeId(a, d.selection.active_project) },
    };
}

fn cloneHistory(comptime K: type, comptime V: type, a: Allocator, old: ids.Map(K, Recency(V))) Allocator.Error!ids.Map(K, Recency(V)) {
    var out: ids.Map(K, Recency(V)) = .empty;
    var it = old.iterator();
    while (it.next()) |e| try out.put(a, try e.key_ptr.dupe(a), try e.value_ptr.clone(a));
    return out;
}

fn dupeText(a: Allocator, text: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (text) |t| try a.dupe(u8, t) else null;
}

fn dupeId(a: Allocator, id: anytype) Allocator.Error!@TypeOf(id) {
    return if (id) |x| try x.dupe(a) else null;
}

// ── Slices that grow ────────────────────────────────────────────────────────

fn appendOne(comptime T: type, a: Allocator, old: []T, item: T) Error![]T {
    return insertAt(T, a, old, old.len, item);
}

fn insertAt(comptime T: type, a: Allocator, old: []T, at: usize, item: T) Error![]T {
    const out = try a.alloc(T, old.len + 1);
    @memcpy(out[0..at], old[0..at]);
    out[at] = item;
    @memcpy(out[at + 1 ..], old[at..]);
    return out;
}

fn removeAt(comptime T: type, a: Allocator, old: []T, at: usize) Error![]T {
    const out = try a.alloc(T, old.len - 1);
    @memcpy(out[0..at], old[0..at]);
    @memcpy(out[at..], old[at + 1 ..]);
    return out;
}

fn indexOf(comptime T: type, items: []const T, id: @FieldType(T, "id")) ?usize {
    for (items, 0..) |it, i| if (it.id.eql(id)) return i;
    return null;
}

// ── Validation ──────────────────────────────────────────────────────────────

/// The first fault of a model: where it is (`projects[1].tabs[0].root.first`)
/// and what is wrong. A fixed buffer, so a fault needs no allocator.
pub const Fault = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn text(f: *const Fault) []const u8 {
        return f.buf[0..f.len];
    }

    pub fn make(comptime fmt: []const u8, args: anytype) Fault {
        var f: Fault = .{};
        const s = std.fmt.bufPrint(&f.buf, fmt, args) catch f.buf[0..];
        f.len = s.len;
        return f;
    }
};

/// Checks that `data` is a model: ids that are not empty and are not used
/// twice, ratios inside 0..1, a `focused` pane that is in its tree, an
/// `active_tab` that is in its project, and the rules of the capability
/// fields (design/010 §11):
///
/// 1. An `alias` is not empty and is unique.
/// 2. A project with `sidebar` other than `tree` is at the top level and
///    holds no project. A `tree` project's parent is a `tree` project.
/// 3. A `single_tab` project holds at most one tab.
/// 4. The selected project is not a project with `sidebar: none`.
///
/// The requests keep these rules, and also: a project with children or
/// that is not `removable` is not removed, and the capability fields never
/// change. Returns the first fault, or null.
pub fn validate(gpa: Allocator, data: *const ModelData) Allocator.Error!?Fault {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var aliases: std.StringHashMapUnmanaged(void) = .empty;

    if (data.version == 0 or data.version > version) return Fault.make("version: {d}", .{data.version});

    for (data.projects, 0..) |p, i| {
        if (p.id.isEmpty()) return Fault.make("projects[{d}].id: empty", .{i});
        if ((try seen.getOrPut(a, p.id.text)).found_existing) return Fault.make("projects[{d}].id: duplicate", .{i});
        if (p.alias) |x| {
            if (x.len == 0) return Fault.make("projects[{d}].alias: empty", .{i});
            if ((try aliases.getOrPut(a, x)).found_existing) return Fault.make("projects[{d}].alias: duplicate", .{i});
        }
    }
    var tabs_seen: std.StringHashMapUnmanaged(void) = .empty;
    var nodes_seen: std.StringHashMapUnmanaged(void) = .empty;
    for (data.projects, 0..) |*p, pi| {
        if (parentIn(data.projects, p)) |g| {
            if (p.sidebar != .tree) return Fault.make("projects[{d}].parent: a project with sidebar {t} is at the top level", .{ pi, p.sidebar });
            if (findIn(data.projects, g).?.sidebar != .tree) return Fault.make("projects[{d}].parent: not a tree project", .{pi});
        }
        if (p.single_tab and p.tabs.len > 1) return Fault.make("projects[{d}].tabs: more than one in a single_tab project", .{pi});
        for (p.tabs, 0..) |t, ti| {
            if (t.id.isEmpty()) return Fault.make("projects[{d}].tabs[{d}].id: empty", .{ pi, ti });
            if ((try tabs_seen.getOrPut(a, t.id.text)).found_existing) {
                return Fault.make("projects[{d}].tabs[{d}].id: duplicate", .{ pi, ti });
            }
            var path: [96]u8 = undefined;
            const prefix = std.fmt.bufPrint(&path, "projects[{d}].tabs[{d}].root", .{ pi, ti }) catch path[0..];
            if (try validateNode(a, &t.root, prefix, &nodes_seen)) |f| return f;
            if (t.focused) |f| {
                if (!tree.contains(&t.root, f)) return Fault.make("projects[{d}].tabs[{d}].focused: not in the tab", .{ pi, ti });
            }
        }
        if (p.active_tab) |at| {
            if (!p.hasTab(at)) return Fault.make("projects[{d}].active_tab: not in the project", .{pi});
        }
    }
    if (data.selection.active_project) |id| {
        const p = findIn(data.projects, id) orelse return Fault.make("selection.active_project: no such project", .{});
        if (p.sidebar == .none) return Fault.make("selection.active_project: a project with sidebar none", .{});
    }
    return null;
}

fn validateNode(
    a: Allocator,
    node: *const SplitNode,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
) Allocator.Error!?Fault {
    switch (node.*) {
        .pane => |p| {
            if (p.id.isEmpty()) return Fault.make("{s}.id: empty", .{path});
            if (p.session.len == 0) return Fault.make("{s}.session: empty", .{path});
            if ((try seen.getOrPut(a, p.id.text)).found_existing) return Fault.make("{s}.id: duplicate", .{path});
        },
        .split => |s| {
            if (s.id.isEmpty()) return Fault.make("{s}.id: empty", .{path});
            if ((try seen.getOrPut(a, s.id.text)).found_existing) return Fault.make("{s}.id: duplicate", .{path});
            if (!(s.ratio > 0 and s.ratio < 1)) return Fault.make("{s}.ratio: outside 0 to 1", .{path});
            var buf: [128]u8 = undefined;
            const first = std.fmt.bufPrint(&buf, "{s}.first", .{path}) catch buf[0..];
            if (try validateNode(a, &s.first, first, seen)) |f| return f;
            const second = std.fmt.bufPrint(&buf, "{s}.second", .{path}) catch buf[0..];
            return validateNode(a, &s.second, second, seen);
        },
    }
    return null;
}
