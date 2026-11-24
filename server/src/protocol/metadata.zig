//! The schema of the protocol, read from `messages.zig` and the model by
//! comptime reflection (design/003 §3). One source for two readers: the
//! generator (`tools/schema.zig`) writes it as `server/schema/protocol.json`,
//! and `macterm api` (`cli/api.zig`) prints it, so the CLI's answer cannot
//! drift from the code (design/011 §4).

const std = @import("std");
const msgpack = @import("msgpack.zig");
const messages = @import("messages.zig");

const Bin = msgpack.Bin;
const Secret = msgpack.Secret;
const Raw = msgpack.Raw;

// ── Metadata ────────────────────────────────────────────────────────────────

pub const Field = struct {
    /// The key on the wire.
    name: []const u8,
    /// `bool`, `u8` to `u64`, `i8` to `i64`, `f64`, `str`, `bin`, `secret`,
    /// `raw`, `[T]` for an array, or the name of a type in `types`.
    type: []const u8,
    optional: bool = false,
    /// The value that a decoder uses when the key is not there: a number,
    /// `true` or `false`, an enum tag, `[]`, or a JSON string.
    default: ?[]const u8 = null,
    since: u32,
    /// One sentence for people: `T.field_doc.<name>` (`macterm api describe`
    /// shows it as `description`).
    doc: ?[]const u8 = null,
    /// The limits that the server checks: `T.field_limits.<name>`. Each one
    /// is a JSON Schema keyword. `min_length` and `max_length` are in bytes,
    /// for a `str`, a `bin` or a `secret`; `min_items` is for an array;
    /// `minimum` and `maximum` are for an integer.
    min_length: ?u64 = null,
    max_length: ?u64 = null,
    min_items: ?u64 = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
};

/// One case of a tagged union.
pub const Variant = struct {
    name: []const u8,
    /// The payload's wire type, as `Field.type`. Null for a case with none.
    type: ?[]const u8 = null,
};

pub const TypeDef = struct {
    /// The Zig name in its name space: `Hello`, `ChannelOpen.Args`, `Split`.
    name: []const u8,
    kind: enum { @"struct", @"enum", @"union" },
    fields: []const Field = &.{},
    cases: []const []const u8 = &.{},
    variants: []const Variant = &.{},
};

pub const Message = struct {
    /// The name on the wire.
    name: []const u8,
    /// Its type in `types`.
    type: []const u8,
    since: u32,
    senders: []const []const u8,
};

pub const Method = struct {
    name: []const u8,
    /// The Zig name of the method: `ChannelOpen`.
    type: []const u8,
    since: u32,
    senders: []const []const u8,
    args: []const u8,
    result: []const u8,
    /// One sentence for people (`macterm api`). Every method that a local
    /// client may send has one.
    doc: ?[]const u8 = null,
};

pub const Metadata = struct {
    level: u32,
    min_level: u32,
    trust: []const []const u8,
    /// The frozen first messages: `hello` and `refuse`.
    messages: []const Message,
    /// The types of the requests, responses, event batches and pane messages.
    envelopes: []const []const u8,
    methods: []const Method,
    events: []const Message,
    /// The messages on a pane channel, in `{t, a}`. Empty in metadata from
    /// before they were added.
    pane_messages: []const Message = &.{},
    types: []const TypeDef,
    /// The tags of `ErrorCode`. Empty in metadata from before they were
    /// listed.
    error_codes: []const []const u8 = &.{},
};

/// The schema of this build.
pub const metadata: Metadata = build();

fn build() Metadata {
    @setEvalBranchQuota(1_000_000);
    comptime {
        const handshake = .{ messages.Hello, messages.Refuse };
        const envelopes = .{ messages.Request, messages.Response, messages.EventBatch, messages.PaneMessage };

        var types: []const type = &.{};
        for (handshake) |T| types = collect(T, types);
        for (envelopes) |T| types = collect(T, types);
        for (messages.methods) |M| types = collect(M.Result, collect(M.Args, types));
        for (messages.events) |E| types = collect(E, types);
        for (messages.pane_messages) |P| types = collect(P, types);

        var handshake_out: [handshake.len]Message = undefined;
        for (handshake, 0..) |T, i| handshake_out[i] = message(T);
        var envelope_out: [envelopes.len][]const u8 = undefined;
        for (envelopes, 0..) |T, i| envelope_out[i] = shortName(T);
        var method_out: [messages.methods.len]Method = undefined;
        for (messages.methods, 0..) |M, i| {
            if (messages.maySend(M, .local) and !@hasDecl(M, "doc"))
                @compileError(M.name ++ ": a local client may send it, so it needs a doc");
            method_out[i] = .{
                .name = M.name,
                .type = shortName(M),
                .since = M.since,
                .senders = trustNames(M.senders),
                .args = shortName(M.Args),
                .result = shortName(M.Result),
                .doc = if (@hasDecl(M, "doc")) M.doc else null,
            };
        }
        var event_out: [messages.events.len]Message = undefined;
        for (messages.events, 0..) |E, i| event_out[i] = message(E);
        var pane_out: [messages.pane_messages.len]Message = undefined;
        for (messages.pane_messages, 0..) |P, i| pane_out[i] = message(P);
        const type_out = typeDefs(types);
        // Swift declares a nested type in an extension of its parent, so the
        // parent must be a method or a type of the schema.
        for (type_out) |t| {
            const dot = std.mem.lastIndexOfScalar(u8, t.name, '.') orelse continue;
            const parent = t.name[0..dot];
            const known = for (method_out) |m| {
                if (std.mem.eql(u8, m.type, parent)) break true;
            } else for (type_out) |o| {
                if (std.mem.eql(u8, o.name, parent)) break true;
            } else false;
            if (!known) @compileError(t.name ++ ": declare it in a method or in a type of the schema");
        }

        const trust = std.meta.fieldNames(messages.Trust);
        var trust_out: [trust.len][]const u8 = undefined;
        for (trust, 0..) |name, i| trust_out[i] = name;

        const codes = std.meta.fieldNames(messages.ErrorCode);
        var code_out: [codes.len][]const u8 = undefined;
        for (codes, 0..) |name, i| {
            checkName(name);
            code_out[i] = name;
        }

        const h = handshake_out;
        const e = envelope_out;
        const ms = method_out;
        const ev = event_out;
        const pm = pane_out;
        const ty = type_out;
        const tr = trust_out;
        const co = code_out;
        return .{
            .level = messages.level,
            .min_level = messages.min_level,
            .trust = &tr,
            .messages = &h,
            .envelopes = &e,
            .methods = &ms,
            .events = &ev,
            .pane_messages = &pm,
            .types = &ty,
            .error_codes = &co,
        };
    }
}

/// The definitions of `types`. Two types with one name are an error: the
/// Swift side would declare one of them twice.
pub fn typeDefs(comptime types: []const type) [types.len]TypeDef {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: [types.len]TypeDef = undefined;
        for (types, 0..) |T, i| {
            out[i] = typeDef(T);
            for (out[0..i]) |o| if (std.mem.eql(u8, o.name, out[i].name))
                @compileError("two types of the schema are named " ++ o.name ++ ": rename one");
        }
        return out;
    }
}

fn message(comptime T: type) Message {
    return .{
        .name = T.name,
        .type = shortName(T),
        .since = T.since,
        .senders = trustNames(T.senders),
    };
}

fn trustNames(comptime senders: []const messages.Trust) []const []const u8 {
    comptime {
        var out: [senders.len][]const u8 = undefined;
        for (senders, 0..) |t, i| out[i] = @tagName(t);
        const final = out;
        return &final;
    }
}

/// Adds `T` and every struct and enum that it holds to `list`.
pub fn collect(comptime T: type, comptime list: []const type) []const type {
    comptime {
        switch (T) {
            Bin, Secret, Raw, []const u8 => return list,
            else => {},
        }
        if (msgpack.isText(T)) return list;
        for (list) |L| if (L == T) return list;
        switch (@typeInfo(T)) {
            .optional => |o| return collect(o.child, list),
            .pointer => |p| return collect(p.child, list),
            .@"enum" => return list ++ &[_]type{T},
            .@"struct" => |s| {
                var out: []const type = list ++ &[_]type{T};
                for (s.field_types) |F| out = collect(F, out);
                return out;
            },
            .@"union" => |u| {
                var out: []const type = list ++ &[_]type{T};
                for (u.field_types) |F| out = collect(F, out);
                return out;
            },
            else => return list,
        }
    }
}

/// The files whose types the schema may hold. A type's name in the schema
/// is its name in its file, so a name must be unique across them all
/// (`build` checks).
const name_spaces = [_][]const u8{ "messages.", "model.", "tree." };

/// The name of a type declared in one of `name_spaces`, without its module
/// path.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // The marker nearest the end names the file that declares `T`.
    var start: ?usize = null;
    for (name_spaces) |marker| {
        const i = std.mem.lastIndexOf(u8, full, marker) orelse continue;
        if (start == null or i + marker.len > start.?) start = i + marker.len;
    }
    return full[start orelse @compileError("declare " ++ full ++ " by name in messages.zig or in the model") ..];
}

fn wireType(comptime T: type) []const u8 {
    switch (T) {
        bool => return "bool",
        Bin => return "bin",
        Secret => return "secret",
        Raw => return "raw",
        []const u8 => return "str",
        u8, u16, u32, u64, i8, i16, i32, i64, f64 => return @typeName(T),
        else => {},
    }
    if (msgpack.isText(T)) return "str";
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice and @typeInfo(p.child) != .optional)
            "[" ++ wireType(p.child) ++ "]"
        else if (p.size == .one and @typeInfo(p.child) != .optional)
            wireType(p.child)
        else
            @compileError("no wire type for " ++ @typeName(T)),
        .@"struct", .@"enum", .@"union" => shortName(T),
        else => @compileError("no wire type for " ++ @typeName(T)),
    };
}

fn typeDef(comptime T: type) TypeDef {
    comptime {
        switch (@typeInfo(T)) {
            .@"enum" => |e| {
                var cases: [e.field_names.len][]const u8 = undefined;
                for (e.field_names, 0..) |name, i| {
                    checkName(name);
                    cases[i] = name;
                }
                const final = cases;
                return .{ .name = shortName(T), .kind = .@"enum", .cases = &final };
            },
            .@"struct" => |s| {
                checkFieldDecl(T, "field_doc");
                checkFieldDecl(T, "field_limits");
                var fields: [s.field_names.len]Field = undefined;
                for (s.field_names, s.field_types, s.field_attrs, 0..) |name, F, attrs, i| {
                    checkName(name);
                    const optional = @typeInfo(F) == .optional;
                    const Inner = if (optional) @typeInfo(F).optional.child else F;
                    // Swift has no struct that holds itself: a pointer goes
                    // through a union, which is an `indirect enum` there.
                    if (@typeInfo(Inner) == .pointer and @typeInfo(Inner).pointer.size == .one)
                        @compileError(name ++ ": a pointer is allowed only as the payload of a union case");
                    if (optional and attrs.defaultValue(F) != null and attrs.defaultValue(F).? != null)
                        @compileError(name ++ ": an optional field has no default but null");
                    fields[i] = .{
                        .name = name,
                        .type = wireType(Inner),
                        .optional = optional,
                        .default = if (optional) null else if (attrs.defaultValue(F)) |d| defaultText(F, d) else null,
                        .since = fieldSince(T, name),
                        .doc = if (@hasDecl(T, "field_doc") and @hasField(@TypeOf(T.field_doc), name))
                            @as([]const u8, @field(T.field_doc, name))
                        else
                            null,
                    };
                    if (@hasDecl(T, "field_limits") and @hasField(@TypeOf(T.field_limits), name))
                        fields[i] = withLimits(fields[i], Inner, @field(T.field_limits, name));
                }
                const final = fields;
                return .{ .name = shortName(T), .kind = .@"struct", .fields = &final };
            },
            .@"union" => |u| {
                if (u.tag_type == null) @compileError(@typeName(T) ++ ": a union on the wire needs a tag");
                var variants: [u.field_names.len]Variant = undefined;
                for (u.field_names, u.field_types, 0..) |name, F, i| {
                    checkName(name);
                    if (std.mem.eql(u8, name, "unknown") and F != void)
                        @compileError(@typeName(T) ++ ": the unknown case has no payload");
                    variants[i] = .{ .name = name, .type = if (F == void) null else wireType(F) };
                }
                const final = variants;
                return .{ .name = shortName(T), .kind = .@"union", .variants = &final };
            },
            else => unreachable,
        }
    }
}

/// `T.field_doc` and `T.field_limits` name only fields of `T`, so that a
/// renamed field cannot lose its doc or its limits without a word.
fn checkFieldDecl(comptime T: type, comptime decl: []const u8) void {
    comptime {
        if (!@hasDecl(T, decl)) return;
        for (std.meta.fieldNames(@TypeOf(@field(T, decl)))) |name| {
            if (!@hasField(T, name)) @compileError(@typeName(T) ++ "." ++ decl ++ ": " ++ name ++ " is not a field");
        }
    }
}

/// `field` with the limits of `T.field_limits.<name>`. A limit that does not
/// apply to the field's type is an error.
fn withLimits(comptime field_in: Field, comptime Inner: type, comptime limits: anytype) Field {
    comptime {
        var field = field_in;
        for (std.meta.fieldNames(@TypeOf(limits))) |key| {
            const value = @field(limits, key);
            const wire = field.type;
            if (std.mem.eql(u8, key, "min_length") or std.mem.eql(u8, key, "max_length")) {
                if (!(std.mem.eql(u8, wire, "str") or std.mem.eql(u8, wire, "bin") or std.mem.eql(u8, wire, "secret")))
                    @compileError(field.name ++ ": " ++ key ++ " is for a str, a bin or a secret");
                @field(field, key) = value;
            } else if (std.mem.eql(u8, key, "min_items")) {
                if (wire[0] != '[') @compileError(field.name ++ ": min_items is for an array");
                field.min_items = value;
            } else if (std.mem.eql(u8, key, "minimum") or std.mem.eql(u8, key, "maximum")) {
                if (@typeInfo(Inner) != .int) @compileError(field.name ++ ": " ++ key ++ " is for an integer");
                if (value < std.math.minInt(Inner) or value > std.math.maxInt(Inner))
                    @compileError(field.name ++ ": " ++ key ++ " is out of the range of its type");
                @field(field, key) = value;
            } else @compileError(field.name ++ ": " ++ key ++ " is not a limit");
        }
        return field;
    }
}

/// A field's level: `T.field_since.<name>` for a field added after its type,
/// else the type's own `since`, else the `since` of the method whose `Args`
/// or `Result` it is, else 1. A new field in a type of an older
/// level must name its level in `field_since`; `check` refuses it if not.
fn fieldSince(comptime T: type, comptime name: []const u8) u32 {
    if (@hasDecl(T, "field_since") and @hasField(@TypeOf(T.field_since), name))
        return @field(T.field_since, name);
    if (@hasDecl(T, "since")) return T.since;
    for (messages.methods) |M| {
        if (T == M.Args or T == M.Result) return M.since;
    }
    return carriedSince(T);
}

/// The lowest `since` of the methods and events that carry `T` (the model's
/// types come with the messages of level 3). 1 for a type that a message of
/// level 1 carries, or that no message carries.
fn carriedSince(comptime T: type) u32 {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var lowest: ?u32 = null;
        for (messages.methods) |M| {
            for (collect(M.Result, collect(M.Args, &.{}))) |C| if (C == T) {
                lowest = @min(lowest orelse M.since, M.since);
            };
        }
        for (messages.events) |E| {
            for (collect(E, &.{})) |C| if (C == T) {
                lowest = @min(lowest orelse E.since, E.since);
            };
        }
        return lowest orelse 1;
    }
}

/// Names that the generated Swift uses for its own locals.
const reserved_names = [_][]const u8{ "self", "key", "reader", "writer", "key_count" };

/// A field name or an enum tag must be a snake_case identifier: the Swift
/// side compares it as a String, and only for ASCII is that the same as the
/// byte compare of the Zig side.
fn checkName(comptime name: []const u8) void {
    comptime {
        if (name.len == 0 or !std.ascii.isLower(name[0]))
            @compileError("'" ++ name ++ "' must start with a lowercase letter");
        for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_'))
            @compileError("'" ++ name ++ "' must be snake_case: a to z, 0 to 9 and _");
        if (std.mem.indexOf(u8, name, "__") != null or name[name.len - 1] == '_')
            @compileError("'" ++ name ++ "' has an _ that the Swift name cannot keep");
        for (reserved_names) |r| if (std.mem.eql(u8, r, name))
            @compileError("'" ++ name ++ "' is a name that the generated Swift uses");
    }
}

fn defaultText(comptime F: type, comptime value: F) []const u8 {
    if (F == bool) return if (value) "true" else "false";
    if (F == []const u8) {
        for (value) |c| if (c == '"' or c == '\\' or c < 0x20)
            @compileError("a default string has a quote, a backslash or a control character");
        return "\"" ++ value ++ "\"";
    }
    return switch (@typeInfo(F)) {
        .int => std.fmt.comptimePrint("{d}", .{value}),
        .float => if (std.math.isFinite(value))
            std.fmt.comptimePrint("{d}", .{value})
        else
            @compileError("a default float must be finite"),
        .@"enum" => @tagName(value),
        .pointer => if (value.len == 0) "[]" else @compileError("a default array must be empty"),
        // A struct whose own fields all have their defaults: `{}`.
        .@"struct" => if (std.meta.eql(value, F{})) "{}" else @compileError("a default struct must be .{}"),
        else => @compileError("no default of type " ++ @typeName(F)),
    };
}

pub fn writeMetadata(w: *std.Io.Writer, meta: Metadata) std.Io.Writer.Error!void {
    try std.json.Stringify.value(meta, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}
