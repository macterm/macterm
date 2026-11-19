//! The grammar of the `macterm` CLI (design 011 §5): commands, options and
//! positional arguments, the parse of an argument line, and the help text.
//!
//! The parse and the help follow the v1 CLI (Swift ArgumentParser), so that
//! the text and the exit codes of `golden/` stay the same: help goes to
//! stdout with exit 0, and a usage error goes to stderr with exit 64.

const std = @import("std");

pub const Option = struct {
    /// With the dashes, the long name last: `-h`, `--help`.
    names: []const []const u8,
    /// The name of the value, for an option that takes one. Null for a flag.
    value: ?[]const u8 = null,
    abstract: []const u8,

    fn long(o: Option) []const u8 {
        return o.names[o.names.len - 1];
    }
};

pub const Argument = struct {
    name: []const u8,
    abstract: []const u8,
    optional: bool = false,
    /// Takes every word that is left. Only the last argument repeats.
    repeating: bool = false,
    /// Takes the words that are not options of the command, too, and the
    /// first `--` (ArgumentParser's `.allUnrecognized`): the command reads
    /// them itself (`pane run`).
    unrecognized: bool = false,
};

pub const Command = struct {
    name: []const u8,
    abstract: []const u8,
    /// Paragraphs after the overview in the help. A line that starts with a
    /// space is written as it is; another line is wrapped.
    discussion: ?[]const u8 = null,
    /// The usage line, in place of the one made from the options.
    usage: ?[]const u8 = null,
    /// Not in the help of its parent.
    hidden: bool = false,
    /// Every command also takes `-h` and `--help` (`help_option`).
    options: []const Option = &.{},
    arguments: []const Argument = &.{},
    subcommands: []const *const Command = &.{},
    /// The subcommand that runs when a group is given alone.
    default: ?*const Command = null,

    pub fn subcommand(c: *const Command, name: []const u8) ?*const Command {
        for (c.subcommands) |sub| {
            if (std.mem.eql(u8, sub.name, name)) return sub;
        }
        return null;
    }
};

pub const help_option: Option = .{ .names = &.{ "-h", "--help" }, .abstract = "Show help information." };

/// The exit code of a usage error (`EX_USAGE`, as ArgumentParser).
pub const usage_exit: u8 = 64;

/// The words of a command line that the parse found.
pub const Parsed = struct {
    /// The root first, the command that runs last.
    path: []const *const Command,
    /// For each option of the command, in order: its value, `""` for a
    /// flag that is given, null when it is not given.
    values: []const ?[]const u8,
    positionals: []const []const u8,

    pub fn command(p: Parsed) *const Command {
        return p.path[p.path.len - 1];
    }

    /// The value of the option with this long name, or null.
    pub fn value(p: Parsed, long: []const u8) ?[]const u8 {
        for (p.command().options, p.values) |o, v| {
            if (std.mem.eql(u8, o.long(), long)) return v;
        }
        return null;
    }

    pub fn flag(p: Parsed, long: []const u8) bool {
        return p.value(long) != null;
    }
};

pub const Result = union(enum) {
    run: Parsed,
    /// Print the help of the last command of the path.
    help: []const *const Command,
    usage_error: struct { path: []const *const Command, message: []const u8 },
};

/// Parses `words` (the argument line without the program name) against the
/// tree under `root`. The root's `help` subcommand prints the help of the
/// command that its words name.
pub fn parse(arena: std.mem.Allocator, root: *const Command, words: []const []const u8) error{OutOfMemory}!Result {
    var path: std.ArrayList(*const Command) = .empty;
    try path.append(arena, root);
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const sub = path.items[path.items.len - 1].subcommand(words[i]) orelse break;
        try path.append(arena, sub);
    }
    if (path.items.len == 2 and std.mem.eql(u8, path.items[1].name, "help") and path.items[1].hidden)
        return helpCommand(arena, root, words[i..]);

    // A group with a default runs it, unless the words ask for the
    // group's help.
    if (path.items[path.items.len - 1].default) |d| {
        for (words[i..]) |word| {
            if (std.mem.eql(u8, word, "--")) break;
            if (std.mem.eql(u8, word, "-h") or std.mem.eql(u8, word, "--help")) return .{ .help = path.items };
        }
        try path.append(arena, d);
    }
    const command = path.items[path.items.len - 1];
    const unrecognized = command.arguments.len > 0 and command.arguments[command.arguments.len - 1].unrecognized;

    const values = try arena.alloc(?[]const u8, command.options.len);
    @memset(values, null);
    var positionals: std.ArrayList([]const u8) = .empty;
    var only_positionals = false;
    while (i < words.len) : (i += 1) {
        const word = words[i];
        if (!only_positionals and std.mem.eql(u8, word, "--")) {
            only_positionals = true;
            if (unrecognized) try positionals.append(arena, word);
            continue;
        }
        if (!only_positionals and isOption(word)) {
            if (std.mem.eql(u8, word, "-h") or std.mem.eql(u8, word, "--help")) return .{ .help = path.items };
            const eq = std.mem.indexOfScalar(u8, word, '=');
            const name = if (eq) |e| word[0..e] else word;
            const index = optionIndex(command, name) orelse {
                if (unrecognized) {
                    try positionals.append(arena, word);
                    continue;
                }
                return usageError(arena, path.items, "Unknown option '{s}'", .{name});
            };
            const o = command.options[index];
            if (o.value == null) {
                if (eq != null) return usageError(arena, path.items, "Unknown option '{s}'", .{word});
                values[index] = "";
            } else if (eq) |e| {
                values[index] = word[e + 1 ..];
            } else if (i + 1 < words.len and !isOption(words[i + 1])) {
                i += 1;
                values[index] = words[i];
            } else {
                return usageError(arena, path.items, "Missing value for '{s} <{s}>'", .{ o.long(), o.value.? });
            }
            continue;
        }
        try positionals.append(arena, word);
    }

    if (command.subcommands.len > 0) {
        if (positionals.items.len > 0)
            return usageError(arena, path.items, "Unexpected argument '{s}'", .{positionals.items[0]});
        // A group given alone prints its help, as ArgumentParser does.
        return .{ .help = path.items };
    }
    const repeats = command.arguments.len > 0 and command.arguments[command.arguments.len - 1].repeating;
    if (!repeats and positionals.items.len > command.arguments.len)
        return usageError(arena, path.items, "Unexpected argument '{s}'", .{positionals.items[command.arguments.len]});
    for (command.arguments[@min(positionals.items.len, command.arguments.len)..]) |a| {
        if (!a.optional) return usageError(arena, path.items, "Missing expected argument '<{s}>'", .{a.name});
    }
    return .{ .run = .{ .path = path.items, .values = values, .positionals = positionals.items } };
}

fn helpCommand(arena: std.mem.Allocator, root: *const Command, words: []const []const u8) error{OutOfMemory}!Result {
    var path: std.ArrayList(*const Command) = .empty;
    try path.append(arena, root);
    for (words) |word| {
        // `macterm help -h` is the help of the root, as in v1.
        if (isHelpFlag(word)) continue;
        const sub = path.items[path.items.len - 1].subcommand(word) orelse
            return usageError(arena, path.items, "Unexpected argument '{s}'", .{word});
        try path.append(arena, sub);
    }
    return .{ .help = path.items };
}

fn isHelpFlag(word: []const u8) bool {
    return std.mem.eql(u8, word, "-h") or std.mem.eql(u8, word, "--help") or std.mem.eql(u8, word, "-help");
}

/// A word that names an option, not a value: `-x`, `--name`. A lone `-` is
/// a value (stdin, by custom).
fn isOption(word: []const u8) bool {
    return word.len > 1 and word[0] == '-';
}

fn optionIndex(command: *const Command, name: []const u8) ?usize {
    for (command.options, 0..) |o, index| {
        for (o.names) |n| {
            if (std.mem.eql(u8, n, name)) return index;
        }
    }
    return null;
}

fn usageError(arena: std.mem.Allocator, path: []const *const Command, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!Result {
    return .{ .usage_error = .{ .path = path, .message = try std.fmt.allocPrint(arena, fmt, args) } };
}

// ── Text ────────────────────────────────────────────────────────────────────

/// The width that help wraps at, as the v1 CLI with `COLUMNS=80`.
const width = 80;
/// A line of the discussion or of a subcommand row is one column shorter, as
/// ArgumentParser wraps them.
const short_width = width - 1;
/// The column where the abstract of a row starts.
const abstract_column = 26;

/// `macterm status`: the command words of the path.
pub fn writeCommandLine(w: *std.Io.Writer, path: []const *const Command) std.Io.Writer.Error!void {
    for (path, 0..) |c, n| {
        if (n > 0) try w.writeByte(' ');
        try w.writeAll(c.name);
    }
}

/// The usage line, without `USAGE: `.
pub fn writeUsage(w: *std.Io.Writer, path: []const *const Command) std.Io.Writer.Error!void {
    const c = path[path.len - 1];
    if (c.usage) |u| return w.writeAll(u);
    try writeCommandLine(w, path);
    if (c.subcommands.len > 0) return w.writeAll(" <subcommand>");
    for (c.arguments) |a| {
        const dots: []const u8 = if (a.repeating) " ..." else "";
        if (a.optional) try w.print(" [<{s}>{s}]", .{ a.name, dots }) else try w.print(" <{s}>{s}", .{ a.name, dots });
    }
    for (c.options) |o| {
        if (o.value) |v| try w.print(" [{s} <{s}>]", .{ o.long(), v }) else try w.print(" [{s}]", .{o.long()});
    }
}

/// A usage error, as ArgumentParser prints it on stderr.
pub fn writeUsageError(w: *std.Io.Writer, path: []const *const Command, message: []const u8) std.Io.Writer.Error!void {
    try w.print("Error: {s}\nUsage: ", .{message});
    try writeUsage(w, path);
    try w.writeAll("\n  See '");
    try writeCommandLine(w, path);
    try w.writeAll(" --help' for more information.\n");
}

/// The `--help` text of the last command of `path`.
pub fn writeHelp(w: *std.Io.Writer, path: []const *const Command) std.Io.Writer.Error!void {
    const c = path[path.len - 1];
    try writeWrapped(w, "OVERVIEW: ", c.abstract, 0, width);
    try w.writeByte('\n');
    if (c.discussion) |d| {
        var lines = std.mem.splitScalar(u8, d, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == ' ') {
                try w.writeAll(line);
                try w.writeByte('\n');
            } else try writeWrapped(w, "", line, 0, short_width);
        }
        try w.writeByte('\n');
    }
    try w.writeAll("USAGE: ");
    try writeUsage(w, path);
    try w.writeAll("\n\n");

    if (c.arguments.len > 0) {
        try w.writeAll("ARGUMENTS:\n");
        for (c.arguments) |a| {
            var label: [64]u8 = undefined;
            try writeRow(w, std.fmt.bufPrint(&label, "<{s}>", .{a.name}) catch a.name, a.abstract, width);
        }
        try w.writeByte('\n');
    }

    try w.writeAll("OPTIONS:\n");
    for (c.options) |o| try writeOption(w, o);
    try writeOption(w, help_option);
    try w.writeByte('\n');

    if (c.subcommands.len > 0) {
        try w.writeAll("SUBCOMMANDS:\n");
        for (c.subcommands) |sub| {
            if (sub.hidden) continue;
            var label: [64]u8 = undefined;
            const name = if (c.default == sub) std.fmt.bufPrint(&label, "{s} (default)", .{sub.name}) catch sub.name else sub.name;
            try writeRow(w, name, sub.abstract, short_width);
        }
        try w.writeAll("\n  See '");
        try w.writeAll(path[0].name);
        try w.writeAll(" help ");
        for (path[1..]) |p| try w.print("{s} ", .{p.name});
        try w.writeAll("<subcommand>' for detailed help.\n");
    }
}

fn writeOption(w: *std.Io.Writer, o: Option) std.Io.Writer.Error!void {
    var label_buf: [128]u8 = undefined;
    var label: std.Io.Writer = .fixed(&label_buf);
    for (o.names, 0..) |n, k| {
        if (k > 0) label.writeAll(", ") catch {};
        label.writeAll(n) catch {};
    }
    if (o.value) |v| label.print(" <{s}>", .{v}) catch {};
    try writeRow(w, label.buffered(), o.abstract, width);
}

/// One row of a section: the label at column 2 and the abstract at column
/// 26, on the next line when the label does not leave room.
fn writeRow(w: *std.Io.Writer, label: []const u8, abstract: []const u8, max: usize) std.Io.Writer.Error!void {
    try w.writeAll("  ");
    try w.writeAll(label);
    if (2 + label.len + 2 > abstract_column) {
        try w.writeByte('\n');
        try w.splatByteAll(' ', abstract_column);
    } else {
        try w.splatByteAll(' ', abstract_column - 2 - label.len);
    }
    try writeWrapped(w, "", abstract, abstract_column, max);
}

/// Writes `prefix` and `text`, wrapped on spaces so that a line holds at
/// most `max` columns, and a newline.
/// A line after the first starts with `indent` spaces; the caller wrote the
/// first `indent` columns of the first line.
fn writeWrapped(w: *std.Io.Writer, prefix: []const u8, text: []const u8, indent: usize, max: usize) std.Io.Writer.Error!void {
    try w.writeAll(prefix);
    var column = indent + prefix.len;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var line_start = true;
    while (words.next()) |word| {
        const cells = std.unicode.utf8CountCodepoints(word) catch word.len;
        if (!line_start and column + 1 + cells > max) {
            try w.writeByte('\n');
            try w.splatByteAll(' ', indent);
            column = indent;
            line_start = true;
        }
        if (!line_start) {
            try w.writeByte(' ');
            column += 1;
        }
        try w.writeAll(word);
        column += cells;
        line_start = false;
    }
    try w.writeByte('\n');
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const test_leaf: Command = .{
    .name = "leaf",
    .abstract = "A leaf.",
    .options = &.{
        .{ .names = &.{"--socket"}, .value = "socket", .abstract = "Socket." },
        .{ .names = &.{"--json"}, .abstract = "JSON." },
    },
    .arguments = &.{.{ .name = "name", .abstract = "Name.", .optional = true }},
};
const test_needs: Command = .{ .name = "needs", .abstract = "Needs an id.", .arguments = &.{.{ .name = "id", .abstract = "Id." }} };
const test_help: Command = .{ .name = "help", .abstract = "Help.", .hidden = true };
const test_root: Command = .{ .name = "macterm", .abstract = "Root.", .subcommands = &.{ &test_leaf, &test_needs, &test_help } };

test "options take a value as the next word or after =, and flags take none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parse(a, &test_root, &.{ "leaf", "--json", "--socket", "/s", "x" });
    try testing.expectEqualStrings("leaf", r.run.command().name);
    try testing.expect(r.run.flag("--json"));
    try testing.expectEqualStrings("/s", r.run.value("--socket").?);
    try testing.expectEqualStrings("x", r.run.positionals[0]);
    const eq = try parse(a, &test_root, &.{ "leaf", "--socket=/t" });
    try testing.expectEqualStrings("/t", eq.run.value("--socket").?);
    try testing.expect(!eq.run.flag("--json"));
}

test "usage errors name the word" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Unexpected argument 'nope'", (try parse(a, &test_root, &.{"nope"})).usage_error.message);
    try testing.expectEqualStrings("Unknown option '--nope'", (try parse(a, &test_root, &.{ "leaf", "--nope" })).usage_error.message);
    try testing.expectEqualStrings("Missing value for '--socket <socket>'", (try parse(a, &test_root, &.{ "leaf", "--socket" })).usage_error.message);
    try testing.expectEqualStrings("Unexpected argument 'y'", (try parse(a, &test_root, &.{ "leaf", "x", "y" })).usage_error.message);
    try testing.expectEqualStrings("Unknown option '--json=1'", (try parse(a, &test_root, &.{ "leaf", "--json=1" })).usage_error.message);
    // A word that names an option is not a value.
    try testing.expectEqualStrings("Missing value for '--socket <socket>'", (try parse(a, &test_root, &.{ "leaf", "--socket", "--json" })).usage_error.message);
    try testing.expectEqualStrings("-", (try parse(a, &test_root, &.{ "leaf", "--socket", "-" })).run.value("--socket").?);
    try testing.expectEqualStrings("Missing expected argument '<id>'", (try parse(a, &test_root, &.{"needs"})).usage_error.message);
}

test "help comes from -h, --help, the help command and a group alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(1, (try parse(a, &test_root, &.{})).help.len);
    try testing.expectEqual(2, (try parse(a, &test_root, &.{ "leaf", "-h" })).help.len);
    try testing.expectEqual(2, (try parse(a, &test_root, &.{ "help", "leaf" })).help.len);
    try testing.expectEqual(1, (try parse(a, &test_root, &.{"--help"})).help.len);
    // After `--`, a help flag is a word.
    try testing.expectEqualStrings("--help", (try parse(a, &test_root, &.{ "leaf", "--", "--help" })).run.positionals[0]);
    try testing.expectEqualStrings("Unexpected argument 'nope'", (try parse(a, &test_root, &.{ "help", "nope" })).usage_error.message);
    try testing.expectEqual(1, (try parse(a, &test_root, &.{ "help", "-h" })).help.len);
}

test "a usage error prints the usage line and where to find help" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeUsageError(&w, &.{ &test_root, &test_leaf }, "Unknown option '--x'");
    try testing.expectEqualStrings(
        \\Error: Unknown option '--x'
        \\Usage: macterm leaf [<name>] [--socket <socket>] [--json]
        \\  See 'macterm leaf --help' for more information.
        \\
    , w.buffered());
}

test "a long abstract wraps at column 80 under column 26" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRow(&w, "status", "Show whether Macterm is running and which project is active.", short_width);
    try writeRow(&w, "--a-very-long-option <value>", "Text.", width);
    try testing.expectEqualStrings(
        \\  status                  Show whether Macterm is running and which project is
        \\                          active.
        \\  --a-very-long-option <value>
        \\                          Text.
        \\
    , w.buffered());
}
