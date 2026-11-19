//! What the CLI prints, as the v1 CLI printed it (`CLI/Output.swift`):
//! stdout holds only the output of a command that worked, and every
//! diagnostic goes to stderr.

const std = @import("std");

/// `macterm: <message>`, and `  hint: <action>` when there is an action.
pub fn writeError(w: *std.Io.Writer, message: []const u8, action: ?[]const u8) std.Io.Writer.Error!void {
    try w.print("macterm: {s}\n", .{message});
    if (action) |a| try w.print("  hint: {s}\n", .{a});
}

/// Rows of cells, each column as wide as its widest cell, two spaces apart.
/// The last cell of a row has no padding (v1's `printColumns`).
pub fn writeColumns(gpa: std.mem.Allocator, w: *std.Io.Writer, rows: []const []const []const u8) (std.Io.Writer.Error || error{OutOfMemory})!void {
    var widths: std.ArrayList(usize) = .empty;
    defer widths.deinit(gpa);
    for (rows) |row| for (row, 0..) |cell, i| {
        if (i == widths.items.len) try widths.append(gpa, 0);
        widths.items[i] = @max(widths.items[i], cellWidth(cell));
    };
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i > 0) try w.writeAll("  ");
            try w.writeAll(cell);
            if (i + 1 < row.len) try w.splatByteAll(' ', widths.items[i] - cellWidth(cell));
        }
        try w.writeByte('\n');
    }
}

fn cellWidth(cell: []const u8) usize {
    return std.unicode.utf8CountCodepoints(cell) catch cell.len;
}

/// `--json` output: the value as Foundation's `JSONEncoder` writes it with
/// `.prettyPrinted` and `.sortedKeys` (two spaces, `"key" : value`, `\/`),
/// and a newline.
pub fn writeJson(gpa: std.mem.Allocator, w: *std.Io.Writer, value: std.json.Value) (std.Io.Writer.Error || error{OutOfMemory})!void {
    try writeValue(gpa, w, value, 0);
    try w.writeByte('\n');
}

fn writeValue(gpa: std.mem.Allocator, w: *std.Io.Writer, value: std.json.Value, depth: usize) (std.Io.Writer.Error || error{OutOfMemory})!void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeString(w, s),
        .array => |list| {
            try w.writeByte('[');
            if (list.items.len == 0) return writeEmpty(w, ']', depth);
            for (list.items, 0..) |item, i| {
                try w.writeAll(if (i == 0) "\n" else ",\n");
                try indent(w, depth + 1);
                try writeValue(gpa, w, item, depth + 1);
            }
            try w.writeByte('\n');
            try indent(w, depth);
            try w.writeByte(']');
        },
        .object => |map| {
            try w.writeByte('{');
            if (map.count() == 0) return writeEmpty(w, '}', depth);
            const keys = try gpa.dupe([]const u8, map.keys());
            defer gpa.free(keys);
            std.mem.sort([]const u8, keys, {}, lessThan);
            for (keys, 0..) |key, i| {
                try w.writeAll(if (i == 0) "\n" else ",\n");
                try indent(w, depth + 1);
                try writeString(w, key);
                try w.writeAll(" : ");
                try writeValue(gpa, w, map.get(key).?, depth + 1);
            }
            try w.writeByte('\n');
            try indent(w, depth);
            try w.writeByte('}');
        },
    }
}

/// An empty container: a blank line, then the close at the container's depth.
fn writeEmpty(w: *std.Io.Writer, close: u8, depth: usize) std.Io.Writer.Error!void {
    try w.writeAll("\n\n");
    try indent(w, depth);
    try w.writeByte(close);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn indent(w: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', depth * 2);
}

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '/' => try w.writeAll("\\/"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "JSON has sorted keys, two spaces, a space before the colon, and escaped slashes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"b": {"z": [1, "a/b\n"], "a": true, "e": {}, "f": []}, "a": null}
    , .{});
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(testing.allocator, &w, value);
    try testing.expectEqualStrings(
        \\{
        \\  "a" : null,
        \\  "b" : {
        \\    "a" : true,
        \\    "e" : {
        \\
        \\    },
        \\    "f" : [
        \\
        \\    ],
        \\    "z" : [
        \\      1,
        \\      "a\/b\n"
        \\    ]
        \\  }
        \\}
        \\
    , w.buffered());
}

test "an error has its hint on a line of its own" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeError(&w, "something broke", "see the log");
    try writeError(&w, "no", null);
    try testing.expectEqualStrings("macterm: something broke\n  hint: see the log\nmacterm: no\n", w.buffered());
}
