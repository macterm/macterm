const std = @import("std");
pub const terminal = @import("terminal.zig");
pub const isUserInput = terminal.isUserInput;
pub const serializeTerminalState = terminal.serializeTerminalState;
pub const serializeScreenState = terminal.serializeScreenState;
const cross = @import("cross");
const lib_posix = @import("posix.zig");
const testing = std.testing;

/// OSC 133;A (prompt start) marker.
const OSC_133_A = "\x1b]133;A";

/// Rewrite OSC 133;A sequences to include `redraw=0`, which tells the outer
/// terminal not to clear prompt lines on resize. This is necessary because
/// zmx sits between the shell and the outer terminal: from the outer terminal's
/// perspective, the foreground process (zmx client) cannot redraw prompts.
/// Without this, the outer terminal clears the prompt on resize expecting the
/// shell to redraw it, but the shell's redraw goes through zmx's IPC path with
/// cursor coordinates relative to the inner PTY, causing a cursor desync that
/// makes the prompt invisible.
/// See: https://github.com/neurosnap/zmx/issues/111
pub fn rewritePromptRedraw(alloc: std.mem.Allocator, data: []const u8) ?[]const u8 {
    // Fast-path: most PTY output has no escape sequences at all. A scalar
    // byte scan for ESC is cheaper than the full string indexOf below.
    if (std.mem.indexOfScalar(u8, data, '\x1b') == null) return null;
    if (std.mem.indexOf(u8, data, OSC_133_A) == null) return null;

    var result = std.ArrayList(u8).initCapacity(alloc, data.len + 200) catch return null;
    errdefer result.deinit(alloc);
    result.appendSlice(alloc, data) catch return null;

    // Work backwards so index shifts don't invalidate later positions.
    var search_from: usize = result.items.len;
    while (search_from > 0) {
        const haystack = result.items[0..search_from];
        const pos = std.mem.lastIndexOf(u8, haystack, OSC_133_A) orelse break;
        search_from = pos;

        const after = pos + OSC_133_A.len;
        if (after >= result.items.len) continue;

        // Find the string terminator (BEL \x07 or ST \x1b\\).
        var term_pos: ?usize = null;
        var j = after;
        while (j < result.items.len) : (j += 1) {
            if (result.items[j] == '\x07') {
                term_pos = j;
                break;
            }
            if (result.items[j] == '\x1b' and j + 1 < result.items.len and result.items[j + 1] == '\\') {
                term_pos = j;
                break;
            }
        }
        const end = term_pos orelse continue;

        // Check the parameter region between OSC_133_A and the terminator.
        const params = result.items[after..end];

        // If redraw=0 already present, skip.
        if (std.mem.indexOf(u8, params, "redraw=0") != null) continue;

        // If redraw= exists with a different value, replace it.
        if (std.mem.indexOf(u8, params, "redraw=")) |rdw_offset| {
            const abs_rdw = after + rdw_offset;
            const value_start = abs_rdw + "redraw=".len;
            var value_end = value_start;
            while (value_end < end and result.items[value_end] != ';') : (value_end += 1) {}
            result.replaceRange(alloc, value_start, value_end - value_start, "0") catch return null;
            continue;
        }

        // No redraw= present. Insert ;redraw=0 before the terminator.
        result.replaceRange(alloc, end, 0, ";redraw=0") catch return null;
    }

    // If nothing changed, free and return null.
    if (std.mem.eql(u8, result.items, data)) {
        result.deinit(alloc);
        return null;
    }

    return result.toOwnedSlice(alloc) catch null;
}

/// The longest prompt mark that `promptStartTail` holds back.
const held_max = 1024;

/// The length of the end of `data` that may be the start of an OSC 133;A with
/// no terminator yet, or 0. The caller holds those bytes back until the next
/// read, so that `rewritePromptRedraw` sees whole marks.
pub fn promptStartTail(data: []const u8) usize {
    const esc = std.mem.lastIndexOfScalar(u8, data, '\x1b') orelse return 0;
    const tail = data[esc..];
    if (tail.len < OSC_133_A.len and std.mem.startsWith(u8, OSC_133_A, tail)) {
        // The ESC of an ST can end a mark: `ESC ] 133;A ... ESC`.
        const mark = std.mem.lastIndexOf(u8, data[0..esc], OSC_133_A) orelse return tail.len;
        if (std.mem.indexOfScalarPos(u8, data[0..esc], mark, '\x07') != null) return tail.len;
        return if (data.len - mark <= held_max) data.len - mark else 0;
    }
    if (!std.mem.startsWith(u8, tail, OSC_133_A)) return 0;
    if (std.mem.indexOfScalar(u8, tail, '\x07') != null) return 0;
    return if (tail.len <= held_max) tail.len else 0;
}

test "promptStartTail: holds the start of a prompt mark" {
    try testing.expectEqual(0, promptStartTail("plain text"));
    try testing.expectEqual(0, promptStartTail("a\x1b]133;A\x07$ "));
    try testing.expectEqual(0, promptStartTail("a\x1b]133;A\x1b\\"));
    try testing.expectEqual(1, promptStartTail("out\x1b"));
    try testing.expectEqual(4, promptStartTail("out\x1b]13"));
    try testing.expectEqual(7, promptStartTail("out\x1b]133;A"));
    try testing.expectEqual(13, promptStartTail("out\x1b]133;A;aid=1"));
    try testing.expectEqual(14, promptStartTail("out\x1b]133;A;aid=1\x1b"));
    // Another sequence, or a mark too long to be a prompt mark.
    try testing.expectEqual(0, promptStartTail("out\x1b]2;title"));
    var long: [held_max + 1]u8 = @splat('x');
    @memcpy(long[0..OSC_133_A.len], OSC_133_A);
    try testing.expectEqual(0, promptStartTail(&long));
}

test "rewritePromptRedraw: no OSC 133;A returns null" {
    const result = rewritePromptRedraw(std.testing.allocator, "hello world");
    try std.testing.expect(result == null);
}

test "rewritePromptRedraw: injects redraw=0 with BEL terminator" {
    const input = "\x1b]133;A\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x07", result);
}

test "rewritePromptRedraw: injects redraw=0 with ST terminator" {
    const input = "\x1b]133;A\x1b\\";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x1b\\", result);
}

test "rewritePromptRedraw: replaces existing redraw=1" {
    const input = "\x1b]133;A;redraw=1\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x07", result);
}

test "rewritePromptRedraw: replaces existing redraw=last" {
    const input = "\x1b]133;A;redraw=last\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;redraw=0\x07", result);
}

test "rewritePromptRedraw: preserves redraw=0 (no-op)" {
    const result = rewritePromptRedraw(std.testing.allocator, "\x1b]133;A;redraw=0\x07");
    try std.testing.expect(result == null);
}

test "rewritePromptRedraw: preserves other parameters" {
    const input = "\x1b]133;A;aid=14;cl=line\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b]133;A;aid=14;cl=line;redraw=0\x07", result);
}

test "rewritePromptRedraw: handles multiple markers" {
    const input = "before\x1b]133;A\x07middle\x1b]133;A;redraw=1\x07after";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("before\x1b]133;A;redraw=0\x07middle\x1b]133;A;redraw=0\x07after", result);
}

test "rewritePromptRedraw: does not touch OSC 133;B or 133;C" {
    const input = "\x1b]133;B\x07\x1b]133;C\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input);
    try std.testing.expect(result == null);
}

test "rewritePromptRedraw: embedded in larger output" {
    const input = "some output\r\n\x1b]133;A\x07prompt$ \x1b]133;B\x07";
    const result = rewritePromptRedraw(std.testing.allocator, input).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("some output\r\n\x1b]133;A;redraw=0\x07prompt$ \x1b]133;B\x07", result);
}

/// Detects Ctrl+\ in raw, Kitty CSI u and xterm modifyOtherKeys encodings.
pub fn isCtrlBackslash(buf: []const u8) bool {
    if (buf.len == 0) return false;
    return buf[0] == 0x1C or isKeyPressed(buf, 0x5c, 0b100) or isModifyOtherKey(buf, 0x5c, 0b100);
}

/// Scans the buffer for an xterm modifyOtherKeys-encoded keypress.
/// Format: CSI 27 ; <modifier> ; <keycode> ~
/// Reference: invisible-island.net/xterm/ctlseqs/ctlseqs.html (modifyOtherKeys).
fn isModifyOtherKey(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 1) {
        if (buf[i] == 0x1b and buf[i + 1] == '[') {
            if (modifyOtherMatches(buf[i + 2 ..], expected_key, expected_mods)) return true;
        }
    }
    return false;
}

/// Parses the body of an xterm modifyOtherKeys CSI sequence (after the leading
/// `\x1b[`). Mirrors keypressWithMod's tolerance for lock modifiers.
fn modifyOtherMatches(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    var pos: usize = 0;

    // 1. Sentinel: literal "27" identifies xterm modifyOtherKeys.
    const sentinel = parseDecimal(buf, &pos) orelse return false;
    if (sentinel != 27) return false;

    // 2. Expect ';' before modifier.
    if (pos >= buf.len or buf[pos] != ';') return false;
    pos += 1;

    // 3. Parse modifier (xterm encodes as 1 + bitfield, same as kitty).
    const mod_encoded = parseDecimal(buf, &pos) orelse return false;
    if (mod_encoded < 1) return false;
    const mod_raw = mod_encoded - 1;
    // Tolerate ambient lock modifiers (caps_lock=64, num_lock=128).
    const intentional_mods = mod_raw & 0b00111111;
    if (expected_mods > 0 and expected_mods != intentional_mods) return false;

    // 4. Expect ';' before keycode.
    if (pos >= buf.len or buf[pos] != ';') return false;
    pos += 1;

    // 5. Parse keycode.
    const key_code = parseDecimal(buf, &pos) orelse return false;
    if (key_code != expected_key) return false;

    // 6. Expect '~' terminator.
    return pos < buf.len and buf[pos] == '~';
}

/// Returns true when the user has opted out of the ctrl+\ detach shortcut
/// via ZMX_NO_DETACH_KEY, e.g. to free up ctrl+\ for an inner program
/// like vim, which uses ctrl+\ ctrl+n to escape its own terminal mode.
pub fn isDetachKeyDisabled() bool {
    return lib_posix.getenv("ZMX_NO_DETACH_KEY") != null;
}

fn isKeyPressed(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    // Scan for any CSI u sequence encoding in the buffer.
    var i: usize = 0;
    while (i + 2 < buf.len) : (i += 1) {
        if (buf[i] == 0x1b and buf[i + 1] == '[') {
            if (keypressWithMod(buf[i + 2 ..], expected_key, expected_mods)) return true;
        }
    }
    return false;
}

/// Parses the general CSI u form:
///   CSI key-code[:alternates] ; modifiers[:event-type] [; text-codepoints] u
///
/// Event type is press (1 or absent) or repeat (2). Rejects release (3).
/// Tolerates additional modifiers (caps_lock, num_lock)
/// and alternate key sub-fields from the kitty protocol's progressive
/// enhancement flags.
fn keypressWithMod(buf: []const u8, expected_key: u32, expected_mods: u32) bool {
    const parsed = parseKittyCsiU(buf) orelse return false;
    if (parsed.key_code != expected_key) return false;

    // Only accept intentional modifiers. Lock modifiers
    // (caps_lock=0b1000000, num_lock=0b10000000) are tolerated because
    // they are ambient state, not deliberate key combinations.
    const intentional_mods = parsed.modifiers & 0b00111111;
    if (expected_mods > 0 and expected_mods != intentional_mods) return false;

    // 3 = release -- reject. Accept press (1) and repeat (2).
    return parsed.event_type != 3;
}

pub const KittyCsiU = struct {
    key_code: u32,
    modifiers: u32,
    event_type: u32,
    consumed: usize,
};

pub fn parseKittyCsiU(buf: []const u8) ?KittyCsiU {
    var pos: usize = 0;

    // 1. Parse key code.
    const key_code = parseDecimal(buf, &pos) orelse return null;

    // 2. Skip any ':alternate-key' sub-fields (shifted key, base layout key).
    while (pos < buf.len and buf[pos] == ':') {
        pos += 1; // consume ':'
        _ = parseDecimal(buf, &pos); // consume digits (may be empty for ::base)
    }

    // 3. Expect ';' separator before modifiers.
    if (pos >= buf.len or buf[pos] != ';') return null;
    pos += 1;

    // 4. Parse modifier value. Kitty encodes as 1 + bitfield.
    const mod_encoded = parseDecimal(buf, &pos) orelse return null;
    if (mod_encoded < 1) return null;
    const mod_raw = mod_encoded - 1;

    var event_type: u32 = 1;
    // 5. Parse optional event type after ':'.
    if (pos < buf.len and buf[pos] == ':') {
        pos += 1;
        event_type = parseDecimal(buf, &pos) orelse return null;
    }

    // 6. Skip optional ';text-codepoints' section.
    if (pos < buf.len and buf[pos] == ';') {
        pos += 1;
        // Consume remaining digits and colons until 'u'.
        while (pos < buf.len and (std.ascii.isDigit(buf[pos]) or buf[pos] == ':')) {
            pos += 1;
        }
    }

    // 7. Expect terminal 'u'.
    if (pos >= buf.len or buf[pos] != 'u') return null;
    pos += 1;

    return .{
        .key_code = key_code,
        .modifiers = mod_raw,
        .event_type = event_type,
        .consumed = pos,
    };
}

/// Parse a decimal integer from buf starting at pos, advancing pos past the
/// consumed digits. Returns null if no digits are present.
fn parseDecimal(buf: []const u8, pos: *usize) ?u32 {
    const start = pos.*;
    var value: u32 = 0;
    while (pos.* < buf.len and std.ascii.isDigit(buf[pos.*])) {
        value = value *% 10 +% (buf[pos.*] - '0');
        pos.* += 1;
    }
    if (pos.* == start) return null;
    return value;
}

test "isCtrlBackslash" {
    const expect = testing.expect;

    // Basic: ctrl only (modifier 5 = 1 + 4)
    try expect(isCtrlBackslash("\x1b[92;5u"));

    // Explicit press event type (:1)
    try expect(isCtrlBackslash("\x1b[92;5:1u"));

    // Repeat event (:2) -- user holding Ctrl+\
    try expect(isCtrlBackslash("\x1b[92;5:2u"));

    // Release event (:3) -- must NOT trigger detach
    try expect(!isCtrlBackslash("\x1b[92;5:3u"));

    // Lock modifiers: caps_lock (bit 6) changes modifier value
    // ctrl + caps_lock = 1 + (4 + 64) = 69
    try expect(isCtrlBackslash("\x1b[92;69u"));
    try expect(isCtrlBackslash("\x1b[92;69:1u"));
    try expect(!isCtrlBackslash("\x1b[92;69:3u"));

    // ctrl + num_lock = 1 + (4 + 128) = 133
    try expect(isCtrlBackslash("\x1b[92;133u"));

    // ctrl + caps_lock + num_lock = 1 + (4 + 64 + 128) = 197
    try expect(isCtrlBackslash("\x1b[92;197u"));

    // Combined intentional modifiers -- must NOT match (ctrl+\ is the
    // detach key, not ctrl+shift+\ or ctrl+alt+\)
    // ctrl + shift = 1 + (4 + 1) = 6
    try expect(!isCtrlBackslash("\x1b[92;6u"));

    // ctrl + alt = 1 + (4 + 2) = 7
    try expect(!isCtrlBackslash("\x1b[92;7u"));

    // ctrl + super = 1 + (4 + 8) = 13
    try expect(!isCtrlBackslash("\x1b[92;13u"));

    // ctrl + shift + caps_lock = 1 + (1 + 4 + 64) = 70 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[92;70u"));

    // ctrl + shift + num_lock = 1 + (1 + 4 + 128) = 134 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[92;134u"));

    // Modifier without ctrl bit -- must NOT match
    // shift only = 1 + 1 = 2
    try expect(!isCtrlBackslash("\x1b[92;1u"));
    try expect(!isCtrlBackslash("\x1b[92;2u"));

    // Alternate key sub-fields (report_alternates flag)
    // shifted key | (124): \x1b[92:124;5u
    try expect(isCtrlBackslash("\x1b[92:124;5u"));

    // base layout key only (non-US keyboard): \x1b[92::92;5u
    try expect(isCtrlBackslash("\x1b[92::92;5u"));

    // both shifted and base layout: \x1b[92:124:92;5u
    try expect(isCtrlBackslash("\x1b[92:124:92;5u"));

    // Alternate keys + lock modifiers + event type
    try expect(isCtrlBackslash("\x1b[92:124;69:1u"));
    try expect(!isCtrlBackslash("\x1b[92:124;69:3u"));

    // Text codepoints section (flag 0b10000) -- tolerated and skipped
    // Even though ctrl+\ text is typically empty, terminals may vary
    try expect(isCtrlBackslash("\x1b[92;5;28u"));
    try expect(isCtrlBackslash("\x1b[92;5;28:92u"));

    // Wrong key code -- must NOT match
    try expect(!isCtrlBackslash("\x1b[91;5u"));
    try expect(!isCtrlBackslash("\x1b[93;5u"));
    try expect(!isCtrlBackslash("\x1b[9;5u"));
    try expect(!isCtrlBackslash("\x1b[920;5u"));

    // Sequence embedded in larger buffer (e.g., preceded by other input)
    try expect(isCtrlBackslash("abc\x1b[92;5u"));
    try expect(isCtrlBackslash("\x1b[A\x1b[92;5u"));

    // Garbage / malformed inputs
    try expect(!isCtrlBackslash("garbage"));
    try expect(!isCtrlBackslash(""));
    try expect(!isCtrlBackslash("\x1b["));
    try expect(!isCtrlBackslash("\x1b[92"));
    try expect(!isCtrlBackslash("\x1b[92;"));
    try expect(!isCtrlBackslash("\x1b[92;u"));
    try expect(!isCtrlBackslash("\x1b[;5u"));

    // Other CSI u sequences that happen to contain '92' elsewhere
    try expect(!isCtrlBackslash("\x1b[65;92u"));
}

test "isCtrlBackslash xterm modifyOtherKeys" {
    const expect = std.testing.expect;

    // Basic: ctrl only (modifier 5 = 1 + 4), key 92 = '\'
    // Format: CSI 27 ; <mod> ; <key> ~
    try expect(isCtrlBackslash("\x1b[27;5;92~"));

    // Lock modifiers tolerated
    // ctrl + caps_lock = 1 + (4 + 64) = 69
    try expect(isCtrlBackslash("\x1b[27;69;92~"));
    // ctrl + num_lock = 1 + (4 + 128) = 133
    try expect(isCtrlBackslash("\x1b[27;133;92~"));
    // ctrl + caps_lock + num_lock = 1 + (4 + 64 + 128) = 197
    try expect(isCtrlBackslash("\x1b[27;197;92~"));

    // Combined intentional modifiers must NOT match
    // ctrl + shift = 1 + (4 + 1) = 6
    try expect(!isCtrlBackslash("\x1b[27;6;92~"));
    // ctrl + alt = 1 + (4 + 2) = 7
    try expect(!isCtrlBackslash("\x1b[27;7;92~"));
    // ctrl + super = 1 + (4 + 8) = 13
    try expect(!isCtrlBackslash("\x1b[27;13;92~"));
    // ctrl + shift + caps_lock = 1 + (1 + 4 + 64) = 70 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[27;70;92~"));
    // ctrl + shift + num_lock = 1 + (1 + 4 + 128) = 134 -- shift is intentional
    try expect(!isCtrlBackslash("\x1b[27;134;92~"));

    // Modifier without ctrl bit -- must NOT match
    try expect(!isCtrlBackslash("\x1b[27;1;92~"));
    try expect(!isCtrlBackslash("\x1b[27;2;92~"));

    // Wrong key code -- must NOT match
    try expect(!isCtrlBackslash("\x1b[27;5;91~"));
    try expect(!isCtrlBackslash("\x1b[27;5;93~"));
    try expect(!isCtrlBackslash("\x1b[27;5;65~"));

    // Wrong sentinel -- must NOT match
    try expect(!isCtrlBackslash("\x1b[28;5;92~"));
    try expect(!isCtrlBackslash("\x1b[26;5;92~"));

    // Wrong terminator -- must NOT match
    try expect(!isCtrlBackslash("\x1b[27;5;92u"));
    try expect(!isCtrlBackslash("\x1b[27;5;92m"));

    // CSI sequences that look similar but are not modifyOtherKeys
    try expect(!isCtrlBackslash("\x1b[27m")); // SGR reset reverse
    try expect(!isCtrlBackslash("\x1b[27~")); // xterm F4
    try expect(!isCtrlBackslash("\x1b[27;5R")); // truncated cursor report

    // Sequence embedded in larger buffer
    try expect(isCtrlBackslash("abc\x1b[27;5;92~"));
    try expect(isCtrlBackslash("\x1b[A\x1b[27;5;92~"));

    // Garbage / malformed
    try expect(!isCtrlBackslash("\x1b[27"));
    try expect(!isCtrlBackslash("\x1b[27;"));
    try expect(!isCtrlBackslash("\x1b[27;5"));
    try expect(!isCtrlBackslash("\x1b[27;5;"));
    try expect(!isCtrlBackslash("\x1b[27;5;92"));
}

test "isDetachKeyDisabled" {
    _ = cross.unsetenv("ZMX_NO_DETACH_KEY");
    try testing.expect(!isDetachKeyDisabled());

    _ = cross.setenv("ZMX_NO_DETACH_KEY", "1", 1);
    defer _ = cross.unsetenv("ZMX_NO_DETACH_KEY");
    try testing.expect(isDetachKeyDisabled());
}
