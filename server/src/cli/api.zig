//! `macterm api` (design/011 §4): the methods of the protocol, read from the
//! comptime metadata (`protocol/metadata.zig`), so that the answer is the
//! code of this build. It prints methods, not verbs: there is no second
//! grammar.
//!
//! - `api list` prints each method that a local client may send.
//! - `api describe` prints one method, with its arguments and its result as
//!   JSON Schema.
//! - `api call` sends one request. Its arguments and its result are JSON
//!   objects with the keys of the wire (snake_case). `bin` is a JSON string.

const std = @import("std");
const m = @import("../protocol/messages.zig");
const msgpack = @import("../protocol/msgpack.zig");
const metadata = @import("../protocol/metadata.zig");

pub const Method = metadata.Method;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// The methods that a local client may send, in the order of
/// `messages.methods`. No other method is in `api list`.
pub const methods: []const metadata.Method = blk: {
    var list: []const metadata.Method = &.{};
    for (metadata.metadata.methods) |method| {
        for (method.senders) |s| if (std.mem.eql(u8, s, "local")) {
            list = list ++ &[_]metadata.Method{method};
        };
    }
    break :blk list;
};

pub fn find(name: []const u8) ?metadata.Method {
    for (methods) |method| if (std.mem.eql(u8, method.name, name)) return method;
    return null;
}

// ── list ────────────────────────────────────────────────────────────────────

/// The rows of `api list`: the name, the level that added the method, and
/// its doc.
pub fn listRows(arena: std.mem.Allocator) error{OutOfMemory}![]const []const []const u8 {
    const rows = try arena.alloc([]const []const u8, methods.len);
    for (methods, rows) |method, *row| row.* = try arena.dupe([]const u8, &.{
        method.name,
        try std.fmt.allocPrint(arena, "since {d}", .{method.since}),
        method.doc orelse "",
    });
    return rows;
}

pub fn listJson(arena: std.mem.Allocator) error{OutOfMemory}!Value {
    var list: std.json.Array = .init(arena);
    for (methods) |method| {
        var o: ObjectMap = .empty;
        try o.put(arena, "name", .{ .string = method.name });
        try o.put(arena, "since", .{ .integer = method.since });
        if (method.doc) |d| try o.put(arena, "doc", .{ .string = d });
        try list.append(.{ .object = o });
    }
    var data: ObjectMap = .empty;
    try data.put(arena, "methods", .{ .array = list });
    return .{ .object = data };
}

// ── describe ────────────────────────────────────────────────────────────────

/// One method as JSON: `args` and `result` are JSON Schemas. Every type that
/// they name is in the top-level `$defs`, which their `$ref`s point to.
pub fn describe(arena: std.mem.Allocator, method: metadata.Method) error{OutOfMemory}!Value {
    var defs: ObjectMap = .empty;
    var o: ObjectMap = .empty;
    try o.put(arena, "name", .{ .string = method.name });
    try o.put(arena, "since", .{ .integer = method.since });
    if (method.doc) |d| try o.put(arena, "doc", .{ .string = d });
    var senders: std.json.Array = .init(arena);
    for (method.senders) |s| try senders.append(.{ .string = s });
    try o.put(arena, "senders", .{ .array = senders });
    try o.put(arena, "args", try definition(arena, typeDef(method.args), &defs));
    try o.put(arena, "result", try definition(arena, typeDef(method.result), &defs));
    if (defs.count() > 0) try o.put(arena, "$defs", .{ .object = defs });
    return .{ .object = o };
}

/// One type as a JSON Schema that stands alone: the types that it names are
/// in its own `$defs` (an MCP tool's `inputSchema` and `outputSchema`).
pub fn schema(arena: std.mem.Allocator, type_name: []const u8) error{OutOfMemory}!Value {
    var defs: ObjectMap = .empty;
    var root = try definition(arena, typeDef(type_name), &defs);
    if (defs.count() > 0) try root.object.put(arena, "$defs", .{ .object = defs });
    return root;
}

fn typeDef(name: []const u8) metadata.TypeDef {
    for (metadata.metadata.types) |t| if (std.mem.eql(u8, t.name, name)) return t;
    // `build` collects every type that a method holds.
    unreachable;
}

/// The schema of a wire type (`Field.type`). A named type goes into `defs`
/// once, so that a tree that holds itself (`SplitNode`) ends.
fn schemaOf(arena: std.mem.Allocator, wire: []const u8, defs: *ObjectMap) error{OutOfMemory}!Value {
    var o: ObjectMap = .empty;
    if (wire[0] == '[') {
        try o.put(arena, "type", .{ .string = "array" });
        try o.put(arena, "items", try schemaOf(arena, wire[1 .. wire.len - 1], defs));
        return .{ .object = o };
    }
    const json_type: ?[]const u8 = if (std.mem.eql(u8, wire, "bool"))
        "boolean"
    else if (std.mem.eql(u8, wire, "f64"))
        "number"
    else if (std.mem.eql(u8, wire, "str") or std.mem.eql(u8, wire, "bin") or std.mem.eql(u8, wire, "secret"))
        "string"
    else
        null;
    if (json_type) |t| {
        try o.put(arena, "type", .{ .string = t });
        return .{ .object = o };
    }
    if (intRange(wire)) |range| {
        try o.put(arena, "type", .{ .string = "integer" });
        try o.put(arena, "minimum", .{ .integer = range[0] });
        try o.put(arena, "maximum", if (range[1]) |max| .{ .integer = max } else .{ .number_string = "18446744073709551615" });
        return .{ .object = o };
    }
    if (!defs.contains(wire)) {
        // In place first, so that a type that holds itself stops here.
        try defs.put(arena, wire, .null);
        const def = try definition(arena, typeDef(wire), defs);
        try defs.put(arena, wire, def);
    }
    try o.put(arena, "$ref", .{ .string = try std.fmt.allocPrint(arena, "#/$defs/{s}", .{wire}) });
    return .{ .object = o };
}

/// The minimum and the maximum of an integer type; null for the maximum of
/// `u64`, which does not fit an `i64`.
fn intRange(wire: []const u8) ?struct { i64, ?i64 } {
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        if (std.mem.eql(u8, wire, @typeName(T)))
            return .{ std.math.minInt(T), if (T == u64) null else std.math.maxInt(T) };
    }
    return null;
}

fn definition(arena: std.mem.Allocator, t: metadata.TypeDef, defs: *ObjectMap) error{OutOfMemory}!Value {
    var o: ObjectMap = .empty;
    switch (t.kind) {
        .@"struct" => {
            var properties: ObjectMap = .empty;
            var required: std.json.Array = .init(arena);
            for (t.fields) |f| {
                var field = try schemaOf(arena, f.type, defs);
                if (f.doc) |d| try field.object.put(arena, "description", .{ .string = d });
                if (f.default) |d| try field.object.put(arena, "default", try defaultValue(arena, d));
                try putLimits(arena, &field.object, f);
                try properties.put(arena, f.name, field);
                if (!f.optional and f.default == null) try required.append(.{ .string = f.name });
            }
            try o.put(arena, "type", .{ .string = "object" });
            try o.put(arena, "properties", .{ .object = properties });
            if (required.items.len > 0) try o.put(arena, "required", .{ .array = required });
            try o.put(arena, "additionalProperties", .{ .bool = false });
        },
        .@"enum" => {
            var cases: std.json.Array = .init(arena);
            // `unknown` is the tag of a later build's case: no one sends it.
            for (t.cases) |c| if (!std.mem.eql(u8, c, "unknown")) try cases.append(.{ .string = c });
            try o.put(arena, "type", .{ .string = "string" });
            try o.put(arena, "enum", .{ .array = cases });
        },
        .@"union" => {
            var one_of: std.json.Array = .init(arena);
            for (t.variants) |v| {
                if (std.mem.eql(u8, v.name, "unknown")) continue;
                var tag: ObjectMap = .empty;
                try tag.put(arena, "const", .{ .string = v.name });
                var properties: ObjectMap = .empty;
                try properties.put(arena, "t", .{ .object = tag });
                var required: std.json.Array = .init(arena);
                try required.append(.{ .string = "t" });
                if (v.type) |payload| {
                    try properties.put(arena, "a", try schemaOf(arena, payload, defs));
                    try required.append(.{ .string = "a" });
                }
                var case: ObjectMap = .empty;
                try case.put(arena, "type", .{ .string = "object" });
                try case.put(arena, "properties", .{ .object = properties });
                try case.put(arena, "required", .{ .array = required });
                try case.put(arena, "additionalProperties", .{ .bool = false });
                try one_of.append(.{ .object = case });
            }
            try o.put(arena, "oneOf", .{ .array = one_of });
        },
    }
    return .{ .object = o };
}

/// The limits of a field, as the JSON Schema keywords. The schema's
/// `minimum` and `maximum` of an integer type give way to the field's own.
/// `minLength` and `maxLength` count characters in JSON Schema, and the
/// server counts bytes: the doc of each such field says so.
fn putLimits(arena: std.mem.Allocator, o: *ObjectMap, f: metadata.Field) error{OutOfMemory}!void {
    if (f.min_length) |v| try o.put(arena, "minLength", .{ .integer = @intCast(v) });
    if (f.max_length) |v| try o.put(arena, "maxLength", .{ .integer = @intCast(v) });
    if (f.min_items) |v| try o.put(arena, "minItems", .{ .integer = @intCast(v) });
    if (f.minimum) |v| try o.put(arena, "minimum", .{ .integer = v });
    if (f.maximum) |v| try o.put(arena, "maximum", .{ .integer = v });
}

/// `Field.default` is JSON, except an enum tag, which is bare.
fn defaultValue(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .string = text },
    };
}

// ── call: JSON to the wire and back ─────────────────────────────────────────

/// Where `fromJson` found a fault: the path to it and what is wrong.
pub const Fault = struct {
    path: std.ArrayList(u8) = .empty,
    message: []const u8 = "",
};

/// `value` as a `T`, with the decoder's rules: a missing field takes its
/// default, or null when it is optional. A key that `T` does not have is a
/// fault, because it is a mistake, not a later build's field.
pub fn fromJson(comptime T: type, arena: std.mem.Allocator, value: Value, fault: *Fault) error{ OutOfMemory, Invalid }!T {
    switch (T) {
        msgpack.Raw => @compileError("no JSON form for a raw value: give the field a type"),
        msgpack.Bin, msgpack.Secret => return .{ .bytes = try expectString(value, fault) },
        []const u8 => return expectString(value, fault),
        else => {},
    }
    if (comptime msgpack.isText(T)) return .{ .text = try expectString(value, fault) };
    switch (@typeInfo(T)) {
        .bool => return switch (value) {
            .bool => |b| b,
            else => wrong(fault, "a boolean"),
        },
        .int => {
            const n: ?T = switch (value) {
                .integer => |i| std.math.cast(T, i),
                .number_string => |s| std.fmt.parseInt(T, s, 10) catch null,
                else => null,
            };
            return n orelse wrong(fault, "an integer from " ++ std.fmt.comptimePrint("{d} to {d}", .{ std.math.minInt(T), std.math.maxInt(T) }));
        },
        .float => return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => wrong(fault, "a number"),
        },
        .@"enum" => |e| {
            const s = try expectString(value, fault);
            inline for (e.field_names) |name| {
                if (comptime std.mem.eql(u8, name, "unknown")) continue;
                if (std.mem.eql(u8, s, name)) return @field(T, name);
            }
            return wrong(fault, "one of " ++ comptime enumCases(T));
        },
        .optional => |o| return if (value == .null) null else try fromJson(o.child, arena, value, fault),
        .pointer => |p| {
            if (p.size == .one) {
                const item = try arena.create(p.child);
                item.* = try fromJson(p.child, arena, value, fault);
                return item;
            }
            const list = switch (value) {
                .array => |a| a.items,
                else => return wrong(fault, "an array"),
            };
            const items = try arena.alloc(p.child, list.len);
            for (list, items, 0..) |v, *item, i| {
                const len = fault.path.items.len;
                try fault.path.print(arena, "[{d}]", .{i});
                item.* = try fromJson(p.child, arena, v, fault);
                fault.path.shrinkRetainingCapacity(len);
            }
            return items;
        },
        .@"struct" => |s| {
            const map = switch (value) {
                .object => |o| o,
                else => return wrong(fault, "an object"),
            };
            var result: T = undefined;
            var it = map.iterator();
            next: while (it.next()) |entry| {
                inline for (s.field_names) |name| {
                    if (std.mem.eql(u8, entry.key_ptr.*, name)) continue :next;
                }
                try enterKey(arena, fault, entry.key_ptr.*);
                return unknownKey(fault);
            }
            inline for (s.field_names, s.field_types, s.field_attrs) |name, F, attrs| {
                const len = fault.path.items.len;
                try enterKey(arena, fault, name);
                if (map.get(name)) |v| {
                    @field(result, name) = try fromJson(F, arena, v, fault);
                } else if (attrs.defaultValue(F)) |default| {
                    @field(result, name) = default;
                } else if (@typeInfo(F) == .optional) {
                    @field(result, name) = null;
                } else {
                    return wrong(fault, "a value: the key is required");
                }
                fault.path.shrinkRetainingCapacity(len);
            }
            return result;
        },
        .@"union" => |u| {
            const map = switch (value) {
                .object => |o| o,
                else => return wrong(fault, "an object {\"t\": tag, \"a\": payload}"),
            };
            const tag_len = fault.path.items.len;
            var keys = map.iterator();
            while (keys.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "t") or std.mem.eql(u8, key, "a")) continue;
                try enterKey(arena, fault, key);
                return unknownKey(fault);
            }
            try enterKey(arena, fault, "t");
            const tag = try expectString(map.get("t") orelse .null, fault);
            fault.path.shrinkRetainingCapacity(tag_len);
            inline for (u.field_names, u.field_types) |name, P| {
                if (comptime std.mem.eql(u8, name, "unknown")) continue;
                if (std.mem.eql(u8, tag, name)) {
                    if (P == void) return @unionInit(T, name, {});
                    try enterKey(arena, fault, "a");
                    const payload = try fromJson(P, arena, map.get("a") orelse return wrong(fault, "a value: the key is required"), fault);
                    fault.path.shrinkRetainingCapacity(tag_len);
                    return @unionInit(T, name, payload);
                }
            }
            try enterKey(arena, fault, "t");
            return wrong(fault, "one of " ++ comptime enumCases(@typeInfo(T).@"union".tag_type.?));
        },
        else => @compileError("no JSON form for " ++ @typeName(T)),
    }
}

fn enterKey(arena: std.mem.Allocator, fault: *Fault, key: []const u8) error{OutOfMemory}!void {
    try fault.path.print(arena, ".{s}", .{key});
}

fn expectString(value: Value, fault: *Fault) error{Invalid}![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => wrong(fault, "a string"),
    };
}

fn wrong(fault: *Fault, comptime expected: []const u8) error{Invalid} {
    fault.message = "expected " ++ expected;
    return error.Invalid;
}

fn unknownKey(fault: *Fault) error{Invalid} {
    fault.message = "not a key of this type";
    return error.Invalid;
}

fn enumCases(comptime E: type) []const u8 {
    comptime {
        var text: []const u8 = "";
        for (std.meta.fieldNames(E)) |name| {
            if (std.mem.eql(u8, name, "unknown")) continue;
            text = text ++ (if (text.len == 0) "" else ", ") ++ name;
        }
        return text;
    }
}

/// A decoded value as JSON, with the keys of the wire. A null optional field
/// is left out, as the encoder leaves it out. `bin` that is not UTF-8 gets
/// U+FFFD for each bad byte: JSON has no bytes.
pub fn toJson(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}!Value {
    const T = @TypeOf(value);
    switch (T) {
        msgpack.Bin => return .{ .string = try utf8(arena, value.bytes) },
        msgpack.Secret => @compileError("a result never holds a secret"),
        msgpack.Raw => @compileError("no JSON form for a raw value: give the field a type"),
        []const u8 => return .{ .string = value },
        else => {},
    }
    if (comptime msgpack.isText(T)) return .{ .string = value.text };
    switch (@typeInfo(T)) {
        .bool => return .{ .bool = value },
        .int => return if (std.math.cast(i64, value)) |i|
            .{ .integer = i }
        else
            .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{value}) },
        .float => return .{ .float = value },
        .@"enum" => return .{ .string = @tagName(value) },
        .optional => return if (value) |v| toJson(arena, v) else .null,
        .pointer => |p| {
            if (p.size == .one) return toJson(arena, value.*);
            var list: std.json.Array = .init(arena);
            for (value) |item| try list.append(try toJson(arena, item));
            return .{ .array = list };
        },
        .@"struct" => |s| {
            var map: ObjectMap = .empty;
            inline for (s.field_names, s.field_types) |name, F| {
                const v = @field(value, name);
                if (@typeInfo(F) == .optional) {
                    if (v) |inner| try map.put(arena, name, try toJson(arena, inner));
                } else try map.put(arena, name, try toJson(arena, v));
            }
            return .{ .object = map };
        },
        .@"union" => {
            var map: ObjectMap = .empty;
            try map.put(arena, "t", .{ .string = @tagName(value) });
            switch (value) {
                inline else => |payload| if (@TypeOf(payload) != void)
                    try map.put(arena, "a", try toJson(arena, payload)),
            }
            return .{ .object = map };
        },
        else => @compileError("no JSON form for " ++ @typeName(T)),
    }
}

fn utf8(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 0 and i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..len])) {
            try out.appendSlice(arena, bytes[i..][0..len]);
            i += len;
        } else {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "api lists only the methods that a local client may send, each with a doc" {
    try testing.expect(find("session.send") != null);
    try testing.expect(find("ping") != null);
    for (methods) |method| try testing.expect(method.doc != null);
    // A session's own messages are not methods; no method of a session
    // connection alone is listed.
    inline for (m.methods) |M| {
        try testing.expectEqual(m.maySend(M, .local), find(M.name) != null);
    }
}

test "describe gives a JSON Schema with the required keys and the defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = (try describe(a, find("session.send").?)).object;
    const args = d.get("args").?.object;
    try testing.expectEqualStrings("object", args.get("type").?.string);
    const props = args.get("properties").?.object;
    try testing.expectEqualStrings("string", props.get("text").?.object.get("type").?.string);
    try testing.expect(props.get("submit").?.object.get("default").?.bool);
    const required = args.get("required").?.array.items;
    try testing.expectEqual(2, required.len);
    try testing.expectEqualStrings("id", required[0].string);
    try testing.expectEqualStrings("text", required[1].string);
    try testing.expectEqual(null, d.get("$defs"));
}

test "describe gives the doc of each field as description, and its limits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const send = (try describe(a, find("session.send").?)).object.get("args").?.object.get("properties").?.object;
    const text = send.get("text").?.object;
    try testing.expectEqualStrings("The text to type. The limit is in bytes.", text.get("description").?.string);
    try testing.expectEqual(m.send_max, text.get("maxLength").?.integer);
    try testing.expect(send.get("submit").?.object.get("description") != null);

    const run = (try describe(a, find("command.run").?)).object.get("args").?.object.get("properties").?.object;
    try testing.expectEqual(1, run.get("argv").?.object.get("minItems").?.integer);
    // The field's own limits win over the range of its type.
    const timeout = run.get("timeout_ms").?.object;
    try testing.expectEqual(1, timeout.get("minimum").?.integer);
    try testing.expectEqual(m.run_timeout_max_ms, timeout.get("maximum").?.integer);
    try testing.expectEqual(5000, timeout.get("default").?.integer);

    const secret = (try describe(a, find("link.open").?)).object.get("args").?.object.get("properties").?.object.get("secret").?.object;
    try testing.expectEqual(m.link_secret_len, secret.get("minLength").?.integer);
    try testing.expectEqual(m.link_secret_len, secret.get("maxLength").?.integer);

    // A field with a named type keeps its $ref next to its description.
    const create = (try describe(a, find("session.create").?)).object.get("result").?.object.get("properties").?.object;
    try testing.expectEqualStrings("#/$defs/Session", create.get("session").?.object.get("$ref").?.string);
    try testing.expectEqualStrings("The new session.", create.get("session").?.object.get("description").?.string);
}

test "every field of each type that a listed method holds has a doc" {
    // The args, the result and each type in their `$defs`.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    var missing: usize = 0;
    for (methods) |method| {
        for ([_][]const u8{ method.args, method.result }) |name| missing += try fieldsWithoutDoc(name, &seen);
    }
    try testing.expectEqual(0, missing);
}

/// The fields with no doc in the type of the wire type `wire` and in each
/// type that it holds. It skips a type in `seen` and prints each field that
/// it counts.
fn fieldsWithoutDoc(wire: []const u8, seen: *std.StringHashMapUnmanaged(void)) !usize {
    if (wire[0] == '[') return fieldsWithoutDoc(wire[1 .. wire.len - 1], seen);
    const named = for (metadata.metadata.types) |t| {
        if (std.mem.eql(u8, t.name, wire)) break t;
    } else return 0;
    if ((try seen.getOrPut(testing.allocator, named.name)).found_existing) return 0;
    var missing: usize = 0;
    for (named.fields) |f| {
        if (f.doc == null) {
            std.debug.print("{s}.{s} has no doc\n", .{ named.name, f.name });
            missing += 1;
        }
        missing += try fieldsWithoutDoc(f.type, seen);
    }
    for (named.variants) |v| if (v.type) |payload| {
        missing += try fieldsWithoutDoc(payload, seen);
    };
    return missing;
}

test "describe gives a schema for every method" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (methods) |method| _ = try describe(arena_state.allocator(), method);
}

test "describe puts named types in $defs, and a tree that holds itself ends" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = (try describe(a, find("tab.create").?)).object;
    const root = d.get("args").?.object.get("properties").?.object.get("root").?.object;
    try testing.expectEqualStrings("#/$defs/SplitNode", root.get("$ref").?.string);
    const defs = d.get("$defs").?.object;
    const node = defs.get("SplitNode").?.object.get("oneOf").?.array.items;
    try testing.expectEqualStrings("pane", node[0].object.get("properties").?.object.get("t").?.object.get("const").?.string);
    try testing.expect(defs.get("Split") != null);
    const port = (try describe(a, find("link.open").?)).object.get("result").?.object.get("properties").?.object.get("port").?.object;
    try testing.expectEqualStrings("integer", port.get("type").?.string);
    try testing.expectEqual(65535, port.get("maximum").?.integer);
}

fn parse(a: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{});
}

test "fromJson reads the args as the server decodes them, and names a fault by its path" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fault: Fault = .{};
    const send = try fromJson(m.SessionSend.Args, a, try parse(a, "{\"id\": \"macterm-x\", \"text\": \"ls\"}"), &fault);
    try testing.expectEqualStrings("macterm-x", send.id);
    try testing.expectEqualStrings("ls", send.text.bytes);
    try testing.expect(send.submit);

    const cases = .{
        .{ "{\"id\": \"x\"}", ".text", "expected a value: the key is required" },
        .{ "{\"id\": \"x\", \"text\": \"ls\", \"sumbit\": false}", ".sumbit", "not a key of this type" },
        .{ "{\"id\": 3, \"text\": \"ls\"}", ".id", "expected a string" },
        .{ "[]", "", "expected an object" },
    };
    inline for (cases) |c| {
        fault = .{};
        try testing.expectError(error.Invalid, fromJson(m.SessionSend.Args, a, try parse(a, c[0]), &fault));
        try testing.expectEqualStrings(c[1], fault.path.items);
        try testing.expectEqualStrings(c[2], fault.message);
    }
    fault = .{};
    try testing.expectError(error.Invalid, fromJson(m.SessionCreate.Args, a, try parse(a, "{\"id\": \"x\", \"cols\": 70000, \"rows\": 24}"), &fault));
    try testing.expectEqualStrings(".cols", fault.path.items);
    try testing.expectEqualStrings("expected an integer from 0 to 65535", fault.message);
    fault = .{};
    try testing.expectError(error.Invalid, fromJson(m.SessionCreate.Args, a, try parse(a, "{\"id\": \"x\", \"cols\": 80, \"rows\": 24, \"command\": [\"sh\", 1]}"), &fault));
    try testing.expectEqualStrings(".command[1]", fault.path.items);
}

test "fromJson reads a tree, and toJson writes it back the same" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\{"t": "split", "a": {"id": "s1", "dir": "horizontal", "ratio": 0.25,
        \\  "first": {"t": "pane", "a": {"id": "p1", "session": "macterm-1"}},
        \\  "second": {"t": "pane", "a": {"id": "p2", "session": "macterm-2"}}}}
    ;
    var fault: Fault = .{};
    const SplitNode = @FieldType(m.TabCreate.Args, "root");
    const node = fromJson(SplitNode, a, try parse(a, text), &fault) catch |err| {
        std.debug.print("{s}: {s}\n", .{ fault.path.items, fault.message });
        return err;
    };
    try testing.expectEqual(.split, std.meta.activeTag(node));
    // Through the wire and back, as `api call` sends it.
    const decoded = try msgpack.decodeSlice(SplitNode, a, try msgpack.encodeAlloc(a, node));
    const back = try toJson(a, decoded);
    const split = back.object.get("a").?.object;
    try testing.expectEqual(0.25, split.get("ratio").?.float);
    try testing.expectEqualStrings("p2", split.get("second").?.object.get("a").?.object.get("id").?.string);

    // A union takes `t` and `a` only, and a payload case needs `a`.
    fault = .{};
    try testing.expectError(error.Invalid, fromJson(SplitNode, a, try parse(a, "{\"t\": \"pane\", \"a\": {\"id\": \"p1\", \"session\": \"s\"}, \"x\": 1}"), &fault));
    try testing.expectEqualStrings(".x", fault.path.items);
    fault = .{};
    try testing.expectError(error.Invalid, fromJson(SplitNode, a, try parse(a, "{\"t\": \"pane\"}"), &fault));
    try testing.expectEqualStrings(".a", fault.path.items);
    try testing.expectEqualStrings("expected a value: the key is required", fault.message);
    fault = .{};
    try testing.expectError(error.Invalid, fromJson(SplitNode, a, try parse(a, "{\"t\": \"leaf\", \"a\": {}}"), &fault));
    try testing.expectEqualStrings(".t", fault.path.items);
}

test "toJson leaves out null fields and writes bad UTF-8 as U+FFFD" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try toJson(a, m.SessionHistory.Result{ .text = .{ .bytes = "a\xffb" } });
    try testing.expectEqualStrings("a\u{FFFD}b", v.object.get("text").?.string);
    try testing.expect(!v.object.get("truncated").?.bool);
    const s = try toJson(a, m.Session{ .id = "macterm-1", .state = .running, .build = "b", .level = 3 });
    try testing.expectEqual(null, s.object.get("pid"));
    try testing.expectEqualStrings("running", s.object.get("state").?.string);
    const big = try toJson(a, m.ControlResume.Args{ .epoch = std.math.maxInt(u64), .seq = 1 });
    try testing.expectEqualStrings("18446744073709551615", big.object.get("epoch").?.number_string);
}
