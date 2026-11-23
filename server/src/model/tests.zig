//! Tests of the model core: the shared tree fixtures, every tree operation,
//! the model's operations, validation, and the JSON file.

const std = @import("std");
const testing = std.testing;
const tree = @import("tree.zig");
const model = @import("model.zig");
const file = @import("file.zig");

const Node = tree.Node;
const Model = model.Model;

// ── Helpers ─────────────────────────────────────────────────────────────────

fn mkPane(id: []const u8) tree.Pane {
    return .{ .id = .of(id), .session = id };
}

fn pane(id: []const u8) Node {
    return .{ .pane = mkPane(id) };
}

fn split(a: std.mem.Allocator, id: []const u8, dir: tree.Dir, ratio: f64, first: Node, second: Node) !Node {
    const s = try a.create(tree.Split);
    s.* = .{ .id = .of(id), .dir = dir, .ratio = ratio, .first = first, .second = second };
    return .{ .split = s };
}

/// A model with one project `p` and an arena allocator for building trees.
fn newModel() !Model {
    var m = Model.init(testing.allocator);
    errdefer m.deinit();
    try m.addProject(.{ .id = .of("p"), .name = "P", .path = "/p" });
    return m;
}

/// Tab `t` in workspace `p`: H(a, V(b, c)), split ids s1 and s2.
fn threePaneTab(m: *Model, tab_id: []const u8, a: []const u8, b: []const u8, c: []const u8, s1: []const u8, s2: []const u8) !void {
    const arena = m.arena.allocator();
    const root = try split(arena, s1, .horizontal, 0.5, pane(a), try split(arena, s2, .vertical, 0.5, pane(b), pane(c)));
    try m.createTab(.of("p"), .of(tab_id), null, root, null, true);
}

fn paneOrder(m: *Model, tab_id: []const u8) ![]const tree.PaneId {
    return tree.paneIds(m.arena.allocator(), &m.findTab(.of(tab_id)).?.root);
}

fn expectOrder(m: *Model, tab_id: []const u8, want: []const []const u8) !void {
    const got = try paneOrder(m, tab_id);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g.text);
}

fn expectFocus(m: *Model, tab_id: []const u8, want: []const u8) !void {
    try testing.expectEqualStrings(want, m.findTab(.of(tab_id)).?.focused.?.text);
}

fn expectValid(m: *const Model) !void {
    const fault = try model.validate(testing.allocator, &m.data);
    if (fault) |f| {
        std.debug.print("fault: {s}\n", .{f.text()});
        return error.TestUnexpectedResult;
    }
}

// ── The shared fixtures ─────────────────────────────────────────────────────

const fixture_text = @embedFile("trees.json");

fn fixtureNode(a: std.mem.Allocator, v: std.json.Value, next_split: *usize) !Node {
    switch (v) {
        .string => |name| return pane(name),
        .object => |o| {
            next_split.* += 1;
            const id = try std.fmt.allocPrint(a, "fx-s{d}", .{next_split.*});
            const dir: tree.Dir = if (std.mem.eql(u8, o.get("dir").?.string, "horizontal")) .horizontal else .vertical;
            const ratio: f64 = switch (o.get("ratio").?) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => unreachable,
            };
            return split(a, id, dir, ratio, try fixtureNode(a, o.get("first").?, next_split), try fixtureNode(a, o.get("second").?, next_split));
        },
        else => return error.BadFixture,
    }
}

/// Fails when the tree and the fixture differ. With `erase_names`, a pane
/// name does not count.
fn expectTreeEquals(v: std.json.Value, n: *const Node, erase_names: bool, where: []const u8) !void {
    switch (v) {
        .string => |name| {
            try testing.expect(n.* == .pane);
            if (!erase_names) {
                testing.expectEqualStrings(name, n.pane.id.text) catch |e| {
                    std.debug.print("case: {s}\n", .{where});
                    return e;
                };
            }
        },
        .object => |o| {
            if (n.* != .split) {
                std.debug.print("case: {s}: want a split\n", .{where});
                return error.TestUnexpectedResult;
            }
            const s = n.split;
            const want_dir: tree.Dir = if (std.mem.eql(u8, o.get("dir").?.string, "horizontal")) .horizontal else .vertical;
            try testing.expectEqual(want_dir, s.dir);
            const want_ratio: f64 = switch (o.get("ratio").?) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => unreachable,
            };
            testing.expectApproxEqAbs(want_ratio, s.ratio, 1e-9) catch |e| {
                std.debug.print("case: {s}\n", .{where});
                return e;
            };
            try expectTreeEquals(o.get("first").?, &s.first, erase_names, where);
            try expectTreeEquals(o.get("second").?, &s.second, erase_names, where);
        },
        else => return error.BadFixture,
    }
}

/// New panes and splits for `tree.makeGrid`: n1, n2, ... and g1, g2, ...
const Gen = struct {
    a: std.mem.Allocator,
    panes: usize = 0,
    splits: usize = 0,

    pub fn newPane(g: *Gen) !tree.Pane {
        g.panes += 1;
        const id = try std.fmt.allocPrint(g.a, "n{d}", .{g.panes});
        return mkPane(id);
    }

    pub fn newSplitId(g: *Gen) !tree.SplitId {
        g.splits += 1;
        return .of(try std.fmt.allocPrint(g.a, "g{d}", .{g.splits}));
    }
};

test "the tree fixtures" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture_text, .{});
    const cases = doc.object.get("cases").?.array.items;
    try testing.expect(cases.len >= 10);

    for (cases) |c| {
        const o = c.object;
        const name = o.get("name").?.string;
        const op = o.get("op").?.string;
        var counter: usize = 0;
        var root = try fixtureNode(a, o.get("before").?, &counter);
        const erase = if (o.get("erase_names")) |e| e.bool else false;

        if (std.mem.eql(u8, op, "split")) {
            const dir: tree.Dir = if (std.mem.eql(u8, o.get("dir").?.string, "horizontal")) .horizontal else .vertical;
            const pos: tree.Position = if (std.mem.eql(u8, o.get("position").?.string, "first")) .first else .second;
            const done = try tree.insertBeside(a, &root, .of(o.get("target").?.string), pane(o.get("new").?.string), .of("fx-new"), dir, pos);
            try testing.expect(done);
        } else if (std.mem.eql(u8, op, "remove")) {
            const result = tree.remove(&root, .of(o.get("pane").?.string));
            try testing.expectEqualStrings(o.get("result").?.string, @tagName(result));
        } else if (std.mem.eql(u8, op, "rebalance")) {
            tree.rebalance(&root);
        } else if (std.mem.eql(u8, op, "swap")) {
            try testing.expect(tree.swap(&root, .of(o.get("x").?.string), .of(o.get("y").?.string)));
        } else if (std.mem.eql(u8, op, "insert")) {
            const zone = std.meta.stringToEnum(tree.Zone, o.get("zone").?.string).?;
            const node = try fixtureNode(a, o.get("node").?, &counter);
            const done = try tree.insertBeside(a, &root, .of(o.get("dest").?.string), node, .of("fx-new"), zone.dir(), zone.position());
            try testing.expect(done);
        } else if (std.mem.eql(u8, op, "grid")) {
            var gen: Gen = .{ .a = a };
            const created = try tree.makeGrid(a, &root, .of(o.get("source").?.string), @intCast(o.get("rows").?.integer), @intCast(o.get("columns").?.integer), &gen);
            try testing.expectEqual(@as(usize, @intCast(o.get("rows").?.integer * o.get("columns").?.integer - 1)), created.items.len);
        } else {
            std.debug.print("unknown op {s} in case {s}\n", .{ op, name });
            return error.BadFixture;
        }
        try expectTreeEquals(o.get("after").?, &root, erase, name);
    }
}

// ── Tree operations ─────────────────────────────────────────────────────────

test "a ratio is clamped, and a NaN is one half" {
    try testing.expectEqual(@as(f64, 0.15), tree.clampRatio(0.0));
    try testing.expectEqual(@as(f64, 0.85), tree.clampRatio(2.0));
    try testing.expectEqual(@as(f64, 0.5), tree.clampRatio(std.math.nan(f64)));
    try testing.expectEqual(@as(f64, 0.4), tree.clampRatio(0.4));
}

test "nextPane wraps in tree order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try split(a, "s1", .horizontal, 0.5, pane("a"), try split(a, "s2", .vertical, 0.5, pane("b"), pane("c")));
    try testing.expectEqualStrings("b", (try tree.nextPane(a, &root, .of("a"), false)).?.text);
    try testing.expectEqualStrings("a", (try tree.nextPane(a, &root, .of("c"), false)).?.text);
    try testing.expectEqualStrings("c", (try tree.nextPane(a, &root, .of("a"), true)).?.text);
    try testing.expectEqual(@as(?tree.PaneId, null), try tree.nextPane(a, &root, .of("z"), false));
    const single = pane("only");
    try testing.expectEqualStrings("only", (try tree.nextPane(a, &single, .of("only"), false)).?.text);
}

test "a grid of fewer than two cells or from an unknown pane does nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var gen: Gen = .{ .a = a };
    var root = pane("a");
    try testing.expectEqual(@as(usize, 0), (try tree.makeGrid(a, &root, .of("a"), 1, 1, &gen)).items.len);
    try testing.expectEqual(@as(usize, 0), (try tree.makeGrid(a, &root, .of("a"), 0, 3, &gen)).items.len);
    try testing.expectEqual(@as(usize, 0), (try tree.makeGrid(a, &root, .of("z"), 2, 2, &gen)).items.len);
    try testing.expect(root == .pane);
}

test "setRatio finds a split by id and clamps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = try split(a, "s1", .horizontal, 0.5, pane("a"), try split(a, "s2", .vertical, 0.5, pane("b"), pane("c")));
    try testing.expect(tree.setRatio(&root, .of("s2"), 0.99));
    try testing.expectEqual(@as(f64, 0.85), tree.findSplit(&root, .of("s2")).?.ratio);
    try testing.expect(!tree.setRatio(&root, .of("zz"), 0.5));
}

// ── Model operations ────────────────────────────────────────────────────────

test "create a tab: the focus is the first pane and the tab is active" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
    try expectFocus(&m, "t1", "a");
    try testing.expectEqualStrings("t1", m.findWorkspace(.of("p")).?.active_tab.?.text);
    try expectValid(&m);
}

test "create a tab refuses a used id and changes nothing" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    const before = m.findWorkspace(.of("p")).?.tabs.len;
    // A pane id in use, a split id in use, a tab id in use, and a pane twice.
    try testing.expectError(error.DuplicateId, m.createTab(.of("p"), .of("t2"), null, pane("b"), null, true));
    const arena = m.arena.allocator();
    try testing.expectError(error.DuplicateId, m.createTab(.of("p"), .of("t2"), null, try split(arena, "s1", .horizontal, 0.5, pane("x"), pane("y")), null, true));
    try testing.expectError(error.DuplicateId, m.createTab(.of("p"), .of("t1"), null, pane("x"), null, true));
    try testing.expectError(error.DuplicateId, m.createTab(.of("p"), .of("t2"), null, try split(arena, "q", .horizontal, 0.5, pane("x"), pane("x")), null, true));
    try testing.expectError(error.NotFound, m.createTab(.of("nope"), .of("t2"), null, pane("x"), null, true));
    try testing.expectEqual(before, m.findWorkspace(.of("p")).?.tabs.len);
    try expectValid(&m);
}

test "split a pane: the new pane is focused and a zoom ends" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom(.of("t1"), .of("b"));
    try testing.expectEqualStrings("b", m.zoomedPane(.of("t1")).?.text);
    try m.splitPane(.of("t1"), .of("b"), mkPane("d"), .of("s3"), .horizontal, .second, null, true, false);
    try expectOrder(&m, "t1", &.{ "a", "b", "d", "c" });
    try expectFocus(&m, "t1", "d");
    try testing.expectEqual(@as(?model.PaneId, null), m.zoomedPane(.of("t1")));
    try expectValid(&m);
}

test "split with no focus keeps the focus and the zoom" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom(.of("t1"), .of("c"));
    try m.splitPane(.of("t1"), .of("a"), mkPane("d"), .of("s3"), .vertical, .first, 0.3, false, false);
    try expectFocus(&m, "t1", "c");
    try testing.expectEqualStrings("c", m.zoomedPane(.of("t1")).?.text);
    try testing.expectEqual(@as(f64, 0.3), tree.findSplit(&m.findTab(.of("t1")).?.root, .of("s3")).?.ratio);
}

test "split with rebalance makes every ratio even" {
    var m = try newModel();
    defer m.deinit();
    const arena = m.arena.allocator();
    try m.createTab(.of("p"), .of("t1"), null, try split(arena, "s1", .horizontal, 0.2, pane("a"), pane("b")), null, true);
    try m.splitPane(.of("t1"), .of("b"), mkPane("c"), .of("s2"), .horizontal, .second, 0.9, true, true);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), tree.findSplit(&m.findTab(.of("t1")).?.root, .of("s1")).?.ratio, 1e-9);
    try testing.expectEqual(@as(f64, 0.5), tree.findSplit(&m.findTab(.of("t1")).?.root, .of("s2")).?.ratio);
}

test "split refuses what it cannot do and changes nothing" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectError(error.NotFound, m.splitPane(.of("t1"), .of("zz"), mkPane("d"), .of("s3"), .horizontal, .second, null, true, false));
    try testing.expectError(error.NotFound, m.splitPane(.of("tx"), .of("a"), mkPane("d"), .of("s3"), .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane(.of("t1"), .of("a"), mkPane("b"), .of("s3"), .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane(.of("t1"), .of("a"), mkPane("d"), .of("s2"), .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane(.of("t1"), .of("a"), mkPane("d"), .of("d"), .horizontal, .second, null, true, false));
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
}

test "close a pane: the next focus is the previous focus, else the first pane" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.focusPane(.of("c"));
    try m.focusPane(.of("b"));
    // History, newest first: c, a. Closing b gives the focus to c.
    try testing.expectEqual(model.CloseResult.pane_removed, try m.closePane(.of("b"), false));
    try expectFocus(&m, "t1", "c");
    try expectOrder(&m, "t1", &.{ "a", "c" });
    // A pane that is not focused: the focus stays.
    try testing.expectEqual(model.CloseResult.pane_removed, try m.closePane(.of("a"), false));
    try expectFocus(&m, "t1", "c");
    try expectValid(&m);
}

test "close skips a history entry that left the tree" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.focusPane(.of("b"));
    try m.focusPane(.of("c"));
    // History: b, a. Close b (not focused), then close c: a is next.
    _ = try m.closePane(.of("b"), false);
    _ = try m.closePane(.of("c"), false);
    try expectFocus(&m, "t1", "a");
}

test "close a zoomed pane ends the zoom" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom(.of("t1"), .of("b"));
    _ = try m.closePane(.of("b"), false);
    try testing.expectEqual(@as(?model.PaneId, null), m.zoomedPane(.of("t1")));
}

test "close the last pane closes the tab and the next tab is the previous one" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    try m.createTab(.of("p"), .of("t2"), null, pane("b"), null, true);
    try m.createTab(.of("p"), .of("t3"), null, pane("c"), null, true);
    try m.selectTab(.of("p"), .of("t2"));
    // History, newest first: t3, t1. Closing t2 (active) gives t3.
    try testing.expectEqual(model.CloseResult.tab_closed, try m.closePane(.of("b"), false));
    try testing.expectEqualStrings("t3", m.findWorkspace(.of("p")).?.active_tab.?.text);
    try testing.expectEqual(@as(usize, 2), m.findWorkspace(.of("p")).?.tabs.len);
    try testing.expectError(error.NotFound, m.closePane(.of("b"), false));
    try expectValid(&m);
}

test "close the only tab leaves no active tab" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    const gone = try m.closeTab(.of("t1"));
    try testing.expectEqual(@as(usize, 1), gone.len);
    try testing.expectEqualStrings("a", gone[0].id.text);
    try testing.expectEqual(@as(?model.TabId, null), m.findWorkspace(.of("p")).?.active_tab);
}

test "focus next and previous wrap, and a zoom follows another focus away" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectEqualStrings("b", (try m.focusNext(.of("t1"), false)).text);
    try testing.expectEqualStrings("c", (try m.focusNext(.of("t1"), false)).text);
    try testing.expectEqualStrings("a", (try m.focusNext(.of("t1"), false)).text);
    try testing.expectEqualStrings("c", (try m.focusNext(.of("t1"), true)).text);
    try m.zoom(.of("t1"), .of("c"));
    _ = try m.focusNext(.of("t1"), false);
    try testing.expectEqual(@as(?model.PaneId, null), m.zoomedPane(.of("t1")));
}

test "zoom a pane focuses it, and null ends the zoom" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.zoom(.of("t1"), .of("c"));
    try expectFocus(&m, "t1", "c");
    try testing.expectEqualStrings("c", m.zoomedPane(.of("t1")).?.text);
    try m.zoom(.of("t1"), null);
    try testing.expectEqual(@as(?model.PaneId, null), m.zoomedPane(.of("t1")));
    try testing.expectError(error.NotFound, m.zoom(.of("t1"), .of("zz")));
}

test "setRatio and rebalance a tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.setRatio(.of("s1"), 0.7);
    try testing.expectEqual(@as(f64, 0.7), tree.findSplit(&m.findTab(.of("t1")).?.root, .of("s1")).?.ratio);
    try m.rebalanceTab(.of("t1"));
    try testing.expectEqual(@as(f64, 0.5), tree.findSplit(&m.findTab(.of("t1")).?.root, .of("s1")).?.ratio);
    try testing.expectError(error.NotFound, m.setRatio(.of("zz"), 0.5));
}

test "swap two panes of one tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.swapPanes(.of("a"), .of("c"));
    try expectOrder(&m, "t1", &.{ "c", "b", "a" });
    try testing.expectError(error.BadRequest, m.swapPanes(.of("a"), .of("a")));
    try m.createTab(.of("p"), .of("t2"), null, pane("x"), null, false);
    try testing.expectError(error.BadRequest, m.swapPanes(.of("a"), .of("x")));
}

test "move a pane inside a tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.movePane(.of("a"), .of("c"), .bottom, .of("s3"), false);
    // a leaves the root; b and c remain in V(b, c); a goes below c.
    try expectOrder(&m, "t1", &.{ "b", "c", "a" });
    try expectFocus(&m, "t1", "a");
    try expectValid(&m);
}

test "move a pane to another tab; its tab closes when it was the last pane" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab(.of("p"), .of("t2"), null, pane("x"), null, true);
    try m.movePane(.of("x"), .of("b"), .left, .of("s3"), true);
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab(.of("t2")));
    try expectOrder(&m, "t1", &.{ "a", "x", "b", "c" });
    try expectFocus(&m, "t1", "x");
    try testing.expectEqual(@as(usize, 1), m.findWorkspace(.of("p")).?.tabs.len);
    try expectValid(&m);
}

test "move a pane to another tab when its own tab has more panes" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab(.of("p"), .of("t2"), null, pane("x"), null, true);
    try m.movePane(.of("a"), .of("x"), .right, .of("s3"), false);
    try expectOrder(&m, "t1", &.{ "b", "c" });
    try expectOrder(&m, "t2", &.{ "x", "a" });
    try expectFocus(&m, "t2", "a");
    try expectValid(&m);
}

test "move refuses a missing or equal pane and a used split id" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectError(error.BadRequest, m.movePane(.of("a"), .of("a"), .left, .of("s3"), false));
    try testing.expectError(error.NotFound, m.movePane(.of("a"), .of("zz"), .left, .of("s3"), false));
    try testing.expectError(error.NotFound, m.movePane(.of("zz"), .of("a"), .left, .of("s3"), false));
    try testing.expectError(error.DuplicateId, m.movePane(.of("a"), .of("b"), .left, .of("s2"), false));
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
}

test "separate a pane into a new tab after its tab" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab(.of("p"), .of("t9"), null, pane("z"), null, false);
    try m.separatePane(.of("c"), .of("t2"), null);
    const ws = m.findWorkspace(.of("p")).?;
    try testing.expectEqualStrings("t1", ws.tabs[0].id.text);
    try testing.expectEqualStrings("t2", ws.tabs[1].id.text);
    try testing.expectEqualStrings("t9", ws.tabs[2].id.text);
    try testing.expectEqualStrings("t2", ws.active_tab.?.text);
    try expectOrder(&m, "t1", &.{ "a", "b" });
    try expectOrder(&m, "t2", &.{"c"});
    try expectFocus(&m, "t2", "c");
    try testing.expectError(error.BadRequest, m.separatePane(.of("c"), .of("t3"), null));
    try expectValid(&m);
}

test "merge a tab beside a pane, and at the edge" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    const arena = m.arena.allocator();
    try m.createTab(.of("p"), .of("t2"), null, try split(arena, "s5", .vertical, 0.5, pane("x"), pane("y")), null, false);
    try m.createTab(.of("p"), .of("t3"), null, pane("w"), null, false);
    try m.mergeTab(.of("t2"), .of("t1"), .of("a"), .right, .of("s6"), false);
    try expectOrder(&m, "t1", &.{ "a", "x", "y", "b", "c" });
    try expectFocus(&m, "t1", "x");
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab(.of("t2")));
    try m.mergeTab(.of("t3"), .of("t1"), null, .top, .of("s7"), true);
    try expectOrder(&m, "t1", &.{ "w", "a", "x", "y", "b", "c" });
    try expectFocus(&m, "t1", "w");
    try expectValid(&m);
}

test "merge ends the zoom of the destination and refuses bad requests" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab(.of("p"), .of("t2"), null, pane("x"), null, false);
    try m.zoom(.of("t1"), .of("a"));
    try testing.expectError(error.BadRequest, m.mergeTab(.of("t1"), .of("t1"), null, .left, .of("s3"), false));
    try testing.expectError(error.NotFound, m.mergeTab(.of("t2"), .of("t1"), .of("zz"), .left, .of("s3"), false));
    try testing.expectError(error.DuplicateId, m.mergeTab(.of("t2"), .of("t1"), .of("a"), .left, .of("s2"), false));
    try testing.expect(m.findTab(.of("t2")) != null);
    try m.mergeTab(.of("t2"), .of("t1"), .of("a"), .left, .of("s3"), false);
    try testing.expectEqual(@as(?model.PaneId, null), m.zoomedPane(.of("t1")));
}

test "make a grid" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    var gen: Gen = .{ .a = m.arena.allocator() };
    const created = try m.makeGrid(.of("t1"), .of("a"), 2, 2, &gen);
    try testing.expectEqual(@as(usize, 3), created.len);
    try expectOrder(&m, "t1", &.{ "a", "n2", "n1", "n3" });
    try expectFocus(&m, "t1", "a");
    try expectValid(&m);
}

test "a grid with a used id fails and changes nothing" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    try m.createTab(.of("p"), .of("t2"), null, pane("n2"), null, true);
    var gen: Gen = .{ .a = m.arena.allocator() };
    try testing.expectError(error.DuplicateId, m.makeGrid(.of("t1"), .of("a"), 2, 2, &gen));
    try expectOrder(&m, "t1", &.{"a"});
    var gen2: Gen = .{ .a = m.arena.allocator() };
    try testing.expectError(error.BadRequest, m.makeGrid(.of("t1"), .of("a"), 1, 1, &gen2));
    try testing.expectError(error.NotFound, m.makeGrid(.of("t1"), .of("zz"), 2, 2, &gen2));
}

test "move a tab to another workspace keeps its tree and selects it" {
    var m = try newModel();
    defer m.deinit();
    try m.addWorkspace(.of("pinned"), .pinned);
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.createTab(.of("p"), .of("t2"), null, pane("x"), null, false);
    try m.focusPane(.of("c"));
    try m.moveTab(.of("t1"), .of("pinned"), null);
    try testing.expectEqual(@as(usize, 1), m.findWorkspace(.of("p")).?.tabs.len);
    try testing.expectEqualStrings("t2", m.findWorkspace(.of("p")).?.active_tab.?.text);
    try testing.expectEqualStrings("t1", m.findWorkspace(.of("pinned")).?.active_tab.?.text);
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
    try expectFocus(&m, "t1", "c");
    try testing.expectError(error.BadRequest, m.moveTab(.of("t1"), .of("pinned"), null));
    try testing.expectError(error.NotFound, m.moveTab(.of("t1"), .of("nope"), null));
    try expectValid(&m);
}

test "reorder tabs" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    try m.createTab(.of("p"), .of("t2"), null, pane("b"), null, true);
    try m.createTab(.of("p"), .of("t3"), null, pane("c"), null, true);
    try m.reorderTab(.of("t3"), 0);
    const ws = m.findWorkspace(.of("p")).?;
    try testing.expectEqualStrings("t3", ws.tabs[0].id.text);
    try testing.expectEqualStrings("t1", ws.tabs[1].id.text);
    try m.reorderTab(.of("t3"), 99);
    try testing.expectEqualStrings("t3", m.findWorkspace(.of("p")).?.tabs[2].id.text);
}

test "remove a project removes its workspace and lists its panes" {
    var m = try newModel();
    defer m.deinit();
    try m.addProject(.{ .id = .of("q"), .name = "Q", .path = "/q" });
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.selectProject(.of("p"));
    const gone = try m.removeProject(.of("p"));
    try testing.expectEqual(@as(usize, 3), gone.len);
    try testing.expectEqual(@as(?*model.Project, null), m.findProject(.of("p")));
    try testing.expectEqual(@as(?*model.Workspace, null), m.findWorkspace(.of("p")));
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab(.of("t1")));
    try testing.expectEqual(@as(?model.ProjectId, null), m.data.selection.active_project);
    try testing.expectError(error.NotFound, m.removeProject(.of("p")));
    try expectValid(&m);
}

test "remove a workspace that is not a project's, with its tabs and their history" {
    var m = try newModel();
    defer m.deinit();
    try m.addWorkspace(.of("pin"), .pinned);
    try m.createTab(.of("pin"), .of("t1"), null, pane("a"), null, true);
    try m.createTab(.of("pin"), .of("t2"), null, pane("b"), null, true);
    try testing.expectError(error.BadRequest, m.removeWorkspace(.of("p")));
    const gone = try m.removeWorkspace(.of("pin"));
    try testing.expectEqual(@as(usize, 2), gone.len);
    try testing.expectEqual(@as(?*model.Workspace, null), m.findWorkspace(.of("pin")));
    try testing.expectEqual(@as(?*model.Tab, null), m.findTab(.of("t1")));
    try testing.expect(m.tab_history.get(.of("pin")) == null);
    try testing.expectError(error.NotFound, m.removeWorkspace(.of("pin")));
    try expectValid(&m);
}

test "a project id is not reused, and workspaces other than projects need a kind" {
    var m = try newModel();
    defer m.deinit();
    try testing.expectError(error.DuplicateId, m.addProject(.{ .id = .of("p"), .name = "P2", .path = "/p2" }));
    try testing.expectError(error.BadRequest, m.addWorkspace(.of("w"), .project));
    try m.addWorkspace(.of("w"), .widget);
    try testing.expectError(error.DuplicateId, m.addWorkspace(.of("w"), .quick));
    try testing.expectError(error.DuplicateId, m.addWorkspace(.of("p"), .quick));
}

test "any project has a workspace, can hold projects, and can be selected" {
    var m = try newModel();
    defer m.deinit();
    try m.addProject(.{ .id = .of("g"), .name = "G", .path = "" });
    try testing.expect(m.findWorkspace(.of("g")) != null);
    try testing.expectError(error.BadRequest, m.addProject(.{ .id = .of("x"), .name = "X", .path = "/x", .parent = .of("zz") }));
    try m.addProject(.{ .id = .of("q"), .name = "Q", .path = "/q", .parent = .of("p") });
    try m.addProject(.{ .id = .of("r"), .name = "R", .path = "/r", .parent = .of("") });
    try testing.expect(m.findWorkspace(.of("q")) != null);
    try testing.expectEqualStrings("p", m.parentOf(m.findProject(.of("q")).?).?.text);
    try testing.expectEqual(@as(?model.ProjectId, null), m.parentOf(m.findProject(.of("r")).?));
    try m.selectProject(.of("g"));
    try m.selectProject(.of("p"));
    // A project with tabs can hold a project too.
    try m.createTab(.of("p"), .of("t1"), null, .{ .pane = mkPane("a") }, null, true);
    try expectValid(&m);
    // A project that holds a project is refused, and nothing changes.
    try testing.expectError(error.BadRequest, m.removeProject(.of("p")));
    try testing.expect(m.findTab(.of("t1")) != null);
    _ = try m.removeProject(.of("q"));
    try testing.expectEqual(@as(usize, 1), (try m.removeProject(.of("p"))).len);
    try testing.expectEqual(@as(?*model.Project, null), m.findProject(.of("p")));
    try testing.expectEqual(@as(?*model.Workspace, null), m.findWorkspace(.of("p")));
    try expectValid(&m);
}

test "set a parent: never into itself or into a project that it holds" {
    var m = try newModel();
    defer m.deinit();
    try m.addProject(.{ .id = .of("g"), .name = "G", .path = "/g" });
    try m.addProject(.{ .id = .of("h"), .name = "H", .path = "/h", .parent = .of("g") });
    try m.setParent(.of("p"), .of("h"));
    try testing.expectEqualStrings("h", m.parentOf(m.findProject(.of("p")).?).?.text);
    try testing.expectError(error.BadRequest, m.setParent(.of("g"), .of("g")));
    try testing.expectError(error.BadRequest, m.setParent(.of("g"), .of("h")));
    try testing.expectError(error.BadRequest, m.setParent(.of("h"), .of("p")));
    try testing.expectError(error.BadRequest, m.setParent(.of("h"), .of("zz")));
    try testing.expectError(error.NotFound, m.setParent(.of("zz"), null));
    try testing.expectEqualStrings("g", m.parentOf(m.findProject(.of("h")).?).?.text);
    try m.setParent(.of("p"), .of(""));
    try testing.expectEqual(@as(?model.ProjectId, null), m.parentOf(m.findProject(.of("p")).?));
}

test "reorder the children of one parent" {
    var m = try newModel();
    defer m.deinit();
    try m.addProject(.{ .id = .of("g"), .name = "G", .path = "/g" });
    try m.addProject(.{ .id = .of("a"), .name = "A", .path = "/a", .parent = .of("g") });
    try m.addProject(.{ .id = .of("b"), .name = "B", .path = "/b", .parent = .of("g") });
    try m.reorderProjects(.of("g"), &.{ .of("b"), .of("a") });
    try testing.expectEqual(@as(i64, 0), m.findProject(.of("b")).?.sort_order);
    try testing.expectEqual(@as(i64, 1), m.findProject(.of("a")).?.sort_order);
    try m.reorderProjects(null, &.{ .of("g"), .of("p") });
    try testing.expectEqual(@as(i64, 1), m.findProject(.of("p")).?.sort_order);
    try testing.expectError(error.BadRequest, m.reorderProjects(.of("g"), &.{.of("a")}));
    try testing.expectError(error.BadRequest, m.reorderProjects(.of("g"), &.{ .of("a"), .of("a") }));
    try testing.expectError(error.BadRequest, m.reorderProjects(.of("g"), &.{ .of("a"), .of("p") }));
    // Any project is a parent: `p` holds no project.
    try m.reorderProjects(.of("p"), &.{});
    try testing.expectError(error.BadRequest, m.reorderProjects(.of("p"), &.{.of("a")}));
    try testing.expectError(error.NotFound, m.reorderProjects(.of("zz"), &.{}));
    try testing.expectEqual(@as(i64, 0), m.findProject(.of("b")).?.sort_order);
    try testing.expectEqual(@as(i64, 1), m.findProject(.of("a")).?.sort_order);
}

test "attention and rename" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.setAttention(.of("b"), .failed);
    try testing.expectEqual(tree.ModelAttention.failed, m.findPane(.of("b")).?.attention);
    try m.renameTab(.of("t1"), "build");
    try testing.expectEqualStrings("build", m.findTab(.of("t1")).?.custom_title.?);
    try m.renameTab(.of("t1"), null);
    try testing.expectEqual(@as(?[]const u8, null), m.findTab(.of("t1")).?.custom_title);
}

test "separate a pane that is a direct child of the root, and the focused one" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.focusPane(.of("a"));
    try m.separatePane(.of("a"), .of("t2"), null);
    try expectOrder(&m, "t1", &.{ "b", "c" });
    try expectOrder(&m, "t2", &.{"a"});
    try expectFocus(&m, "t1", "b");
    try expectValid(&m);
    try m.focusPane(.of("c"));
    try m.separatePane(.of("c"), .of("t3"), null);
    try expectOrder(&m, "t1", &.{"b"});
    try expectFocus(&m, "t1", "b");
    try expectValid(&m);
}

test "a pane id and a split id never match" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try testing.expectError(error.DuplicateId, m.splitPane(.of("t1"), .of("a"), mkPane("s1"), .of("s9"), .horizontal, .second, null, true, false));
    try testing.expectError(error.DuplicateId, m.splitPane(.of("t1"), .of("a"), mkPane("d"), .of("b"), .horizontal, .second, null, true, false));
    try m.createTab(.of("p"), .of("t2"), null, pane("x"), null, false);
    try testing.expectError(error.DuplicateId, m.movePane(.of("x"), .of("a"), .left, .of("c"), false));
    try testing.expectError(error.DuplicateId, m.mergeTab(.of("t2"), .of("t1"), .of("a"), .left, .of("a"), false));
    try testing.expectError(error.DuplicateId, m.createTab(.of("p"), .of("t3"), null, pane("s2"), null, false));
    try expectOrder(&m, "t1", &.{ "a", "b", "c" });
    try expectValid(&m);
}

test "input that validate would refuse is refused" {
    var m = try newModel();
    defer m.deinit();
    const arena = m.arena.allocator();
    try testing.expectError(error.BadRequest, m.createTab(.of("p"), .of("t1"), null, .{ .pane = .{ .id = .of("a"), .session = "" } }, null, true));
    try testing.expectError(error.BadRequest, m.createTab(.of("p"), .of("t1"), null, try split(arena, "s", .horizontal, 7.0, pane("a"), pane("b")), null, true));
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    try testing.expectError(error.BadRequest, m.splitPane(.of("t1"), .of("a"), .{ .id = .of("d"), .session = "" }, .of("s9"), .horizontal, .second, null, true, false));
    try testing.expectEqual(@as(usize, 1), m.findWorkspace(.of("p")).?.tabs.len);
    try expectValid(&m);
}

// ── Validation ──────────────────────────────────────────────────────────────

fn faultOf(json: []const u8) ![]const u8 {
    var fault: model.Fault = .{};
    if (file.parse(testing.allocator, json, &fault)) |*m| {
        var mm = m.*;
        mm.deinit();
        return error.TestExpectedFault;
    } else |err| switch (err) {
        error.Invalid => {
            const S = struct {
                var buf: [200]u8 = undefined;
            };
            @memcpy(S.buf[0..fault.len], fault.text());
            return S.buf[0..fault.len];
        },
        else => return err,
    }
}

const base_ok =
    \\{"version":1,"projects":[{"id":"p","name":"P","path":"/p"}],
    \\ "workspaces":[{"id":"p","kind":"project","active_tab":"t1","tabs":[
    \\   {"id":"t1","focused":"a","root":{"split":{"id":"s1","dir":"horizontal","ratio":0.5,
    \\     "first":{"pane":{"id":"a","session":"sa"}},"second":{"pane":{"id":"b","session":"sb"}}}}}]}],
    \\ "selection":{"active_project":"p"}}
;

test "a good file loads" {
    var fault: model.Fault = .{};
    var m = try file.parse(testing.allocator, base_ok, &fault);
    defer m.deinit();
    try expectOrder(&m, "t1", &.{ "a", "b" });
    // A file from before nested projects has no `parent`.
    try testing.expectEqual(@as(?model.ProjectId, null), m.findProject(.of("p")).?.parent);
}

test "each fault names its place" {
    const cases = [_]struct { from: []const u8, to: []const u8, want: []const u8 }{
        .{ .from = "\"id\":\"b\"", .to = "\"id\":\"a\"", .want = "workspaces[0].tabs[0].root.second.id: duplicate" },
        .{ .from = "\"id\":\"s1\"", .to = "\"id\":\"b\"", .want = "workspaces[0].tabs[0].root.second.id: duplicate" },
        .{ .from = "\"ratio\":0.5", .to = "\"ratio\":1.5", .want = "workspaces[0].tabs[0].root.ratio: outside 0 to 1" },
        .{ .from = "\"ratio\":0.5", .to = "\"ratio\":0", .want = "workspaces[0].tabs[0].root.ratio: outside 0 to 1" },
        .{ .from = "\"focused\":\"a\"", .to = "\"focused\":\"zz\"", .want = "workspaces[0].tabs[0].focused: not in the tab" },
        .{ .from = "\"active_tab\":\"t1\"", .to = "\"active_tab\":\"zz\"", .want = "workspaces[0].active_tab: not in the workspace" },
        .{ .from = "\"session\":\"sb\"", .to = "\"session\":\"\"", .want = "workspaces[0].tabs[0].root.second.session: empty" },
        .{ .from = "\"active_project\":\"p\"", .to = "\"active_project\":\"zz\"", .want = "selection.active_project: no such project" },
        .{ .from = "\"kind\":\"project\"", .to = "\"kind\":\"pinned\"", .want = "workspaces[0].id: also a project" },
        .{ .from = "\"workspaces\":[{\"id\":\"p\"", .to = "\"workspaces\":[{\"id\":\"zz\"", .want = "workspaces[0].id: no project" },
        .{ .from = "\"id\":\"t1\"", .to = "\"id\":\"\"", .want = "workspaces[0].tabs[0].id: empty" },
    };
    for (cases) |c| {
        const text = try std.mem.replaceOwned(u8, testing.allocator, base_ok, c.from, c.to);
        defer testing.allocator.free(text);
        try testing.expect(!std.mem.eql(u8, text, base_ok));
        try testing.expectEqualStrings(c.want, try faultOf(text));
    }
}

test "a project with no workspace is a fault" {
    const text = "{\"version\":1,\"projects\":[{\"id\":\"p\",\"name\":\"P\",\"path\":\"/p\"}]}";
    try testing.expectEqualStrings("workspaces: a project has no workspace", try faultOf(text));
}

test "a tab id twice is a fault" {
    const text =
        \\{"version":1,"projects":[{"id":"p","name":"P","path":"/p"}],
        \\ "workspaces":[{"id":"p","kind":"project","tabs":[
        \\   {"id":"t1","root":{"pane":{"id":"a","session":"sa"}}},
        \\   {"id":"t1","root":{"pane":{"id":"b","session":"sb"}}}]}]}
    ;
    try testing.expectEqualStrings("workspaces[0].tabs[1].id: duplicate", try faultOf(text));
}

// ── The file ────────────────────────────────────────────────────────────────

test "a model writes and reads back the same" {
    var m = try newModel();
    defer m.deinit();
    try m.addWorkspace(.of("pinned"), .pinned);
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.renameTab(.of("t1"), "build \"it\"");
    try m.setAttention(.of("c"), .done);
    try m.selectProject(.of("p"));
    m.data.imported_v1 = true;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try file.write(&m, &out.writer);

    var fault: model.Fault = .{};
    var back = try file.parse(testing.allocator, out.written(), &fault);
    defer back.deinit();
    try testing.expect(back.data.imported_v1);
    try testing.expectEqualStrings("build \"it\"", back.findTab(.of("t1")).?.custom_title.?);
    try testing.expectEqual(tree.ModelAttention.done, back.findPane(.of("c")).?.attention);
    try testing.expectEqualStrings("p", back.data.selection.active_project.?.text);
    try testing.expectEqual(@as(usize, 2), back.data.workspaces.len);
    try expectOrder(&back, "t1", &.{ "a", "b", "c" });

    var again: std.Io.Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try file.write(&back, &again.writer);
    try testing.expectEqualStrings(out.written(), again.written());
}

test "a project and its parent write and read back" {
    var m = try newModel();
    defer m.deinit();
    try m.addProject(.{ .id = .of("q"), .name = "Q", .path = "/q", .parent = .of("p") });
    const text = try written(&m);
    defer testing.allocator.free(text);
    var fault: model.Fault = .{};
    var back = try file.parse(testing.allocator, text, &fault);
    defer back.deinit();
    try testing.expectEqualStrings("p", back.parentOf(back.findProject(.of("q")).?).?.text);
    try testing.expectEqual(@as(?model.ProjectId, null), back.findProject(.of("p")).?.parent);
}

test "an old file with kind loads, a former group gets a workspace, and a save writes no kind" {
    // The shape that a build before issue 0480 wrote.
    const text =
        \\{"version":1,"projects":[
        \\ {"id":"g","name":"G","path":"","color":"red","kind":"group"},
        \\ {"id":"p","name":"P","path":"/p","kind":"project","parent":"g"}],
        \\ "workspaces":[{"id":"p","kind":"project"}]}
    ;
    var fault: model.Fault = .{};
    var m = try file.parse(testing.allocator, text, &fault);
    defer m.deinit();
    try expectValid(&m);
    const g = m.findProject(.of("g")).?;
    try testing.expectEqualStrings("G", g.name);
    try testing.expectEqualStrings("red", g.color.?);
    try testing.expectEqualStrings("", g.path);
    try testing.expect(m.findWorkspace(.of("g")) != null);
    try testing.expectEqualStrings("g", m.parentOf(m.findProject(.of("p")).?).?.text);
    // The former group is a project as any other.
    try m.selectProject(.of("g"));
    try m.createTab(.of("g"), .of("t1"), null, .{ .pane = mkPane("a") }, null, true);

    const out = try written(&m);
    defer testing.allocator.free(out);
    const Written = struct { projects: []const struct { kind: ?[]const u8 = null } };
    const read = try std.json.parseFromSlice(Written, testing.allocator, out, .{ .ignore_unknown_fields = true });
    defer read.deinit();
    try testing.expectEqual(@as(usize, 2), read.value.projects.len);
    for (read.value.projects) |p| try testing.expectEqual(@as(?[]const u8, null), p.kind);
    var back = try file.parse(testing.allocator, out, &fault);
    defer back.deinit();
    const again = try written(&back);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "only a former group gets a workspace on load, and a project stays strict" {
    const text =
        \\{"version":1,"projects":[{"id":"p","name":"P","path":"/p","kind":"project"}]}
    ;
    try testing.expectEqualStrings("workspaces: a project has no workspace", try faultOf(text));
    var fault: model.Fault = .{};
    for ([_][]const u8{ "\"kind\":\"folder\"", "\"bogus\":1" }) |extra| {
        var buf: [64]u8 = undefined;
        const with = try std.fmt.bufPrint(&buf, "\"path\":\"/p\",{s}", .{extra});
        const bad = try std.mem.replaceOwned(u8, testing.allocator, base_ok, "\"path\":\"/p\"", with);
        defer testing.allocator.free(bad);
        try testing.expectError(error.Syntax, file.parse(testing.allocator, bad, &fault));
    }
}

test "an unknown parent, or a loop of parents, reads as the top level" {
    const text =
        \\{"version":1,"projects":[
        \\ {"id":"p","name":"P","path":"/p","parent":"gone"},
        \\ {"id":"q","name":"Q","path":"/q","parent":"p"},
        \\ {"id":"g","name":"G","path":"/g","parent":"h"},
        \\ {"id":"h","name":"H","path":"/h","parent":"g"},
        \\ {"id":"r","name":"R","path":"/r","parent":"g"}],
        \\ "workspaces":[{"id":"p","kind":"project"},{"id":"q","kind":"project"},{"id":"g","kind":"project"},
        \\  {"id":"h","kind":"project"},{"id":"r","kind":"project"}]}
    ;
    var fault: model.Fault = .{};
    var m = try file.parse(testing.allocator, text, &fault);
    defer m.deinit();
    for ([_][]const u8{ "p", "g", "h" }) |id| {
        try testing.expectEqual(@as(?model.ProjectId, null), m.parentOf(m.findProject(.of(id)).?));
    }
    try testing.expectEqualStrings("p", m.parentOf(m.findProject(.of("q")).?).?.text);
    try testing.expectEqualStrings("g", m.parentOf(m.findProject(.of("r")).?).?.text);
    // The file keeps what it said.
    try testing.expectEqualStrings("gone", m.findProject(.of("p")).?.parent.?.text);
    // A new parent never makes a loop through the old one.
    try m.addProject(.{ .id = .of("k"), .name = "K", .path = "/k", .parent = .of("h") });
    try testing.expectError(error.BadRequest, m.setParent(.of("g"), .of("k")));
}

test "a newer version is refused, and a bad file is refused" {
    var fault: model.Fault = .{};
    const newer = "{\"version\":99,\"something\":{\"new\":true}}";
    try testing.expectError(error.NewerVersion, file.parse(testing.allocator, newer, &fault));
    try testing.expectEqual(@as(?u32, 99), file.peekVersion(testing.allocator, newer));
    try testing.expectError(error.Syntax, file.parse(testing.allocator, "{not json", &fault));
    try testing.expectError(error.Syntax, file.parse(testing.allocator, "{\"version\":1,\"bogus\":1}", &fault));
    try testing.expectError(error.Invalid, file.parse(testing.allocator, "{\"version\":0}", &fault));
}

test "an empty model writes and reads back" {
    var m = Model.init(testing.allocator);
    defer m.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try file.write(&m, &out.writer);
    var fault: model.Fault = .{};
    var back = try file.parse(testing.allocator, out.written(), &fault);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.data.projects.len);
}

test "save and load go through a file" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/model.json", .{path_buf[0..dir_len]});
    defer testing.allocator.free(path);

    try file.save(testing.allocator, testing.io, &m, path);
    var fault: model.Fault = .{};
    var back = try file.load(testing.allocator, testing.io, path, &fault);
    defer back.deinit();
    try expectOrder(&back, "t1", &.{ "a", "b", "c" });

    const missing = try std.fmt.allocPrint(testing.allocator, "{s}.none", .{path});
    defer testing.allocator.free(missing);
    var empty = try file.load(testing.allocator, testing.io, missing, &fault);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.data.projects.len);
}

test "an id is a plain string in the file" {
    var m = try newModel();
    defer m.deinit();
    try threePaneTab(&m, "t1", "a", "b", "c", "s1", "s2");
    try m.selectProject(.of("p"));
    const text = try written(&m);
    defer testing.allocator.free(text);
    for ([_][]const u8{ "\"id\": \"p\"", "\"id\": \"t1\"", "\"id\": \"s1\"", "\"id\": \"a\"", "\"focused\": \"a\"", "\"active_tab\": \"t1\"", "\"active_project\": \"p\"" }) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("missing: {s}\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
}

// ── Compaction ──────────────────────────────────────────────────────────────

fn written(m: *Model) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try file.write(m, &out.writer);
    return out.toOwnedSlice();
}

test "compact frees the memory of old edits and keeps the model" {
    var m = try newModel();
    defer m.deinit();
    try addFullModel(&m);
    try m.compact();
    const small = m.arena.queryCapacity();

    // Many edits that end where they started.
    var pane_buf: [16]u8 = undefined;
    var split_buf: [16]u8 = undefined;
    for (0..2000) |i| {
        const pane_id = try std.fmt.bufPrint(&pane_buf, "e{d}", .{i});
        const split_id = try std.fmt.bufPrint(&split_buf, "f{d}", .{i});
        try m.splitPane(.of("t1"), .of("c"), mkPane(pane_id), .of(split_id), .horizontal, .second, null, true, false);
        _ = try m.closePane(.of(pane_id), false);
        try m.renameTab(.of("t1"), "build");
    }
    try m.focusPane(.of("b"));
    try m.focusPane(.of("c"));
    try m.zoom(.of("t1"), .of("a"));
    try m.selectTab(.of("p"), .of("t2"));
    const grown = m.arena.queryCapacity();
    try testing.expect(grown > 4 * small);

    const before = try written(&m);
    defer testing.allocator.free(before);
    try m.compact();
    try testing.expect(m.arena.queryCapacity() * 4 < grown);
    const after = try written(&m);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try expectValid(&m);

    // The zoom and both histories are in the new arena.
    try testing.expectEqualStrings("a", m.zoomedPane(.of("t1")).?.text);
    _ = try m.closePane(.of("a"), false);
    try expectFocus(&m, "t1", "c");
    _ = try m.closeTab(.of("t2"));
    try testing.expectEqualStrings("t1", m.findWorkspace(.of("p")).?.active_tab.?.text);
}

/// Adds to project `p` a project and a pane with every field set, tab `t1`
/// (H(a, V(b, c))) and tab `t2` (pane `x`), and selects `p`.
fn addFullModel(m: *Model) !void {
    try m.addProject(.{ .id = .of("g"), .name = "G", .path = "", .color = "red" });
    try m.addProject(.{ .id = .of("q"), .name = "Q", .path = "me@box:/q", .color = "blue", .sort_order = 3, .created_at = 1700000000000, .parent = .of("g") });
    try m.addWorkspace(.of("pinned"), .pinned);
    try threePaneTab(m, "t1", "a", "b", "c", "s1", "s2");
    const x: tree.Pane = .{
        .id = .of("x"),
        .session = "macterm-x",
        .host = "me@box",
        .slug = "q",
        .origin_path = "/q",
        .cwd = "/q/src",
        .host_session_dir = "/q/src",
        .attention = .failed,
    };
    try m.createTab(.of("p"), .of("t2"), null, .{ .pane = x }, null, false);
    try m.renameTab(.of("t1"), "build");
    try m.selectProject(.of("p"));
}

test "compact that runs out of memory leaves the model as it was" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var m = Model.init(failing.allocator());
    defer m.deinit();
    try m.addProject(.{ .id = .of("p"), .name = "P", .path = "/p" });
    try addFullModel(&m);
    try m.zoom(.of("t1"), .of("b"));
    const before = try written(&m);
    defer testing.allocator.free(before);
    // Fail the first allocation of `compact`, then the second, and so on,
    // until it succeeds.
    var n: usize = 0;
    while (true) : (n += 1) {
        failing.fail_index = failing.alloc_index + n;
        const result = m.compact();
        failing.fail_index = std.math.maxInt(usize);
        const after = try written(&m);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(before, after);
        try testing.expectEqualStrings("b", m.zoomedPane(.of("t1")).?.text);
        if (result) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(n > 0);
}

test "save compacts the model" {
    var m = try newModel();
    defer m.deinit();
    try m.createTab(.of("p"), .of("t1"), null, pane("a"), null, true);
    try m.compact();
    const small = m.arena.queryCapacity();
    for (0..2000) |_| try m.renameTab(.of("t1"), "a title that takes some bytes");
    const grown = m.arena.queryCapacity();
    try testing.expect(grown > 4 * small);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/model.json", .{path_buf[0..dir_len]});
    defer testing.allocator.free(path);
    try file.save(testing.allocator, testing.io, &m, path);
    try testing.expect(m.arena.queryCapacity() * 4 < grown);
    try testing.expectEqualStrings("a title that takes some bytes", m.findTab(.of("t1")).?.custom_title.?);
}
