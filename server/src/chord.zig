//! The chord of `macterm pane key` (`session.key`): the keybind grammar of
//! the app (`HotkeyRegistry.parseShortcut`), and its encoding with the key
//! modes of the session's terminal.
//!
//! - Modifiers (`ctrl`, `cmd`, `shift`, `opt` and their other names) are
//!   joined with `+`, then one key token. Case and spaces do not count.
//! - The key tokens are the keys of the US-ANSI table of the app: letters,
//!   digits, the symbol keys, `return` (`enter`), `tab`, `space`, `escape`
//!   and the arrows (`left`, `right`, `down`, `up`).
//! - A key with no `ctrl`, `cmd` or `opt` types its character, shifted with
//!   `shift` (`shift+1` is `!`). The app does the same
//!   (`GhosttyTerminalNSView.sendKey`): the character comes from the token,
//!   not from the keyboard layout.

const std = @import("std");
const vt = @import("ghostty-vt");
const input = vt.input;

pub const Chord = struct {
    key: input.Key,
    /// The token after its alias: `enter` is `return`.
    token: []const u8,
    mods: input.KeyMods = .{},
};

const Token = struct { name: []const u8, key: input.Key };

const tokens = [_]Token{
    .{ .name = "return", .key = .enter },
    .{ .name = "tab", .key = .tab },
    .{ .name = "space", .key = .space },
    .{ .name = "escape", .key = .escape },
    .{ .name = "left", .key = .arrow_left },
    .{ .name = "right", .key = .arrow_right },
    .{ .name = "down", .key = .arrow_down },
    .{ .name = "up", .key = .arrow_up },
    .{ .name = "=", .key = .equal },
    .{ .name = "-", .key = .minus },
    .{ .name = "]", .key = .bracket_right },
    .{ .name = "[", .key = .bracket_left },
    .{ .name = "'", .key = .quote },
    .{ .name = ";", .key = .semicolon },
    .{ .name = "\\", .key = .backslash },
    .{ .name = ",", .key = .comma },
    .{ .name = "/", .key = .slash },
    .{ .name = ".", .key = .period },
    .{ .name = "`", .key = .backquote },
};

/// The US-ANSI shifted forms of the symbol and digit keys, as the app's
/// `HotkeyRegistry.shiftedSymbols`.
const shifted = [_][2]u8{
    .{ '1', '!' }, .{ '2', '@' },  .{ '3', '#' }, .{ '4', '$' }, .{ '5', '%' },
    .{ '6', '^' }, .{ '7', '&' },  .{ '8', '*' }, .{ '9', '(' }, .{ '0', ')' },
    .{ '-', '_' }, .{ '=', '+' },  .{ '[', '{' }, .{ ']', '}' }, .{ '\\', '|' },
    .{ ';', ':' }, .{ '\'', '"' }, .{ ',', '<' }, .{ '.', '>' }, .{ '/', '?' },
    .{ '`', '~' },
};

/// Parses a chord. Null when it does not parse.
pub fn parse(raw: []const u8) ?Chord {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    for (raw) |c| {
        if (c == ' ') continue;
        if (len == buf.len) return null;
        buf[len] = std.ascii.toLower(c);
        len += 1;
    }
    const cleaned = buf[0..len];
    var parts = std.mem.tokenizeScalar(u8, cleaned, '+');
    var words: [8][]const u8 = undefined;
    var n: usize = 0;
    while (parts.next()) |part| {
        if (n == words.len) return null;
        words[n] = part;
        n += 1;
    }
    if (n == 0) return null;
    var token = words[n - 1];
    if (std.mem.eql(u8, token, "enter")) token = "return";
    var chord: Chord = .{ .key = keyOf(token) orelse return null, .token = canonical(token) };
    for (words[0 .. n - 1]) |word| {
        if (eqlAny(word, &.{ "cmd", "command", "⌘" })) {
            chord.mods.super = true;
        } else if (eqlAny(word, &.{ "ctrl", "control", "⌃" })) {
            chord.mods.ctrl = true;
        } else if (eqlAny(word, &.{ "shift", "⇧" })) {
            chord.mods.shift = true;
        } else if (eqlAny(word, &.{ "opt", "option", "alt", "⌥" })) {
            chord.mods.alt = true;
        } else return null;
    }
    return chord;
}

fn eqlAny(word: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, word, name)) return true;
    return false;
}

fn keyOf(token: []const u8) ?input.Key {
    if (token.len == 1) {
        const c = token[0];
        if (c >= 'a' and c <= 'z') return @fromBackingInt(@intCast(@backingInt(input.Key.key_a) + (c - 'a')));
        if (c >= '0' and c <= '9') return @fromBackingInt(@intCast(@backingInt(input.Key.digit_0) + (c - '0')));
    }
    for (tokens) |t| if (std.mem.eql(u8, t.name, token)) return t.key;
    return null;
}

/// The token as a string that outlives the parse buffer.
fn canonical(token: []const u8) []const u8 {
    for (tokens) |t| if (std.mem.eql(u8, t.name, token)) return t.name;
    const all = "abcdefghijklmnopqrstuvwxyz0123456789";
    const at = std.mem.indexOfScalar(u8, all, token[0]).?;
    return all[at .. at + 1];
}

/// The character that the chord types, or null for a key with none (an
/// arrow, `tab`, `escape`, `return`) or a chord with `ctrl`, `cmd` or `opt`.
fn text(chord: Chord, buf: *[1]u8) ?[]const u8 {
    if (chord.mods.ctrl or chord.mods.super or chord.mods.alt) return null;
    if (std.mem.eql(u8, chord.token, "space")) return " ";
    if (chord.token.len != 1) return null;
    var c = chord.token[0];
    if (chord.mods.shift) {
        if (c >= 'a' and c <= 'z') {
            c = std.ascii.toUpper(c);
        } else for (shifted) |pair| {
            if (pair[0] == c) c = pair[1];
        }
    }
    buf[0] = c;
    return buf[0..1];
}

/// Writes the bytes of a press and a release of the chord, as the terminal's
/// modes encode them. A release writes nothing unless the kitty flags ask
/// for it.
pub fn encode(w: *std.Io.Writer, chord: Chord, term: *const vt.Terminal) std.Io.Writer.Error!void {
    const opts: input.KeyEncodeOptions = .fromTerminal(term);
    var buf: [1]u8 = undefined;
    const typed = text(chord, &buf);
    const event: input.KeyEvent = .{
        .action = .press,
        .key = chord.key,
        .mods = chord.mods,
        // Shift made the character, so it is used up, as the app does.
        .consumed_mods = if (typed != null and chord.mods.shift) .{ .shift = true } else .{},
        .utf8 = typed orelse "",
        // From it, ctrl+c becomes 0x03.
        .unshifted_codepoint = if (chord.token.len == 1) chord.token[0] else 0,
    };
    try input.encodeKey(w, event, opts);
    var release = event;
    release.action = .release;
    // A release never types the character again.
    release.utf8 = "";
    try input.encodeKey(w, release, opts);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn encoded(raw: []const u8, vt_data: []const u8) ![]const u8 {
    const chord = parse(raw) orelse return error.NoParse;
    var term = try vt.Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(testing.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(vt_data);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try encode(&out.writer, chord, &term);
    return out.toOwnedSlice();
}

fn expectEncoded(want: []const u8, raw: []const u8, vt_data: []const u8) !void {
    const got = try encoded(raw, vt_data);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
}

test "chord: the keys of the pane key help" {
    try expectEncoded("\x03", "ctrl+c", "");
    try expectEncoded("\x1b", "escape", "");
    try expectEncoded("\x1b[A", "up", "");
    try expectEncoded("j", "j", "");
    try expectEncoded("!", "shift+1", "");
    try expectEncoded(" ", "space", "");
    try expectEncoded("\x1c", "ctrl+\\", "");
    try expectEncoded("\r", "enter", "");
    try expectEncoded("\r", "return", "");
    try expectEncoded("A", "Shift + A", "");
}

test "chord: the terminal's modes decide the bytes" {
    // DECCKM: application cursor keys.
    try expectEncoded("\x1bOA", "up", "\x1b[?1h");
    // The kitty keyboard protocol, flag 1 (disambiguate).
    try expectEncoded("\x1b[99;5u", "ctrl+c", "\x1b[>1u");
}

test "chord: what does not parse" {
    try testing.expectEqual(null, parse(""));
    try testing.expectEqual(null, parse("ctrl+"));
    try testing.expectEqual(null, parse("hyper+c"));
    try testing.expectEqual(null, parse("f1"));
    try testing.expectEqual(null, parse("ctrl"));
    try testing.expect(parse("cmd+opt+shift+ctrl+k") != null);
}
