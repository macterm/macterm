//! The ids of the model (design/010 §1). Each kind of thing has its own id
//! type, so the compiler refuses a tab id where a pane id goes. In JSON and
//! in MessagePack an id is a plain string, as before: the types change no
//! byte of `model.json`.
//!
//! An id is text: a UUID, or a short name in a test. A pane id is its
//! session id (design/004). Panes and splits share one namespace, so the
//! model compares their text (`nodeIdInUse`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProjectId = Id(.project);
pub const TabId = Id(.tab);
pub const PaneId = Id(.pane);
pub const SplitId = Id(.split);

/// A hash map keyed by an id.
pub fn Map(comptime K: type, comptime V: type) type {
    return std.HashMapUnmanaged(K, V, K.Context, std.hash_map.default_max_load_percentage);
}

const IdKind = enum { project, tab, pane, split };

/// A distinct type for each `kind`.
fn Id(comptime kind: IdKind) type {
    return struct {
        text: []const u8,

        const Self = @This();

        /// What the id names. Each value makes its own type.
        const id_kind = kind;

        /// A str on the wire, as in JSON (`msgpack.isText`).
        pub const wire_str = {};

        pub fn of(text: []const u8) Self {
            return .{ .text = text };
        }

        pub fn eql(x: Self, y: Self) bool {
            return std.mem.eql(u8, x.text, y.text);
        }

        pub fn isEmpty(x: Self) bool {
            return x.text.len == 0;
        }

        pub fn dupe(x: Self, a: Allocator) Allocator.Error!Self {
            return .{ .text = try a.dupe(u8, x.text) };
        }

        /// For a hash map keyed by this id (`Map`).
        pub const Context = struct {
            pub fn hash(_: Context, x: Self) u64 {
                return std.hash.Wyhash.hash(0, x.text);
            }
            pub fn eql(_: Context, x: Self, y: Self) bool {
                return x.eql(y);
            }
        };

        pub fn jsonStringify(x: Self, jw: anytype) !void {
            try jw.write(x.text);
        }

        pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            return .{ .text = try std.json.innerParse([]const u8, a, source, options) };
        }
    };
}
