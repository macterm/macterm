//! The schema of the protocol, read from `messages.zig` and the model by
//! comptime reflection (design/003 §3). `zig build schema` builds this
//! program into `zig-out/tools`. It is not in the shipped server.
//! `scripts/protocol.sh` runs it to write three files:
//!
//! - `metadata`: every message, method, event, type and field, with `since`
//!   and the trust levels that may send each one (`server/schema/protocol.json`);
//! - `swift`: the Swift types of the app (`Macterm/Protocol/MactermProtocol.generated.swift`);
//! - `fixtures`: frames that this Zig code encodes, which the Swift tests
//!   decode and encode again (`server/schema/frames.json`).
//!
//! `check` compares the metadata of this build with an older one: the
//! add-only rule of `messages.zig` as a test, no change to who may send a
//! message, and no saved secret in a reply or an event (design/006 §1).

const std = @import("std");
const protocol = @import("protocol");
const model = @import("model");
const msgpack = protocol.msgpack;
const messages = protocol.messages;
const frame = protocol.frame;

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
};

/// The schema of this build.
pub const metadata: Metadata = build();

fn build() Metadata {
    @setEvalBranchQuota(100_000);
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
        for (messages.methods, 0..) |M, i| method_out[i] = .{
            .name = M.name,
            .type = shortName(M),
            .since = M.since,
            .senders = trustNames(M.senders),
            .args = shortName(M.Args),
            .result = shortName(M.Result),
        };
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

        const h = handshake_out;
        const e = envelope_out;
        const ms = method_out;
        const ev = event_out;
        const pm = pane_out;
        const ty = type_out;
        const tr = trust_out;
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
        };
    }
}

/// The definitions of `types`. Two types with one name are an error: the
/// Swift side would declare one of them twice.
fn typeDefs(comptime types: []const type) [types.len]TypeDef {
    comptime {
        @setEvalBranchQuota(100_000);
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
fn collect(comptime T: type, comptime list: []const type) []const type {
    comptime {
        switch (T) {
            Bin, Secret, Raw, []const u8 => return list,
            else => {},
        }
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
                    };
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
    return 1;
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

// ── Check ───────────────────────────────────────────────────────────────────

pub const Base = enum {
    /// The metadata on `main`. Before a release, an addition may keep the
    /// level of `main`.
    main,
    /// The metadata of a release. Peers of that level are out, so an
    /// addition needs a level above it.
    release,
};

/// Writes one line for each change from `old` to `new` that an older peer
/// could not read, for each change to who may send a message, and for each
/// reply or event that holds a `secret`. Returns the count of lines. `old` is
/// null when there is no older metadata: only the secret check runs.
pub fn check(w: *std.Io.Writer, old: ?Metadata, new: Metadata, against: Base) std.Io.Writer.Error!usize {
    var n: usize = 0;

    if (new.types.len > max_types) {
        try w.print("{d} types: the check reads at most {d}\n", .{ new.types.len, max_types });
        return n + 1;
    }
    if (new.min_level > new.level) {
        try w.print("min_level {d} is over level {d}\n", .{ new.min_level, new.level });
        n += 1;
    }

    for (new.methods) |method| {
        if (holdsSecret(new, method.result)) {
            try w.print("method {s}: its result holds a secret\n", .{method.name});
            n += 1;
        }
    }
    for (new.events) |event| {
        if (holdsSecret(new, event.type)) {
            try w.print("event {s} holds a secret\n", .{event.name});
            n += 1;
        }
    }
    // A pane message goes to every client of the session, as an event does.
    for (new.pane_messages) |msg| {
        if (holdsSecret(new, msg.type)) {
            try w.print("pane message {s} holds a secret\n", .{msg.name});
            n += 1;
        }
    }

    const o = old orelse return n;

    if (new.level < o.level) {
        try w.print("level went down from {d} to {d}\n", .{ o.level, new.level });
        n += 1;
    }
    const level: NewLevel = .{ .level = new.level, .released = if (against == .release) o.level else null };

    n += try checkMessages(w, "message", o.messages, new.messages, level);
    n += try checkMessages(w, "event", o.events, new.events, level);
    n += try checkMessages(w, "pane message", o.pane_messages, new.pane_messages, level);

    for (o.methods) |om| {
        const nm = findName(Method, new.methods, om.name) orelse {
            try w.print("method {s} was removed\n", .{om.name});
            n += 1;
            continue;
        };
        if (nm.since != om.since) {
            try w.print("method {s}: since changed from {d} to {d}\n", .{ om.name, om.since, nm.since });
            n += 1;
        }
        if (!std.mem.eql(u8, nm.args, om.args) or !std.mem.eql(u8, nm.result, om.result)) {
            try w.print("method {s}: its args or result type changed\n", .{om.name});
            n += 1;
        }
        n += try checkSenders(w, "method", om.name, om.senders, nm.senders);
    }
    for (new.methods) |nm| {
        if (findName(Method, o.methods, nm.name) == null and !level.ok(nm.since)) {
            try w.print("method {s} is new, but {f}\n", .{ nm.name, level.why(nm.since) });
            n += 1;
        }
    }

    for (o.envelopes) |name| {
        for (new.envelopes) |e| {
            if (std.mem.eql(u8, e, name)) break;
        } else {
            try w.print("envelope {s} was removed\n", .{name});
            n += 1;
        }
    }

    for (new.types) |nt| {
        if (findName(TypeDef, o.types, nt.name) != null) continue;
        for (nt.fields) |nf| {
            if (!level.ok(nf.since)) {
                try w.print("{s}.{s} is new, but {f}\n", .{ nt.name, nf.name, level.why(nf.since) });
                n += 1;
            }
        }
    }

    for (o.types) |ot| {
        const nt = findName(TypeDef, new.types, ot.name) orelse {
            try w.print("type {s} was removed\n", .{ot.name});
            n += 1;
            continue;
        };
        if (nt.kind != ot.kind) {
            try w.print("type {s}: its kind changed\n", .{ot.name});
            n += 1;
            continue;
        }
        for (ot.cases) |case| {
            for (nt.cases) |c| {
                if (std.mem.eql(u8, c, case)) break;
            } else {
                try w.print("enum {s}: case {s} was removed\n", .{ ot.name, case });
                n += 1;
            }
        }
        // An older peer refuses a tag that it does not know, unless the enum
        // has `unknown`.
        const open = for (ot.cases) |c| {
            if (std.mem.eql(u8, c, "unknown")) break true;
        } else false;
        if (!open) for (nt.cases) |case| {
            for (ot.cases) |c| {
                if (std.mem.eql(u8, c, case)) break;
            } else {
                try w.print("enum {s}: case {s} is new, but the enum has no unknown case\n", .{ ot.name, case });
                n += 1;
            }
        };
        for (ot.variants) |ov| {
            const nv = findName(Variant, nt.variants, ov.name) orelse {
                try w.print("union {s}: case {s} was removed\n", .{ ot.name, ov.name });
                n += 1;
                continue;
            };
            if (!optionalEql(nv.type, ov.type)) {
                try w.print("union {s}: the payload of case {s} changed\n", .{ ot.name, ov.name });
                n += 1;
            }
        }
        // As for an enum: an older peer refuses a case that it does not
        // know, unless the union has `unknown`.
        const open_union = findName(Variant, ot.variants, "unknown") != null;
        if (!open_union) for (nt.variants) |nv| {
            if (findName(Variant, ot.variants, nv.name) == null) {
                try w.print("union {s}: case {s} is new, but the union has no unknown case\n", .{ ot.name, nv.name });
                n += 1;
            }
        };
        for (ot.fields) |of| {
            const nf = findName(Field, nt.fields, of.name) orelse {
                try w.print("{s}.{s} was removed\n", .{ ot.name, of.name });
                n += 1;
                continue;
            };
            if (!std.mem.eql(u8, nf.type, of.type) or nf.optional != of.optional or
                !optionalEql(nf.default, of.default))
            {
                try w.print("{s}.{s}: its type or default changed\n", .{ ot.name, of.name });
                n += 1;
            }
            if (nf.since != of.since) {
                try w.print("{s}.{s}: since changed from {d} to {d}\n", .{ ot.name, of.name, of.since, nf.since });
                n += 1;
            }
        }
        for (nt.fields) |nf| {
            if (findName(Field, ot.fields, nf.name) != null) continue;
            if (!nf.optional and nf.default == null) {
                try w.print("{s}.{s} is new, but it is not optional and has no default\n", .{ ot.name, nf.name });
                n += 1;
            }
            if (!level.ok(nf.since)) {
                try w.print("{s}.{s} is new, but {f}\n", .{ ot.name, nf.name, level.why(nf.since) });
                n += 1;
            }
        }
    }
    return n;
}

/// The levels that an addition may have. Against `main`, only the current
/// level. Against a release, any level over the release's, up to the current
/// one: an earlier change since the release may have raised the level already.
const NewLevel = struct {
    level: u32,
    released: ?u32,

    fn ok(l: NewLevel, since: u32) bool {
        const r = l.released orelse return since == l.level;
        return since > r and since <= l.level;
    }

    fn why(l: NewLevel, since: u32) std.fmt.Alt([3]?u32, formatWhy) {
        return .{ .data = .{ since, l.level, l.released } };
    }

    fn formatWhy(d: [3]?u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d[2]) |r| {
            if (d[1].? <= r) return w.print("level {d} is released: raise the level to {d}", .{ r, r + 1 });
            return w.print("its since is {d}, and it must be from {d} to {d}", .{ d[0].?, r + 1, d[1].? });
        }
        try w.print("its since is {d}, not {d}", .{ d[0].?, d[1].? });
    }
};

fn checkMessages(
    w: *std.Io.Writer,
    comptime what: []const u8,
    old: []const Message,
    new: []const Message,
    level: NewLevel,
) std.Io.Writer.Error!usize {
    var n: usize = 0;
    for (old) |om| {
        const nm = findName(Message, new, om.name) orelse {
            try w.print(what ++ " {s} was removed\n", .{om.name});
            n += 1;
            continue;
        };
        if (nm.since != om.since or !std.mem.eql(u8, nm.type, om.type)) {
            try w.print(what ++ " {s}: its since or type changed\n", .{om.name});
            n += 1;
        }
        n += try checkSenders(w, what, om.name, om.senders, nm.senders);
    }
    for (new) |nm| {
        if (findName(Message, old, nm.name) == null and !level.ok(nm.since)) {
            try w.print(what ++ " {s} is new, but {f}\n", .{ nm.name, level.why(nm.since) });
            n += 1;
        }
    }
    return n;
}

/// A sender that is added gives a peer of that trust a new power; one that
/// is removed refuses an older peer. Both are a line: a change of trust is
/// a decision of design/006, and the check makes it visible.
fn checkSenders(
    w: *std.Io.Writer,
    comptime what: []const u8,
    name: []const u8,
    old: []const []const u8,
    new: []const []const u8,
) std.Io.Writer.Error!usize {
    var n: usize = 0;
    for (new) |s| if (!containsName(old, s)) {
        try w.print(what ++ " {s}: sender {s} was added\n", .{ name, s });
        n += 1;
    };
    for (old) |s| if (!containsName(new, s)) {
        try w.print(what ++ " {s}: sender {s} was removed\n", .{ name, s });
        n += 1;
    };
    return n;
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn findName(comptime T: type, items: []const T, name: []const u8) ?T {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The most types that `holdsSecret` can track. `check` refuses more.
const max_types = 4096;

fn holdsSecret(meta: Metadata, type_name: []const u8) bool {
    // Each type is read once. A type that holds itself (a split of two
    // nodes) ends there, and the walk stays linear.
    var seen: [max_types]bool = @splat(false);
    return holdsSecretIn(meta, type_name, &seen);
}

fn holdsSecretIn(meta: Metadata, type_name: []const u8, seen: *[max_types]bool) bool {
    var t = type_name;
    while (t.len >= 2 and t[0] == '[') t = t[1 .. t.len - 1];
    if (std.mem.eql(u8, t, "secret")) return true;
    const i = for (meta.types, 0..) |def, i| {
        if (std.mem.eql(u8, def.name, t)) break i;
    } else return false;
    if (seen[i]) return false;
    seen[i] = true;
    const def = meta.types[i];
    for (def.fields) |f| if (holdsSecretIn(meta, f.type, seen)) return true;
    for (def.variants) |v| if (v.type) |vt| if (holdsSecretIn(meta, vt, seen)) return true;
    return false;
}

// ── Swift ───────────────────────────────────────────────────────────────────

pub fn writeSwift(w: *std.Io.Writer, meta: Metadata) std.Io.Writer.Error!void {
    try w.writeAll(
        \\import Foundation
        \\
        \\/// Generated by server/tools/schema.zig from server/src/protocol/messages.zig.
        \\/// Do not edit. Run `mise run protocol` after a change to the Zig schema.
        \\enum MactermProtocol {
        \\
    );
    try w.print("    /// The level that this build speaks. It counts additions to the protocol.\n", .{});
    try w.print("    static let level: UInt32 = {d}\n", .{meta.level});
    try w.print("    /// The lowest level that this build accepts from a peer.\n", .{});
    try w.print("    static let minLevel: UInt32 = {d}\n\n", .{meta.min_level});
    try w.writeAll("    /// How a connection came, and so what its peer may send (design/006 §2).\n");
    try w.writeAll("    enum Trust: String {\n");
    for (meta.trust) |t| try w.print("        case {f}\n", .{swiftName(t)});
    try w.writeAll("    }\n}\n");

    for (meta.methods) |method| {
        try w.print(
            \\
            \\extension MactermProtocol {{
            \\    enum {s}: ProtocolMethod {{
            \\        static let name = "{s}"
            \\        static let since: UInt32 = {d}
            \\        static let senders: [MactermProtocol.Trust] = {f}
            \\    }}
            \\}}
            \\
        , .{ method.type, method.name, method.since, swiftSenders(method.senders) });
    }

    for (meta.types) |t| try writeSwiftType(w, t);

    for (meta.messages) |msg| try writeSwiftMessage(w, msg);
    for (meta.events) |ev| try writeSwiftMessage(w, ev);
    for (meta.pane_messages) |pm| try writeSwiftMessage(w, pm);
}

fn writeSwiftMessage(w: *std.Io.Writer, msg: Message) std.Io.Writer.Error!void {
    try w.print(
        \\
        \\extension MactermProtocol.{s}: ProtocolMessage {{
        \\    static let name = "{s}"
        \\    static let since: UInt32 = {d}
        \\    static let senders: [MactermProtocol.Trust] = {f}
        \\}}
        \\
    , .{ msg.type, msg.name, msg.since, swiftSenders(msg.senders) });
}

fn writeSwiftType(w: *std.Io.Writer, t: TypeDef) std.Io.Writer.Error!void {
    const dot = std.mem.lastIndexOfScalar(u8, t.name, '.');
    const parent = if (dot) |i| t.name[0..i] else "";
    const leaf = if (dot) |i| t.name[i + 1 ..] else t.name;
    const sep: []const u8 = if (dot == null) "" else ".";

    switch (t.kind) {
        .@"enum" => {
            try w.print("\nextension MactermProtocol{s}{s} {{\n", .{ sep, parent });
            try w.print("    enum {s}: String, Equatable {{\n", .{leaf});
            for (t.cases) |c| try w.print("        case {f}\n", .{swiftName(c)});
            try w.writeAll("    }\n}\n");

            var has_unknown = false;
            for (t.cases) |c| {
                if (std.mem.eql(u8, c, "unknown")) has_unknown = true;
            }
            try w.print("\nextension MactermProtocol.{s}: ProtocolValue {{\n", .{t.name});
            try w.writeAll("    init(from reader: inout MessagePackReader) throws {\n");
            try w.writeAll("        let tag = try reader.readString()\n");
            if (has_unknown) {
                try w.writeAll("        self = Self(rawValue: tag) ?? .unknown\n");
            } else {
                try w.writeAll("        guard let value = Self(rawValue: tag) else { throw MessagePackError.unknownEnumTag(tag) }\n");
                try w.writeAll("        self = value\n");
            }
            try w.writeAll(
                \\    }
                \\
                \\    func encode(to writer: inout MessagePackWriter) {
                \\        writer.writeString(rawValue)
                \\    }
                \\}
                \\
            );
        },
        .@"struct" => {
            try w.print("\nextension MactermProtocol{s}{s} {{\n", .{ sep, parent });
            if (t.fields.len == 0) {
                try w.print("    struct {s}: Equatable {{}}\n}}\n", .{leaf});
            } else {
                try w.print("    struct {s}: Equatable {{\n", .{leaf});
                for (t.fields) |f| {
                    try w.print("        var {f}: {f}", .{ swiftCamel(f.name), swiftType(f.type) });
                    if (f.optional) {
                        try w.writeAll("?");
                    } else if (f.default) |d| {
                        try w.print(" = {f}", .{swiftDefault(f.type, d)});
                    }
                    try w.writeByte('\n');
                }
                try w.writeAll("    }\n}\n");
            }

            try w.print("\nextension MactermProtocol.{s}: ProtocolValue {{\n", .{t.name});
            try w.writeAll("    init(from reader: inout MessagePackReader) throws {\n");
            if (t.fields.len == 0) {
                try w.writeAll("        try reader.readMap { _, _ in false }\n");
            } else {
                for (t.fields) |f| try w.print("        var {f}: {f}?\n", .{ swiftCamel(f.name), swiftType(f.type) });
                try w.writeAll("        try reader.readMap { key, reader in\n");
                try w.writeAll("            switch key {\n");
                for (t.fields) |f| {
                    if (f.optional) {
                        try w.print("            case \"{s}\": {f} = try reader.readOptional({f}.self)\n", .{
                            f.name, swiftCamel(f.name), swiftType(f.type),
                        });
                    } else {
                        try w.print("            case \"{s}\": {f} = try {f}(from: &reader)\n", .{
                            f.name, swiftCamel(f.name), swiftType(f.type),
                        });
                    }
                }
                try w.writeAll("            default: return false\n");
                try w.writeAll("            }\n");
                try w.writeAll("            return true\n");
                try w.writeAll("        }\n");
                for (t.fields) |f| {
                    if (f.optional) {
                        try w.print("        self.{f} = {f}\n", .{ swiftCamel(f.name), swiftCamel(f.name) });
                    } else if (f.default) |d| {
                        try w.print("        self.{f} = {f} ?? {f}\n", .{ swiftCamel(f.name), swiftCamel(f.name), swiftDefault(f.type, d) });
                    } else {
                        try w.print("        self.{f} = try MessagePackReader.required({f}, \"{s}\")\n", .{
                            swiftCamel(f.name), swiftCamel(f.name), f.name,
                        });
                    }
                }
            }
            try w.writeAll("    }\n\n");

            try w.writeAll("    func encode(to writer: inout MessagePackWriter) {\n");
            var required: usize = 0;
            var optionals: usize = 0;
            for (t.fields) |f| {
                if (f.optional) optionals += 1 else required += 1;
            }
            if (optionals == 0) {
                try w.print("        writer.writeMapHeader({d})\n", .{required});
            } else {
                try w.print("        var keyCount = {d}\n", .{required});
                for (t.fields) |f| {
                    if (f.optional) try w.print("        if {f} != nil {{ keyCount += 1 }}\n", .{swiftCamel(f.name)});
                }
                try w.writeAll("        writer.writeMapHeader(keyCount)\n");
            }
            for (t.fields) |f| {
                if (f.optional) {
                    try w.print("        if let {f} {{\n", .{swiftCamel(f.name)});
                    try w.print("            writer.writeString(\"{s}\")\n", .{f.name});
                    try w.print("            {f}.encode(to: &writer)\n", .{swiftCamel(f.name)});
                    try w.writeAll("        }\n");
                } else {
                    try w.print("        writer.writeString(\"{s}\")\n", .{f.name});
                    try w.print("        {f}.encode(to: &writer)\n", .{swiftCamel(f.name)});
                }
            }
            try w.writeAll("    }\n}\n");
        },
        .@"union" => try writeSwiftUnion(w, t, sep, parent, leaf),
    }
}

/// A tagged union is an `indirect enum`, so that it may hold itself through
/// a struct (a split holds two nodes). On the wire it is `{t: tag, a:
/// payload}`, and the keys may come in either order.
fn writeSwiftUnion(w: *std.Io.Writer, t: TypeDef, sep: []const u8, parent: []const u8, leaf: []const u8) std.Io.Writer.Error!void {
    try w.print("\nextension MactermProtocol{s}{s} {{\n", .{ sep, parent });
    try w.print("    indirect enum {s}: Equatable {{\n", .{leaf});
    for (t.variants) |v| {
        if (v.type) |vt| {
            try w.print("        case {f}({f})\n", .{ swiftName(v.name), swiftType(vt) });
        } else {
            try w.print("        case {f}\n", .{swiftName(v.name)});
        }
    }
    try w.writeAll("    }\n}\n");

    const has_unknown = findName(Variant, t.variants, "unknown") != null;
    try w.print("\nextension MactermProtocol.{s}: ProtocolValue {{\n", .{t.name});
    try w.writeAll(
        \\    init(from reader: inout MessagePackReader) throws {
        \\        var tag: String?
        \\        var payload: ProtocolRaw?
        \\        try reader.readMap { key, reader in
        \\            switch key {
        \\            case "t": tag = try reader.readString()
        \\            case "a": payload = try ProtocolRaw(from: &reader)
        \\            default: return false
        \\            }
        \\            return true
        \\        }
        \\        switch try MessagePackReader.required(tag, "t") {
        \\
    );
    for (t.variants) |v| {
        if (v.type) |vt| {
            try w.print("        case \"{s}\": self = try .{f}(reader.decodePayload({f}.self, from: payload))\n", .{
                v.name, swiftName(v.name), swiftType(vt),
            });
        } else {
            try w.print("        case \"{s}\": self = .{f}\n", .{ v.name, swiftName(v.name) });
        }
    }
    if (has_unknown) {
        try w.writeAll("        default: self = .unknown\n");
    } else {
        try w.writeAll("        case let other: throw MessagePackError.unknownEnumTag(other)\n");
    }
    try w.writeAll(
        \\        }
        \\    }
        \\
        \\    func encode(to writer: inout MessagePackWriter) {
        \\        switch self {
        \\
    );
    for (t.variants) |v| {
        if (v.type != null) {
            try w.print("        case let .{f}(value):\n", .{swiftName(v.name)});
            try w.writeAll("            writer.writeMapHeader(2)\n");
        } else {
            try w.print("        case .{f}:\n", .{swiftName(v.name)});
            try w.writeAll("            writer.writeMapHeader(1)\n");
        }
        try w.writeAll("            writer.writeString(\"t\")\n");
        try w.print("            writer.writeString(\"{s}\")\n", .{v.name});
        if (v.type != null) {
            try w.writeAll("            writer.writeString(\"a\")\n");
            try w.writeAll("            value.encode(to: &writer)\n");
        }
    }
    try w.writeAll("        }\n    }\n}\n");
}

const swift_keywords = [_][]const u8{
    "as",       "associatedtype", "break",     "case",     "catch",  "class",     "continue",
    "default",  "defer",          "do",        "else",     "enum",   "extension", "fallthrough",
    "false",    "for",            "func",      "guard",    "if",     "import",    "in",
    "init",     "inout",          "is",        "let",      "nil",    "operator",  "private",
    "protocol", "public",         "repeat",    "rethrows", "return", "self",      "Self",
    "static",   "struct",         "super",     "switch",   "throw",  "throws",    "true",
    "try",      "Type",           "typealias", "var",      "where",  "while",     "internal",
    "deinit",   "fileprivate",    "subscript",
};

/// A Swift identifier, in backticks where it is a keyword.
fn swiftName(name: []const u8) std.fmt.Alt([]const u8, formatName) {
    return .{ .data = name };
}

fn formatName(name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (swift_keywords) |k| {
        if (std.mem.eql(u8, k, name)) return w.print("`{s}`", .{name});
    }
    try w.writeAll(name);
}

/// `min_level` as `minLevel`, in backticks where it is a keyword.
fn swiftCamel(name: []const u8) std.fmt.Alt([]const u8, formatCamel) {
    return .{ .data = name };
}

fn formatCamel(name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var upper = false;
    for (name) |c| {
        if (c == '_') {
            upper = true;
            continue;
        }
        if (len == buf.len) return error.WriteFailed;
        buf[len] = if (upper) std.ascii.toUpper(c) else c;
        len += 1;
        upper = false;
    }
    try formatName(buf[0..len], w);
}

fn swiftType(wire: []const u8) std.fmt.Alt([]const u8, formatType) {
    return .{ .data = wire };
}

fn formatType(wire: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (wire.len >= 2 and wire[0] == '[') {
        try w.writeByte('[');
        try formatType(wire[1 .. wire.len - 1], w);
        return w.writeByte(']');
    }
    const map = [_][2][]const u8{
        .{ "bool", "Bool" },             .{ "str", "String" },      .{ "bin", "ProtocolBin" },
        .{ "secret", "ProtocolSecret" }, .{ "raw", "ProtocolRaw" }, .{ "u8", "UInt8" },
        .{ "u16", "UInt16" },            .{ "u32", "UInt32" },      .{ "u64", "UInt64" },
        .{ "i8", "Int8" },               .{ "i16", "Int16" },       .{ "i32", "Int32" },
        .{ "i64", "Int64" },             .{ "f64", "Double" },
    };
    for (map) |pair| {
        if (std.mem.eql(u8, pair[0], wire)) return w.writeAll(pair[1]);
    }
    try w.print("MactermProtocol.{s}", .{wire});
}

fn swiftDefault(wire: []const u8, text: []const u8) std.fmt.Alt([2][]const u8, formatDefault) {
    return .{ .data = .{ wire, text } };
}

fn formatDefault(pair: [2][]const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const wire = pair[0];
    const text = pair[1];
    const plain = [_][]const u8{ "bool", "str", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f64" };
    for (plain) |p| {
        if (std.mem.eql(u8, p, wire)) return w.writeAll(text);
    }
    if (std.mem.eql(u8, text, "[]")) return w.writeAll("[]");
    // An enum tag.
    try w.writeByte('.');
    try formatName(text, w);
}

fn swiftSenders(senders: []const []const u8) std.fmt.Alt([]const []const u8, formatSenders) {
    return .{ .data = senders };
}

fn formatSenders(senders: []const []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (senders, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('.');
        try formatName(s, w);
    }
    try w.writeByte(']');
}

// ── Main ────────────────────────────────────────────────────────────────────

/// `macterm-schema swift | metadata | fixtures` writes that file to stdout.
/// `macterm-schema check [--release] [old-metadata.json]` checks this schema
/// against an older one, and exits 1 on a problem. `--release` says that the
/// older one is a release's.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.next();

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const w = &out.interface;
    const kind = args.next() orelse fail(io, "macterm-schema needs swift, metadata, fixtures or check", .{});
    if (std.mem.eql(u8, kind, "swift")) {
        try writeSwift(w, metadata);
    } else if (std.mem.eql(u8, kind, "metadata")) {
        try writeMetadata(w, metadata);
    } else if (std.mem.eql(u8, kind, "fixtures")) {
        try writeFixtures(arena, w);
    } else if (std.mem.eql(u8, kind, "check")) {
        var against: Base = .main;
        var path: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--release")) against = .release else path = arg;
        }
        const old: ?Metadata = if (path) |p| blk: {
            const text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(16 * 1024 * 1024)) catch |err|
                fail(io, "cannot read {s}: {s}", .{ p, @errorName(err) });
            break :blk std.json.parseFromSliceLeaky(Metadata, arena, text, .{ .ignore_unknown_fields = true }) catch |err|
                fail(io, "cannot parse {s}: {s}", .{ p, @errorName(err) });
        } else null;
        const problems_found = try check(w, old, metadata, against);
        try w.flush();
        if (problems_found > 0) fail(io, "{d} problems in the protocol schema", .{problems_found});
    } else {
        fail(io, "unknown output {s}", .{kind});
    }
    try w.flush();
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &buf);
    err.interface.print("macterm-schema: " ++ fmt ++ "\n", args) catch {};
    err.interface.flush() catch {};
    std.process.exit(1);
}

// ── Fixtures ────────────────────────────────────────────────────────────────

pub const Fixture = struct {
    name: []const u8,
    /// One whole frame, header included, in lowercase hex.
    frame: []const u8,
    /// False for a frame from a later build: it decodes, but this build
    /// writes it with fewer keys.
    reencodes: bool = true,
};

/// The frames that the Swift tests decode and encode again. Each one has
/// the values that `ProtocolFixtureTests` expects.
pub fn fixtures(arena: std.mem.Allocator) ![]const Fixture {
    const m = messages;
    var list: std.ArrayList(Fixture) = .empty;

    const hello: m.Hello = .{
        .level = 1,
        .min_level = 1,
        .build = "2.0.0-tip.1",
        .role = .gui,
        .epoch = 0x1234_5678_9abc_def0,
        .caps = &.{ "tcc", "password-tty" },
    };
    try list.append(arena, try control(arena, "hello", hello, true));
    try list.append(arena, try control(arena, "refuse", m.Refuse{ .reason = "level_too_low", .needs_level = 4 }, true));

    var buf: std.Io.Writer.Allocating = .init(arena);
    try m.encodeRequest(&buf.writer, 7, m.ChannelOpen, .{ .session = "macterm-abc" });
    try list.append(arena, try control(arena, "channel.open request", Raw{ .bytes = try buf.toOwnedSlice() }, true));
    try m.encodeResult(&buf.writer, 7, m.ChannelOpen, .{ .channel = 2 });
    try list.append(arena, try control(arena, "channel.open result", Raw{ .bytes = try buf.toOwnedSlice() }, true));
    try m.encodeRequest(&buf.writer, 8, m.ChannelClose, .{ .channel = 2 });
    try list.append(arena, try control(arena, "channel.close request", Raw{ .bytes = try buf.toOwnedSlice() }, true));
    try m.encodeResult(&buf.writer, 8, m.ChannelClose, .{});
    try list.append(arena, try control(arena, "channel.close result", Raw{ .bytes = try buf.toOwnedSlice() }, true));

    try list.append(arena, try control(arena, "error", m.Response{
        .re = 9,
        .err = .{ .code = "unknown_method", .message = "No method pane.fly.", .level = 3 },
    }, true));
    try list.append(arena, try control(arena, "events", m.EventBatch{ .seq = 41, .ev = &.{
        .{ .e = "pane.title", .a = .{ .bytes = &.{ 0x81, 0xa1, 't', 0xa2, 'h', 'x' } } },
        .{ .e = "pane.bell" },
    } }, true));

    // A hello from a later build: a new field, a new cap and a new role.
    try list.append(arena, try control(arena, "later hello", .{
        .level = @as(u32, 9),
        .min_level = @as(u32, 1),
        .build = @as([]const u8, "3.0.0"),
        .role = @as([]const u8, "relay"),
        .epoch = @as(u64, 1),
        .caps = @as([]const []const u8, &.{ "tcc", "teleport" }),
        .region = .{ .name = @as([]const u8, "eu"), .ids = @as([]const u64, &.{ 1, 70000 }) },
    }, false));

    try m.encodePane(&buf.writer, m.Attach, .{ .cols = 120, .rows = 40 });
    try list.append(arena, try pane(arena, "attach", try buf.toOwnedSlice()));
    try m.encodePane(&buf.writer, m.Exit, .{ .code = 130 });
    try list.append(arena, try pane(arena, "exit", try buf.toOwnedSlice()));
    try m.encodePane(&buf.writer, m.Claim, .{});
    try list.append(arena, try pane(arena, "claim", try buf.toOwnedSlice()));

    var out: std.Io.Writer.Allocating = .init(arena);
    try frame.write(&out.writer, .{ .channel = 3, .kind = .bytes, .body = "ls\r" });
    try list.append(arena, .{ .name = "pane bytes", .frame = try hex(arena, out.written()) });

    return list.toOwnedSlice(arena);
}

fn control(arena: std.mem.Allocator, name: []const u8, value: anytype, reencodes: bool) !Fixture {
    var out: std.Io.Writer.Allocating = .init(arena);
    const body = try msgpack.encodeAlloc(arena, value);
    try frame.write(&out.writer, .{ .channel = frame.control_channel, .kind = .msg, .body = body });
    return .{ .name = name, .frame = try hex(arena, out.written()), .reencodes = reencodes };
}

fn pane(arena: std.mem.Allocator, name: []const u8, body: []const u8) !Fixture {
    var out: std.Io.Writer.Allocating = .init(arena);
    try frame.write(&out.writer, .{ .channel = messages.pane_channel, .kind = .msg, .body = body });
    return .{ .name = name, .frame = try hex(arena, out.written()) };
}

fn hex(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const digits = "0123456789abcdef";
    const out = try arena.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 0x0f];
    }
    return out;
}

pub fn writeFixtures(arena: std.mem.Allocator, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(try fixtures(arena), .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Runs `check` on two metadata files in JSON, and returns its lines.
fn problems(arena: std.mem.Allocator, old_json: ?[]const u8, new_json: []const u8) ![]const u8 {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const new = try std.json.parseFromSliceLeaky(Metadata, arena, new_json, opts);
    const old = if (old_json) |j| try std.json.parseFromSliceLeaky(Metadata, arena, j, opts) else null;
    var out: std.Io.Writer.Allocating = .init(arena);
    const n = try check(&out.writer, old, new, .main);
    try testing.expectEqual(n, std.mem.count(u8, out.written(), "\n"));
    return out.written();
}

fn metadataJson(arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeMetadata(&out.writer, metadata);
    return out.written();
}

test "the metadata names every message, method and type" {
    try testing.expectEqual(messages.level, metadata.level);
    try testing.expectEqualStrings("hello", metadata.messages[0].name);
    try testing.expectEqualStrings("Hello", metadata.messages[0].type);
    try testing.expectEqual(messages.methods.len, metadata.methods.len);
    const open = findName(Method, metadata.methods, "channel.open").?;
    try testing.expectEqualStrings("ChannelOpen.Args", open.args);
    try testing.expectEqualStrings("local", open.senders[0]);

    const hello = findName(TypeDef, metadata.types, "Hello").?;
    try testing.expectEqualStrings("min_level", hello.fields[1].name);
    try testing.expectEqualStrings("Role", hello.fields[3].type);
    try testing.expectEqualStrings("[str]", hello.fields[5].type);

    const req = findName(TypeDef, metadata.types, "Request").?;
    try testing.expectEqualStrings("raw", req.fields[2].type);
    try testing.expect(req.fields[2].optional);

    const role = findName(TypeDef, metadata.types, "Role").?;
    try testing.expectEqual(.@"enum", role.kind);
    try testing.expectEqualStrings("unknown", role.cases[role.cases.len - 1]);
}

test "the metadata of this build passes the check against itself" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try metadataJson(arena);
    try testing.expectEqualStrings("", try problems(arena, json, json));
    try testing.expectEqualStrings("", try problems(arena, null, json));
}

const base =
    \\{"level": 1, "min_level": 1, "trust": ["local"],
    \\ "messages": [{"name": "hello", "type": "Hello", "since": 1, "senders": ["local"]}],
    \\ "envelopes": ["Request"],
    \\ "methods": [{"name": "pane.split", "type": "PaneSplit", "since": 1, "senders": ["local"],
    \\              "args": "PaneSplit.Args", "result": "PaneSplit.Result"}],
    \\ "events": [],
    \\ "types": [
    \\   {"name": "Hello", "kind": "struct", "fields": [{"name": "level", "type": "u32", "since": 1}]},
    \\   {"name": "Request", "kind": "struct", "fields": [{"name": "id", "type": "u64", "since": 1}]},
    \\   {"name": "Role", "kind": "enum", "cases": ["gui", "unknown"]},
    \\   {"name": "PaneSplit.Args", "kind": "struct", "fields": [
    \\     {"name": "pane", "type": "str", "since": 1},
    \\     {"name": "ratio", "type": "u8", "default": "50", "since": 1}]},
    \\   {"name": "PaneSplit.Result", "kind": "struct", "fields": []}]}
;

/// `base` with one piece of text replaced.
fn edit(arena: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    try testing.expect(std.mem.count(u8, base, from) == 1);
    return std.mem.replaceOwned(u8, arena, base, from, to);
}

test "the check refuses a removed field, message, method, type or case" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("", try problems(arena, base, base));

    const no_field = try edit(arena, ",\n     {\"name\": \"ratio\", \"type\": \"u8\", \"default\": \"50\", \"since\": 1}", "");
    try testing.expectEqualStrings("PaneSplit.Args.ratio was removed\n", try problems(arena, base, no_field));

    const no_case = try edit(arena, "[\"gui\", \"unknown\"]", "[\"unknown\"]");
    try testing.expectEqualStrings("enum Role: case gui was removed\n", try problems(arena, base, no_case));

    const no_method = try edit(arena, "\"pane.split\"", "\"pane.splat\"");
    try testing.expectEqualStrings(
        "method pane.split was removed\n",
        try problems(arena, base, no_method),
    );

    const no_message = try edit(arena, "\"name\": \"hello\"", "\"name\": \"hullo\"");
    try testing.expectEqualStrings("message hello was removed\n", try problems(arena, base, no_message));

    const no_type = try edit(arena, "\"name\": \"Role\"", "\"name\": \"Rule\"");
    try testing.expectEqualStrings("type Role was removed\n", try problems(arena, base, no_type));
}

test "a new enum case needs an unknown case in the enum" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const open = try edit(arena, "[\"gui\", \"unknown\"]", "[\"gui\", \"cli\", \"unknown\"]");
    try testing.expectEqualStrings("", try problems(arena, base, open));

    const closed_old = try edit(arena, "[\"gui\", \"unknown\"]", "[\"gui\"]");
    const closed_new = try edit(arena, "[\"gui\", \"unknown\"]", "[\"gui\", \"cli\"]");
    try testing.expectEqualStrings(
        "enum Role: case cli is new, but the enum has no unknown case\n",
        try problems(arena, closed_old, closed_new),
    );
}

test "the check refuses a changed type, default or since" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wider = try edit(arena, "\"type\": \"u32\"", "\"type\": \"u64\"");
    try testing.expectEqualStrings("Hello.level: its type or default changed\n", try problems(arena, base, wider));

    const optional = try edit(arena, "\"type\": \"str\", \"since\": 1", "\"type\": \"str\", \"optional\": true, \"since\": 1");
    try testing.expectEqualStrings("PaneSplit.Args.pane: its type or default changed\n", try problems(arena, base, optional));

    const default = try edit(arena, "\"default\": \"50\"", "\"default\": \"40\"");
    try testing.expectEqualStrings("PaneSplit.Args.ratio: its type or default changed\n", try problems(arena, base, default));

    const since = try edit(arena, "\"type\": \"u64\", \"since\": 1", "\"type\": \"u64\", \"since\": 2");
    try testing.expectEqualStrings("Request.id: since changed from 1 to 2\n", try problems(arena, base, since));
}

test "an addition needs the current level, and a new field needs a default" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // At level 1, a new optional field of level 1 is good.
    const good = try edit(arena, "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}", "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}, {\"name\": \"hint\", \"type\": \"str\", \"optional\": true, \"since\": 1}");
    try testing.expectEqualStrings("", try problems(arena, base, good));

    const required = try edit(arena, "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}", "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}, {\"name\": \"hint\", \"type\": \"str\", \"since\": 1}");
    try testing.expectEqualStrings(
        "Request.hint is new, but it is not optional and has no default\n",
        try problems(arena, base, required),
    );

    // The level went up to 2, but the new field says 1.
    const stale = try std.mem.replaceOwned(u8, arena, good, "{\"level\": 1", "{\"level\": 2");
    try testing.expectEqualStrings("Request.hint is new, but its since is 1, not 2\n", try problems(arena, base, stale));

    // A field of a new type has the current level too.
    const new_type = try std.mem.replaceOwned(u8, arena, try edit(arena, "{\"level\": 1", "{\"level\": 2"), "\"types\": [",
        \\"types": [{"name": "Size", "kind": "struct", "fields": [{"name": "rows", "type": "u16", "since": 1}]},
    );
    try testing.expectEqualStrings("Size.rows is new, but its since is 1, not 2\n", try problems(arena, base, new_type));

    const down = try edit(arena, "{\"level\": 1, \"min_level\": 1", "{\"level\": 0, \"min_level\": 0");
    try testing.expectEqualStrings("level went down from 1 to 0\n", try problems(arena, base, down));
}

test "no result and no event may hold a secret" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const leak = try edit(arena, "{\"name\": \"PaneSplit.Result\", \"kind\": \"struct\", \"fields\": []}",
        \\{"name": "PaneSplit.Result", "kind": "struct", "fields": [
        \\  {"name": "saved", "type": "[Saved]", "optional": true, "since": 1}]},
        \\{"name": "Saved", "kind": "struct", "fields": [{"name": "password", "type": "secret", "since": 1}]}
    );
    try testing.expectEqualStrings("method pane.split: its result holds a secret\n", try problems(arena, null, leak));

    const event = try edit(arena, "\"events\": []",
        \\"events": [{"name": "pane.prompt", "type": "Prompt", "since": 1, "senders": ["local"]}]
    );
    const event_leak = try std.mem.replaceOwned(u8, arena, event, "\"types\": [",
        \\"types": [{"name": "Prompt", "kind": "struct", "fields": [{"name": "typed", "type": "secret", "since": 1}]},
    );
    try testing.expectEqualStrings("event pane.prompt holds a secret\n", try problems(arena, base, event_leak));

    // A secret in a request's arguments is allowed: the GUI sends it to type
    // a password into a pane (design/006 §4).
    const args = try edit(arena, "{\"name\": \"pane\", \"type\": \"str\", \"since\": 1}", "{\"name\": \"pane\", \"type\": \"secret\", \"since\": 1}");
    try testing.expect(std.mem.indexOf(u8, try problems(arena, null, args), "secret") == null);
}

test "every fixture decodes as the message it names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = try fixtures(arena);
    for (list) |f| {
        const bytes = try arena.alloc(u8, f.frame.len / 2);
        _ = try std.fmt.hexToBytes(bytes, f.frame);
        const parsed = (try frame.parse(bytes)).?;
        try testing.expectEqual(bytes.len, parsed.len);
        if (parsed.frame.kind != .msg) continue;
        if (parsed.frame.channel == messages.pane_channel) {
            const msg = try msgpack.decodeSlice(messages.PaneMessage, arena, parsed.frame.body);
            try testing.expectEqualStrings(f.name, msg.t);
            continue;
        }
        const decoded = try messages.decodeControl(arena, parsed.frame.body);
        const expected: std.meta.Tag(messages.Control) = if (std.mem.endsWith(u8, f.name, "request"))
            .request
        else if (std.mem.endsWith(u8, f.name, "result") or std.mem.eql(u8, f.name, "error"))
            .response
        else if (std.mem.eql(u8, f.name, "events"))
            .events
        else if (std.mem.eql(u8, f.name, "refuse"))
            .refuse
        else
            .hello;
        try testing.expectEqual(expected, std.meta.activeTag(decoded));
    }
}

test "the Swift output names each type and field" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeSwift(&out.writer, metadata);
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "struct Hello: Equatable {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "var minLevel: UInt32\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "case \"min_level\": minLevel = try UInt32(from: &reader)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "enum ChannelOpen: ProtocolMethod {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "extension MactermProtocol.ChannelOpen {\n    struct Args") != null);
    try testing.expect(std.mem.indexOf(u8, s, "self = Self(rawValue: tag) ?? .unknown") != null);
}

test "Swift names: camel case and keywords" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("needsLevel", try std.fmt.bufPrint(&buf, "{f}", .{swiftCamel("needs_level")}));
    try testing.expectEqualStrings("`default`", try std.fmt.bufPrint(&buf, "{f}", .{swiftCamel("default")}));
    try testing.expectEqualStrings("[MactermProtocol.Event]", try std.fmt.bufPrint(&buf, "{f}", .{swiftType("[Event]")}));
    try testing.expectEqualStrings(".gui", try std.fmt.bufPrint(&buf, "{f}", .{swiftDefault("Role", "gui")}));
}

test "the check refuses a changed sender" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const wider = try edit(arena, "\"since\": 1, \"senders\": [\"local\"],\n              \"args\"", "\"since\": 1, \"senders\": [\"local\", \"remote\"],\n              \"args\"");
    try testing.expectEqualStrings("method pane.split: sender remote was added\n", try problems(arena, base, wider));

    const narrower = try edit(arena, "\"type\": \"Hello\", \"since\": 1, \"senders\": [\"local\"]", "\"type\": \"Hello\", \"since\": 1, \"senders\": []");
    try testing.expectEqualStrings("message hello: sender local was removed\n", try problems(arena, base, narrower));
}

test "against a release, an addition needs a level above the release" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const old = try std.json.parseFromSliceLeaky(Metadata, arena, base, opts);

    // A new optional field at level 1, the level of the release.
    const same_level = try edit(arena, "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}", "[{\"name\": \"id\", \"type\": \"u64\", \"since\": 1}, {\"name\": \"hint\", \"type\": \"str\", \"optional\": true, \"since\": 1}");
    try testing.expectEqualStrings("", try problems(arena, base, same_level));
    var out: std.Io.Writer.Allocating = .init(arena);
    const new = try std.json.parseFromSliceLeaky(Metadata, arena, same_level, opts);
    try testing.expectEqual(1, try check(&out.writer, old, new, .release));
    try testing.expectEqualStrings("Request.hint is new, but level 1 is released: raise the level to 2\n", out.written());

    // At level 2, it passes.
    const bumped = try std.mem.replaceOwned(u8, arena, same_level, "{\"level\": 1", "{\"level\": 2");
    const raised = try std.mem.replaceOwned(u8, arena, bumped, "\"optional\": true, \"since\": 1", "\"optional\": true, \"since\": 2");
    out.clearRetainingCapacity();
    try testing.expectEqual(0, try check(&out.writer, old, try std.json.parseFromSliceLeaky(Metadata, arena, raised, opts), .release));

    // Two raises since the release: an addition of either level passes, and
    // one of the released level does not.
    const twice = try std.mem.replaceOwned(u8, arena, raised, "{\"level\": 2", "{\"level\": 3");
    out.clearRetainingCapacity();
    try testing.expectEqual(0, try check(&out.writer, old, try std.json.parseFromSliceLeaky(Metadata, arena, twice, opts), .release));
    const stale = try std.mem.replaceOwned(u8, arena, twice, "\"optional\": true, \"since\": 2", "\"optional\": true, \"since\": 1");
    out.clearRetainingCapacity();
    try testing.expectEqual(1, try check(&out.writer, old, try std.json.parseFromSliceLeaky(Metadata, arena, stale, opts), .release));
    try testing.expectEqualStrings("Request.hint is new, but its since is 1, and it must be from 2 to 3\n", out.written());

    // No addition and no change of level: nothing to say.
    out.clearRetainingCapacity();
    try testing.expectEqual(0, try check(&out.writer, old, old, .release));
}

test "the check refuses a removed or changed union case, and a new one without unknown" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const with_union = try edit(arena, "\"types\": [",
        \\"types": [{"name": "Node", "kind": "union", "variants": [{"name": "pane", "type": "str"}, {"name": "split", "type": "u8"}]},
    );
    try testing.expectEqualStrings("", try problems(arena, with_union, with_union));

    const removed = try std.mem.replaceOwned(u8, arena, with_union, ", {\"name\": \"split\", \"type\": \"u8\"}", "");
    try testing.expectEqualStrings("union Node: case split was removed\n", try problems(arena, with_union, removed));

    const changed = try std.mem.replaceOwned(u8, arena, with_union, "\"type\": \"u8\"}]", "\"type\": \"u16\"}]");
    try testing.expectEqualStrings("union Node: the payload of case split changed\n", try problems(arena, with_union, changed));

    const added = try std.mem.replaceOwned(u8, arena, with_union, "\"type\": \"u8\"}]", "\"type\": \"u8\"}, {\"name\": \"tabs\"}]");
    try testing.expectEqualStrings("union Node: case tabs is new, but the union has no unknown case\n", try problems(arena, with_union, added));
}

test "a secret in a union's payload is found" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const leak = try edit(arena, "{\"name\": \"PaneSplit.Result\", \"kind\": \"struct\", \"fields\": []}",
        \\{"name": "PaneSplit.Result", "kind": "struct", "fields": [{"name": "node", "type": "Node", "since": 1}]},
        \\{"name": "Node", "kind": "union", "variants": [{"name": "empty"}, {"name": "saved", "type": "secret"}]}
    );
    try testing.expectEqualStrings("method pane.split: its result holds a secret\n", try problems(arena, null, leak));
}

test "the secret check reads a type that holds itself once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A result that holds a tree. Each split holds two nodes and 60 types
    // that hold the split again: a walk with no memory takes 2^60 steps.
    var types: std.Io.Writer.Allocating = .init(arena);
    const tw = &types.writer;
    try tw.writeAll(
        \\{"name": "PaneSplit.Result", "kind": "struct", "fields": [{"name": "root", "type": "Node", "since": 1}]},
        \\{"name": "Node", "kind": "union", "variants": [{"name": "leaf", "type": "u8"}, {"name": "split", "type": "Split"}]},
        \\{"name": "Split", "kind": "struct", "fields": [{"name": "a", "type": "Node", "since": 1}, {"name": "b", "type": "Hop0", "since": 1}]}
    );
    for (0..60) |i| try tw.print(",{{\"name\": \"Hop{d}\", \"kind\": \"struct\", \"fields\": [{{\"name\": \"a\", \"type\": \"{s}{d}\", \"since\": 1}}, {{\"name\": \"b\", \"type\": \"Split\", \"since\": 1}}]}}", .{ i, if (i == 59) "Lea" else "Hop", if (i == 59) 0 else i + 1 });
    try tw.writeAll(",{\"name\": \"Lea0\", \"kind\": \"struct\", \"fields\": [{\"name\": \"s\", \"type\": \"secret\", \"since\": 1}]}");
    const json = try edit(arena, "{\"name\": \"PaneSplit.Result\", \"kind\": \"struct\", \"fields\": []}", types.written());
    try testing.expectEqualStrings("method pane.split: its result holds a secret\n", try problems(arena, null, json));
    const clean = try std.mem.replaceOwned(u8, arena, json, "\"type\": \"secret\"", "\"type\": \"str\"");
    try testing.expectEqualStrings("", try problems(arena, null, clean));
}

/// The model's split tree, as the schema would carry it (design/010 §3).
const model_types = collect(model.tree.Node, &.{});

test "the model's tree has a schema: a union, a pointer and an f64" {
    const defs = comptime typeDefs(model_types);
    const node = findName(TypeDef, &defs, "Node").?;
    try testing.expectEqual(.@"union", node.kind);
    try testing.expectEqualStrings("pane", node.variants[0].name);
    try testing.expectEqualStrings("Pane", node.variants[0].type.?);
    // `*Split` on the wire is the split itself.
    try testing.expectEqualStrings("Split", node.variants[1].type.?);

    const split = findName(TypeDef, &defs, "Split").?;
    const ratio = findName(Field, split.fields, "ratio").?;
    try testing.expectEqualStrings("f64", ratio.type);
    try testing.expectEqualStrings("0.5", ratio.default.?);
    try testing.expectEqualStrings("Node", findName(Field, split.fields, "first").?.type);
    try testing.expectEqual(.@"enum", findName(TypeDef, &defs, "Dir").?.kind);
    try testing.expect(!protocol.holdsSecret(model.tree.Node));
}

test "the model's tree round-trips through MessagePack" {
    const tree = model.tree;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var split: tree.Split = .{
        .id = "s1",
        .dir = .vertical,
        .ratio = 0.3,
        .first = .{ .pane = .{ .id = "a", .session = "macterm-a" } },
        .second = .{ .pane = .{ .id = "b", .session = "macterm-b", .host = "box", .attention = .failed } },
    };
    const root: tree.Node = .{ .split = &split };
    const bytes = try msgpack.encodeAlloc(arena, root);
    const back = try msgpack.decodeSlice(tree.Node, arena, bytes);
    try testing.expectEqual(0.3, back.split.ratio);
    try testing.expectEqualStrings("box", back.split.second.pane.host.?);
    try testing.expectEqualSlices(u8, bytes, try msgpack.encodeAlloc(arena, back));
}

test "the Swift output of a union is an indirect enum on {t, a}" {
    const defs = comptime typeDefs(model_types);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (defs) |t| try writeSwiftType(&out.writer, t);
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "    indirect enum Node: Equatable {\n        case pane(MactermProtocol.Pane)\n        case split(MactermProtocol.Split)\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "case \"split\": self = try .split(reader.decodePayload(MactermProtocol.Split.self, from: payload))") != null);
    try testing.expect(std.mem.indexOf(u8, s, "case let other: throw MessagePackError.unknownEnumTag(other)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "var ratio: Double = 0.5\n") != null);
}
