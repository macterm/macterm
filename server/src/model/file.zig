//! `model.json` (design/010 §2): the model as JSON, and its load and save.
//!
//! The file has a `version`. A file with a newer version is refused, and the
//! caller must not write over it (`error.NewerVersion`): an older build
//! never destroys the data of a newer one. A file that does not parse, or
//! does not validate, is refused too, and nothing is written over it.
//!
//! Only `ModelData` is in the file. The zoom and the focus history of a tab
//! stay in memory (design/010 §1).
//!
//! The reader also takes a file of version 1, which had a list of
//! workspaces apart from the projects (design/010 §11). The writer writes
//! the current version only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Model = model.Model;

pub const LoadError = error{
    OutOfMemory,
    /// Not JSON, or not the shape of `Data`.
    Syntax,
    /// `version` is higher than this build writes. `peekVersion` has the
    /// number.
    NewerVersion,
    /// A fault in the model; `parse` gives it in its `fault` argument.
    Invalid,
};

/// The `version` of a file, if it has one.
pub fn peekVersion(gpa: Allocator, bytes: []const u8) ?u32 {
    const Head = struct { version: u32 };
    const parsed = std.json.parseFromSlice(Head, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.version;
}

/// Reads a model from JSON text. The model copies every string, so `bytes`
/// can go away. `fault` gets the first fault when the
/// result is `error.Invalid`.
pub fn parse(gpa: Allocator, bytes: []const u8, fault: *model.Fault) LoadError!Model {
    const v = peekVersion(gpa, bytes);
    if (v) |x| if (x > model.version) return error.NewerVersion;
    var m = Model.init(gpa);
    errdefer m.deinit();
    const a = m.arena.allocator();
    const options: std.json.ParseOptions = .{ .allocate = .alloc_always };
    if (v == 1) {
        const old = std.json.parseFromSliceLeaky(Version1, a, bytes, options) catch |err| return syntax(err);
        m.data = try fromVersion1(a, old, fault);
    } else {
        m.data = std.json.parseFromSliceLeaky(model.ModelData, a, bytes, options) catch |err| return syntax(err);
    }
    if (try model.validate(gpa, &m.data)) |f| {
        fault.* = f;
        return error.Invalid;
    }
    return m;
}

fn syntax(err: anyerror) LoadError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.Syntax;
}

/// A file of version 1: the tabs were in workspaces. A project's workspace
/// had the project's id; the pinned, scratch, quick-terminal and widget
/// workspaces had ids of their own.
const Version1 = struct {
    version: u32,
    epoch_hint: u64 = 0,
    imported_v1: bool = false,
    projects: []model.Project = &.{},
    workspaces: []const Workspace = &.{},
    selection: model.Selection = .{},

    const Workspace = struct {
        id: []const u8,
        kind: enum { project, pinned, scratch, quick, widget },
        tabs: []model.Tab = &.{},
        active_tab: ?model.TabId = null,
    };
};

/// The projects of a version 1 file, each with the tabs of its workspace.
/// A pinned, scratch, quick-terminal or widget workspace with no project of
/// its id becomes a hidden project with the fields of design/010 §11, §2.
/// A project with no workspace (a former group) has no tabs.
fn fromVersion1(a: Allocator, old: Version1, fault: *model.Fault) LoadError!model.ModelData {
    var projects: std.ArrayList(model.Project) = .empty;
    try projects.appendSlice(a, old.projects);
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (old.workspaces, 0..) |w, wi| {
        if ((try done.getOrPut(a, w.id)).found_existing) {
            fault.* = .make("workspaces[{d}].id: duplicate", .{wi});
            return error.Invalid;
        }
        for (projects.items) |*p| {
            if (!std.mem.eql(u8, p.id.text, w.id)) continue;
            p.tabs = w.tabs;
            p.active_tab = w.active_tab;
            break;
        } else {
            const hidden: model.Project = switch (w.kind) {
                .project => {
                    fault.* = .make("workspaces[{d}].id: no project", .{wi});
                    return error.Invalid;
                },
                .pinned => .{ .id = .of(w.id), .name = "Pinned", .path = "", .sidebar = .top, .removable = false, .alias = "pinned" },
                .scratch => .{ .id = .of(w.id), .name = "Scratch Tabs", .path = "", .sidebar = .bottom, .removable = false, .alias = "scratch" },
                .quick => .{ .id = .of(w.id), .name = "Quick Terminal", .path = "", .sidebar = .none, .single_tab = true, .removable = false, .alias = "quick" },
                .widget => .{ .id = .of(w.id), .name = "Widget", .path = "", .sidebar = .none, .single_tab = true },
            };
            var p = hidden;
            p.tabs = w.tabs;
            p.active_tab = w.active_tab;
            try projects.append(a, p);
        }
    }
    return .{
        .epoch_hint = old.epoch_hint,
        .imported_v1 = old.imported_v1,
        .projects = projects.items,
        .selection = old.selection,
    };
}

/// Writes the model as JSON.
pub fn write(m: *const Model, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(m.data, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, w);
    try w.writeByte('\n');
}

pub const FileError = LoadError || error{ ReadFailed, WriteFailed };

/// Reads `path`. A missing file gives an empty model (a first start).
pub fn load(gpa: Allocator, io: std.Io, path: []const u8, fault: *model.Fault) FileError!Model {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return Model.init(gpa),
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReadFailed,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, fault);
}

/// Writes `path` through a temporary file and a rename, so a crash leaves
/// the old file whole. `path` is absolute. It compacts the model first
/// (`Model.compact`): the server saves after each batch, debounced to 100 ms
/// (design/010 §2), so the arena holds only the edits since the last
/// save. Pointers into the model are invalid after a save.
pub fn save(gpa: Allocator, io: std.Io, m: *Model, path: []const u8) FileError!void {
    try m.compact();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(m, &out.writer) catch return error.OutOfMemory;
    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return error.OutOfMemory;
    defer gpa.free(tmp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.written() }) catch return error.WriteFailed;
    std.Io.Dir.renameAbsolute(tmp, path, io) catch return error.WriteFailed;
}
