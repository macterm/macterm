//! The agent skills that `macterm skills` prints (design 011 §2): SKILL.md
//! files that a coding agent loads from its skills directory, as
//! `<name>/SKILL.md`. The files in `skills/` are the text. The binary embeds
//! them, so the CLI prints them with no server and they always describe the
//! CLI that printed them.
//!
//! There is no installer: each agent knows where its skills go. The output
//! is shaped for the agent to install from: one skill as it is, ready to
//! redirect into place, or all of them after `skills/header.txt`, each after
//! a delimiter line that names its path.
//!
//! Until the swap, the Swift CLI prints the same text from
//! `Macterm/Control/AgentSkills/`. `AgentSkillsTests` checks that the files
//! here are that text.

const std = @import("std");

pub const Skill = struct {
    /// Lowercase letters, digits and single hyphens. The folder of the skill.
    name: []const u8,
    /// `<name>/SKILL.md`.
    path: []const u8,
    /// The `description:` line of the frontmatter: what the skill does and
    /// when to use it.
    description: []const u8,
    /// The whole SKILL.md: what `macterm skills <name>` prints.
    text: []const u8,
};

fn embed(comptime name: []const u8) Skill {
    const text = @embedFile("skills/" ++ name ++ "/SKILL.md");
    return .{ .name = name, .path = name ++ "/SKILL.md", .description = comptime frontmatterDescription(text), .text = text };
}

fn frontmatterDescription(comptime text: []const u8) []const u8 {
    @setEvalBranchQuota(100_000);
    const key = "\ndescription: ";
    const start = (std.mem.indexOf(u8, text, key) orelse @compileError("a skill has no description")) + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n').?;
    return text[start..end];
}

/// In the order that `macterm skills` prints them.
pub const all = [_]Skill{
    embed("macterm-panes"),
    embed("macterm-workspace"),
    embed("macterm-subagents"),
    embed("macterm-palettes"),
};

/// How to install the skills. It comes before them in `macterm skills`.
pub const header = @embedFile("skills/header.txt");

pub fn named(name: []const u8) ?*const Skill {
    for (&all) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

/// The line that introduces a skill in the catalog.
pub fn writeDelimiter(w: *std.Io.Writer, s: Skill) std.Io.Writer.Error!void {
    try w.print("==> {s} <==\n", .{s.path});
}

/// `macterm skills`: the header, a blank line, then each skill after its
/// delimiter.
pub fn writeCatalog(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(header);
    try w.writeByte('\n');
    for (all) |s| {
        try writeDelimiter(w, s);
        try w.writeAll(s.text);
    }
}

/// `macterm skills --list`: one skill on each line, the name padded to the
/// longest name, two spaces, then the description.
pub fn writeList(w: *std.Io.Writer) std.Io.Writer.Error!void {
    var width: usize = 0;
    for (all) |s| width = @max(width, s.name.len);
    for (all) |s| {
        try w.writeAll(s.name);
        try w.splatByteAll(' ', width - s.name.len + 2);
        try w.writeAll(s.description);
        try w.writeByte('\n');
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const contract = @import("contract.zig");

test "each skill is frontmatter with its name, then a body that ends with one newline" {
    for (&all) |*s| {
        try testing.expect(named(s.name) == s);
        var lines = std.mem.splitScalar(u8, s.text, '\n');
        try testing.expectEqualStrings("---", lines.next().?);
        try testing.expectEqualStrings(s.name, lines.next().?["name: ".len..]);
        try testing.expectEqualStrings(s.description, lines.next().?["description: ".len..]);
        try testing.expectEqualStrings("---", lines.next().?);
        try testing.expectEqualStrings("", lines.next().?);
        try testing.expect(std.mem.endsWith(u8, s.text, "\n") and !std.mem.endsWith(u8, s.text, "\n\n"));
        // Nothing in a skill may read as the delimiter of the catalog.
        while (lines.next()) |line| try testing.expect(!std.mem.startsWith(u8, line, "==> "));
    }
    try testing.expect(named("macterm") == null);
}

/// A heading and the first block under it: the text up to the next blank
/// line, or to the end.
fn section(text: []const u8, heading: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, heading) orelse return null;
    const end = std.mem.indexOfPos(u8, text, start + heading.len + 1, "\n\n") orelse text.len;
    return text[start..end];
}

test "each skill stands alone and its description is a plain YAML scalar" {
    // Every skill has the same ground rules.
    const ground_rules = section(all[0].text, "\n## Ground rules\n").?;
    for (all, 0..) |s, i| {
        try testing.expect(s.name.len <= 64);
        var parts = std.mem.splitScalar(u8, s.name, '-');
        while (parts.next()) |part| {
            try testing.expect(part.len > 0);
            for (part) |c| try testing.expect(std.ascii.isLower(c) or std.ascii.isDigit(c));
        }
        for (all[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, s.name, other.name));
        try testing.expectEqualStrings(ground_rules, section(s.text, "\n## Ground rules\n").?);
        var note: [512]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&note,
            \\
            \\## Keeping this skill current
            \\
            \\This file came from `macterm skills {s}`. If Macterm rejects a command shown here, the CLI changed
            \\after you installed the skill. Install the skill again from the output of that command.
            \\
        , .{s.name}), section(s.text, "\n## Keeping this skill current\n").?);

        const d = s.description;
        try testing.expect(d.len > 0 and d.len <= 1024);
        try testing.expect(std.mem.indexOf(u8, d, "Use when") != null);
        try testing.expect(std.mem.indexOf(u8, d, ": ") == null and std.mem.indexOf(u8, d, " #") == null);
        try testing.expect(std.mem.indexOfAny(u8, d, "\t") == null and d[0] != ' ' and d[d.len - 1] != ' ');
        try testing.expect(std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", d[0]) == null);
        // An agent reads all of a skill when it loads it.
        try testing.expect(std.mem.count(u8, s.text, "\n") < 500);
        // A code span stays on one line, so that the check below sees it.
        var fenced = false;
        var lines = std.mem.splitScalar(u8, s.text, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```")) {
                fenced = !fenced;
            } else if (!fenced) try testing.expect(std.mem.count(u8, line, "`") % 2 == 0);
        }
    }
}

test "the catalog splits back into the skills that it printed" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeCatalog(&out.writer);
    var rest = out.written();
    try testing.expect(std.mem.startsWith(u8, rest, header ++ "\n"));
    rest = rest[header.len + 1 ..];
    for (all, 0..) |s, i| {
        var delimiter: std.Io.Writer.Allocating = .init(testing.allocator);
        defer delimiter.deinit();
        try writeDelimiter(&delimiter.writer, s);
        try testing.expect(std.mem.startsWith(u8, rest, delimiter.written()));
        rest = rest[delimiter.written().len..];
        const end = if (i + 1 < all.len) std.mem.indexOf(u8, rest, "\n==> ").? + 1 else rest.len;
        try testing.expectEqualStrings(s.text, rest[0..end]);
        rest = rest[end..];
    }
    try testing.expectEqual(0, rest.len);
}

test "the list names each skill once, with its description" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeList(&out.writer);
    try testing.expectEqualStrings(
        "macterm-panes      " ++ all[0].description ++ "\n" ++
            "macterm-workspace  " ++ all[1].description ++ "\n" ++
            "macterm-subagents  " ++ all[2].description ++ "\n" ++
            "macterm-palettes   " ++ all[3].description ++ "\n",
        out.written(),
    );
}

// ── The skills check (design 011 §5) ────────────────────────────────────────
//
// Every `macterm …` command line in a fenced block or a code span of a skill,
// and every code span that starts with a command of the CLI, must parse
// against the v1 contract: real commands, only options that they declare,
// and no more arguments than they take. A command that exists only in Debug
// builds does not count, because a release CLI does not have it.

const operators = "|;&()<>`";

/// Enough of a shell's word split to find where a command line ends: quotes
/// and backslashes, and each operator as a word of its own.
fn shellWords(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    var escaped = false;
    for (line) |c| {
        if (escaped) {
            try current.append(arena, c);
            escaped = false;
        } else if (quote) |open| {
            if (c == open) {
                quote = null;
            } else if (c == '\\' and open == '"') {
                escaped = true;
            } else try current.append(arena, c);
        } else if (c == '\\') {
            escaped = true;
            in_word = true;
        } else if (c == '\'' or c == '"') {
            quote = c;
            in_word = true;
        } else if (c == ' ' or c == '\t') {
            if (in_word) try words.append(arena, try current.toOwnedSlice(arena));
            in_word = false;
        } else if (std.mem.indexOfScalar(u8, operators, c) != null) {
            if (in_word) try words.append(arena, try current.toOwnedSlice(arena));
            in_word = false;
            try words.append(arena, try arena.dupe(u8, &.{c}));
        } else if (c == '#' and !in_word) {
            break;
        } else {
            try current.append(arena, c);
            in_word = true;
        }
    }
    if (in_word) try words.append(arena, try current.toOwnedSlice(arena));
    return words.items;
}

fn isOperator(word: []const u8) bool {
    return word.len == 1 and std.mem.indexOfScalar(u8, operators, word[0]) != null;
}

/// The command lines of a skill, each as the words after `macterm`.
fn invocations(arena: std.mem.Allocator, text: []const u8, spec: contract.Contract) ![]const []const []const u8 {
    const Snippet = struct { text: []const u8, inline_span: bool };
    var snippets: std.ArrayList(Snippet) = .empty;
    var fenced = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```")) {
            fenced = !fenced;
        } else if (fenced) {
            try snippets.append(arena, .{ .text = line, .inline_span = false });
        } else {
            var parts = std.mem.splitScalar(u8, line, '`');
            var odd = false;
            while (parts.next()) |part| : (odd = !odd) {
                if (odd) try snippets.append(arena, .{ .text = part, .inline_span = true });
            }
        }
    }
    const root = spec.find(&.{}).?;
    var found: std.ArrayList([]const []const u8) = .empty;
    for (snippets.items) |snippet| {
        var words = try shellWords(arena, snippet.text);
        if (snippet.inline_span and words.len > 1) {
            for (root.subcommands) |name| {
                if (std.mem.eql(u8, name, words[0])) {
                    words = try std.mem.concat(arena, []const u8, &.{ &.{"macterm"}, words });
                    break;
                }
            }
        }
        for (words, 0..) |word, i| {
            if (!std.mem.eql(u8, std.fs.path.basename(word), "macterm")) continue;
            var end = i + 1;
            while (end < words.len and !isOperator(words[end])) end += 1;
            try found.append(arena, words[i + 1 .. end]);
        }
    }
    return found.items;
}

fn findOption(options: []const contract.Contract.Option, spelling: []const u8) ?contract.Contract.Option {
    for (options) |o| {
        for (o.names) |n| if (std.mem.eql(u8, n, spelling)) return o;
    }
    return null;
}

/// Why `words` (the words after `macterm`) would not parse, or null.
fn problem(arena: std.mem.Allocator, spec: contract.Contract, words: []const []const u8) !?[]const u8 {
    var node = spec.find(&.{}).?;
    var index: usize = 0;
    while (index < words.len) : (index += 1) {
        node = spec.find(words[0 .. index + 1]) orelse break;
    }
    const path = try std.mem.join(arena, " ", node.path);
    if (node.debug) return try std.fmt.allocPrint(arena, "`{s}` exists only in Debug builds", .{path});
    if (std.mem.eql(u8, path, "help")) {
        for (index..words.len) |n| {
            if (spec.find(words[index .. n + 1]) == null)
                return try std.fmt.allocPrint(arena, "no `{s}` command to show help for", .{words[n]});
        }
        return null;
    }
    var positionals: usize = 0;
    var repeats = false;
    var takes_all = false;
    for (node.arguments) |a| {
        positionals += 1;
        repeats = repeats or a.repeating;
        takes_all = takes_all or std.mem.eql(u8, a.takes orelse "", "all");
    }
    var arguments: std.ArrayList([]const u8) = .empty;
    while (index < words.len) {
        const word = words[index];
        index += 1;
        if (std.mem.eql(u8, word, "--")) {
            try arguments.appendSlice(arena, words[index..]);
            break;
        }
        if (word.len > 1 and word[0] == '-') {
            const spelling = word[0 .. std.mem.indexOfScalar(u8, word, '=') orelse word.len];
            // `ssh`: a word that is not its own option starts the words
            // that it passes on.
            const o = findOption(node.options, spelling) orelse if (takes_all) break else return try std.fmt.allocPrint(arena, "`{s}` has no {s} option", .{ path, spelling });
            if (o.debug) return try std.fmt.allocPrint(arena, "{s} exists only in Debug builds", .{spelling});
            if (o.value != null and spelling.len == word.len) index += 1;
            continue;
        }
        if (takes_all) break;
        try arguments.append(arena, word);
    }
    if (!repeats and arguments.items.len > positionals)
        return try std.fmt.allocPrint(arena, "`{s}` takes {d} argument(s), not {d}", .{ path, positionals, arguments.items.len });
    if (std.mem.eql(u8, path, "skills")) for (arguments.items) |name| {
        if (named(name) == null) return try std.fmt.allocPrint(arena, "there is no skill named {s}", .{name});
    };
    return null;
}

test "every command in the skills is one that the CLI accepts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec = try contract.parseContract(arena);

    var checked: usize = 0;
    var failed = false;
    for (all) |s| {
        for (try invocations(arena, s.text, spec)) |words| {
            checked += 1;
            if (try problem(arena, spec, words)) |p| {
                std.debug.print("{s}: `macterm {s}`: {s}\n", .{ s.name, try std.mem.join(arena, " ", words), p });
                failed = true;
            }
        }
    }
    try testing.expect(!failed);
    // A parse that found nothing would pass.
    try testing.expect(checked > 60);
}

test "the check finds what the CLI would refuse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec = try contract.parseContract(arena);

    const cases = [_]struct { line: []const u8, bad: bool }{
        .{ .line = "macterm pane run --session x -- ls -la | head", .bad = false },
        .{ .line = "macterm pane run --nope -- ls", .bad = true },
        .{ .line = "macterm session info a b", .bad = true },
        .{ .line = "macterm skills macterm-panes > x", .bad = false },
        .{ .line = "macterm skills nope", .bad = true },
        .{ .line = "macterm help pane run", .bad = false },
        .{ .line = "macterm help pane nope", .bad = true },
        .{ .line = "macterm ssh -p 22 host -v", .bad = false },
    };
    for (cases) |case| {
        const lines = try invocations(arena, try std.fmt.allocPrint(arena, "```sh\n{s}\n```\n", .{case.line}), spec);
        try testing.expectEqual(1, lines.len);
        const p = try problem(arena, spec, lines[0]);
        testing.expectEqual(case.bad, p != null) catch |e| {
            std.debug.print("{s}: {?s}\n", .{ case.line, p });
            return e;
        };
    }
    // A code span that starts with a command counts with no `macterm`.
    try testing.expectEqual(1, (try invocations(arena, "Press `pane key return` now.", spec)).len);
    try testing.expectEqual(0, (try invocations(arena, "Read `pane` here.", spec)).len);
}
