//! The `macterm` CLI in the server binary (design 011). It keeps the grammar,
//! the output and the exit codes of the v1 CLI (`golden/`):
//!
//! - 0: the command worked.
//! - 1: the server refused the command, or it failed.
//! - 2: no server answered.
//! - 64: a usage error (ArgumentParser's `EX_USAGE`).
//!
//! The Swift CLI stays `Resources/bin/macterm` until the swap (design 011
//! §3). Each port issue adds its verbs to `root`, and the golden tests below
//! check each one against the contract.

const std = @import("std");
const command = @import("command.zig");
const client = @import("client.zig");
const output = @import("output.zig");
const m = @import("../protocol/messages.zig");
const chord = @import("../chord.zig");
const skills = @import("skills.zig");
const api = @import("api.zig");

const Command = command.Command;
const Option = command.Option;

/// Where a run reads and writes.
pub const Context = struct {
    /// An arena: the CLI is short-lived.
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// stdin, for `api call --args -`.
    in: ?*std.Io.Reader = null,
};

const socket_option: Option = .{ .names = &.{"--socket"}, .value = "socket", .abstract = "Control socket path. It overrides discovery." };
const json_option: Option = .{ .names = &.{"--json"}, .abstract = "Print the raw JSON payload instead of a table." };

const status_command: Command = .{
    .name = "status",
    .abstract = "Show whether Macterm is running and which project is active.",
    .options = &.{ socket_option, json_option },
};

/// `macterm help <subcommand>`: ArgumentParser's own help command.
const help_command: Command = .{ .name = "help", .abstract = "Show subcommand help information.", .hidden = true };

// ── The pane and session verbs (design 011 issue 5) ─────────────────────────

const project_option: Option = .{ .names = &.{"--project"}, .value = "project", .abstract = "Project scope (name, UUID, or index). The default is the active project." };
const tab_option: Option = .{ .names = &.{"--tab"}, .value = "tab", .abstract = "Tab scope (title, UUID, or index)." };
const pane_option: Option = .{ .names = &.{"--pane"}, .value = "pane", .abstract = "Target pane by UUID, or index within the tab (pane:2)." };
const session_option: Option = .{ .names = &.{"--session"}, .value = "session", .abstract = "Target pane by zmx session name (restart-stable)." };
const target_and_connection = [_]Option{ project_option, tab_option, pane_option, session_option, socket_option, json_option };

const pane_inspect_command: Command = .{
    .name = "inspect",
    .abstract = "Show the live terminal state of a pane: grid, scrollback and foreground process.",
    .options = &target_and_connection,
};

const pane_dump_command: Command = .{
    .name = "dump",
    .abstract = "Print the terminal text of a pane: the viewport, or the full scrollback with --scrollback.",
    .options = &([_]Option{.{ .names = &.{"--scrollback"}, .abstract = "Include the full scrollback, not only the visible viewport." }} ++ target_and_connection),
};

const pane_run_command: Command = .{
    .name = "run",
    .abstract = "Type a command into the shell of a live pane. Add a newline.",
    .usage = "macterm pane run [<options>] [--] <command> ...",
    .discussion =
    \\Pastes a command line into an existing pane's shell and submits it.
    \\
    \\Put the command line after `--`: everything after it is typed verbatim, dashes included, so `macterm pane run --session X -- ls -la` types `ls -la` into X. Before `--`, this command's flags are parsed wherever they appear and words with no leading dash are typed, so `macterm pane run ls` needs no `--`. Any other dash-prefixed word before `--` is an error and nothing is typed: `macterm pane run ls -la` refuses rather than guess whose flag `-la` is. `--help` or `-h` before `--` shows this help.
    \\
    \\`--no-submit` withholds the trailing newline, so the text lands on the prompt unsubmitted — pre-filling a command for a human to inspect, or feeding a TUI that submits on its own terms. Follow it with `macterm pane key return` to execute; that Return registers as a real command submission, exactly as if the text had been typed.
    \\
    \\Both forms ride the terminal's paste path. Reach for `pane key` instead when you need a real key *event* — a control byte (`ctrl+c`) or a named key (`escape`, `up`) — which no text can express.
    \\
    \\With no pane/tab/session selector it targets the current pane via $MACTERM_SESSION.
    ,
    .options = &([_]Option{.{ .names = &.{"--no-submit"}, .abstract = "Leave the text at the shell prompt. Do not run it. (This leaves out the newline at the end.)" }} ++ target_and_connection),
    .arguments = &.{.{ .name = "command", .abstract = "The command line to type, after `--`, exactly as you wrote it.", .optional = true, .repeating = true, .unrecognized = true }},
};

const pane_key_command: Command = .{
    .name = "key",
    .abstract = "Send a single key press to a live pane.",
    .discussion =
    \\Delivers one key press through the terminal's key-encoding path — the counterpart to `pane run`, which pastes a whole command line. Use it for control keys, named keys, and single printable keys a TUI reads as keystrokes rather than as pasted text.
    \\
    \\The chord grammar matches keybinds: modifiers ctrl/cmd/shift/opt joined with '+', then one key token. Examples:
    \\
    \\  macterm pane key ctrl+c          # interrupt the foreground process
    \\  macterm pane key escape          # send Esc to a TUI
    \\  macterm pane key up              # arrow key (mode-aware encoding)
    \\  macterm pane key j               # a bare printable key (vim-style nav)
    \\  macterm pane key shift+1         # the shifted character ('!')
    \\  macterm pane key space           # space bar
    \\  macterm pane key 'ctrl+\'        # SIGQUIT char (quote for the shell)
    \\  macterm pane key enter           # submit (alias of 'return')
    \\
    \\Option chords stay on the raw encoding path — their character is a keyboard-layout translation this path can't resolve — so use `pane run` when you need the literal text Option would compose.
    \\
    \\With no pane/tab/session selector it targets the current pane via $MACTERM_SESSION.
    ,
    .options = &target_and_connection,
    .arguments = &.{.{ .name = "chord", .abstract = "The key combination, for example a, space, ctrl+c, escape, up or ctrl+\\." }},
};

const pane_command: Command = .{
    .name = "pane",
    .abstract = "List, inspect, split, focus and close panes, and run commands in them.",
    .subcommands = &.{ &pane_inspect_command, &pane_dump_command, &pane_run_command, &pane_key_command },
};

const session_name_argument: command.Argument = .{ .name = "name", .abstract = "Session name (macterm-<slug>-<hex>)." };

const session_list_command: Command = .{
    .name = "list",
    .abstract = "List live zmx sessions.",
    .options = &.{ socket_option, json_option },
};

const session_info_command: Command = .{
    .name = "info",
    .abstract = "Show one zmx session.",
    .options = &.{ socket_option, json_option },
    .arguments = &.{session_name_argument},
};

const session_kill_command: Command = .{
    .name = "kill",
    .abstract = "Kill a zmx session. Its shell ends, and the shell of a connected pane exits.",
    .options = &.{ socket_option, json_option },
    .arguments = &.{session_name_argument},
};

const session_command: Command = .{
    .name = "session",
    .abstract = "Inspect and kill terminal sessions that zmx runs.",
    .subcommands = &.{ &session_list_command, &session_info_command, &session_kill_command },
    .default = &session_list_command,
};

// ── skills (design 011 issue 4) ─────────────────────────────────────────────

const skills_command: Command = .{
    .name = "skills",
    .abstract = "Print skills that teach AI coding agents to use Macterm. It works with no running app.",
    .discussion =
    \\Prints Agent Skills: SKILL.md files that Claude Code, Codex, OpenCode, Gemini CLI, Cursor and other agents load from a skills directory. They teach an agent to run commands in panes and read their output, to build a workspace that persists, to run sub-agents in panes of their own, and to write extensions that add screens to the command palette. There is no installer. The agent installs them itself. To set one up, give it this prompt:
    \\
    \\  Run `macterm skills` and install each skill it prints into your skills
    \\  directory as <name>/SKILL.md, exactly as printed. Then tell me what you
    \\  installed and where. (Outside a Macterm pane, `macterm` is
    \\  /Applications/Macterm.app/Contents/Resources/bin/macterm.)
    \\
    \\With no arguments, it prints every skill after a short header about the install. A line with its path introduces each skill (==> <name>/SKILL.md <==). With a name, it prints only that SKILL.md, exactly as it is, ready to redirect into place.
    ,
    .options = &.{
        .{ .names = &.{"--list"}, .abstract = "List the names and descriptions of the skills instead." },
        .{ .names = &.{"--json"}, .abstract = "Print JSON: the name, description, path and (without --list) text of each skill." },
    },
    .arguments = &.{.{ .name = "name", .abstract = "Print only the SKILL.md of this skill, exactly as it is.", .optional = true }},
};

/// `skills`: the text is in the binary, so it needs no server.
fn skillsRun(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const list = parsed.flag("--list");
    const name: ?[]const u8 = if (parsed.positionals.len > 0) parsed.positionals[0] else null;
    if (list and name != null) {
        try output.writeError(ctx.err, "pass a skill name or --list, not both", null);
        return 1;
    }
    var chosen: []const skills.Skill = &skills.all;
    if (name) |n| {
        const s = skills.named(n) orelse {
            try output.writeError(ctx.err, try std.fmt.allocPrint(ctx.arena, "no skill named \"{s}\"", .{n}), "run `macterm skills --list` for their names");
            return 1;
        };
        chosen = s[0..1];
    }
    if (parsed.flag("--json")) {
        // `--list` leaves out the text, as v1 left out a nil field.
        const Row = struct { name: []const u8, description: []const u8, path: []const u8, text: ?[]const u8 };
        const rows = try ctx.arena.alloc(Row, chosen.len);
        for (chosen, rows) |s, *r| r.* = .{ .name = s.name, .description = s.description, .path = s.path, .text = if (list) null else s.text };
        try output.writeJson(ctx.arena, ctx.out, try toJson(ctx.arena, struct { skills: []const Row }{ .skills = rows }));
    } else if (list) {
        try skills.writeList(ctx.out);
    } else if (name != null) {
        try ctx.out.writeAll(chosen[0].text);
    } else try skills.writeCatalog(ctx.out);
    return 0;
}

// ── api (design 011 §4) ─────────────────────────────────────────────────────

const method_argument: command.Argument = .{ .name = "method", .abstract = "The name of the method, as `macterm api list` prints it." };

const api_list_command: Command = .{
    .name = "list",
    .abstract = "List the methods of the server that this CLI can call. It works with no server.",
    .options = &.{.{ .names = &.{"--json"}, .abstract = "Print JSON: the name, level and description of each method." }},
};

const api_describe_command: Command = .{
    .name = "describe",
    .abstract = "Print a method as JSON: its arguments and its result as JSON Schema. It works with no server.",
    .arguments = &.{method_argument},
};

const api_call_command: Command = .{
    .name = "call",
    .abstract = "Send one request to the server and print its result as JSON.",
    .options = &.{
        .{ .names = &.{"--args"}, .value = "json", .abstract = "The arguments as a JSON object, or - to read them from stdin. The default is {}." },
        socket_option,
    },
    .arguments = &.{method_argument},
};

const api_command: Command = .{
    .name = "api",
    .abstract = "List, describe and call the methods of the server's protocol.",
    .discussion =
    \\The methods and their types come from the protocol of this build. The arguments and the result use the keys of the protocol (snake_case). Bytes are JSON strings.
    ,
    .subcommands = &.{ &api_list_command, &api_describe_command, &api_call_command },
};

fn apiList(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    if (parsed.flag("--json")) {
        try output.writeJson(ctx.arena, ctx.out, try api.listJson(ctx.arena));
    } else try output.writeColumns(ctx.arena, ctx.out, try api.listRows(ctx.arena));
    return 0;
}

fn apiMethod(ctx: Context, name: []const u8) error{ OutOfMemory, WriteFailed }!?api.Method {
    if (api.find(name)) |method| return method;
    try output.writeError(ctx.err, try std.fmt.allocPrint(ctx.arena, "no method named \"{s}\"", .{name}), "run `macterm api list` for their names");
    return null;
}

fn apiDescribe(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const method = (try apiMethod(ctx, parsed.positionals[0])) orelse return 1;
    try output.writeJson(ctx.arena, ctx.out, try api.describe(ctx.arena, method));
    return 0;
}

fn apiCall(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const method = (try apiMethod(ctx, parsed.positionals[0])) orelse return 1;
    const text = parsed.value("--args") orelse "{}";
    const json = if (!std.mem.eql(u8, text, "-")) text else read: {
        const in = ctx.in orelse break :read "";
        // A request that is larger than one frame cannot go.
        break :read in.allocRemaining(ctx.arena, .limited(server_frame_max)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => {
                try output.writeError(ctx.err, "the arguments on stdin are larger than one request holds (1 MiB)", null);
                return 1;
            },
            else => {
                try output.writeError(ctx.err, "could not read the arguments from stdin", null);
                return 1;
            },
        };
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try output.writeError(ctx.err, "the arguments are not JSON", "give a JSON object, for example --args '{\"id\": \"macterm-x\"}'");
            return 1;
        },
    };
    inline for (m.methods) |M| {
        if (comptime m.maySend(M, .local)) if (std.mem.eql(u8, method.name, M.name)) return apiSend(ctx, parsed, M, value);
    }
    unreachable;
}

/// `server.frame_max`: the server reads no larger request.
const server_frame_max = 1024 * 1024;

fn apiSend(ctx: Context, parsed: command.Parsed, comptime M: type, value: std.json.Value) error{ OutOfMemory, WriteFailed }!u8 {
    var fault: api.Fault = .{};
    const args = api.fromJson(M.Args, ctx.arena, value, &fault) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            const message = try std.fmt.allocPrint(ctx.arena, "args{s}: {s}", .{ fault.path.items, fault.message });
            try output.writeError(ctx.err, message, "run `macterm api describe " ++ M.name ++ "` for the arguments");
            return 1;
        },
    };
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    switch (conn.request(M, args) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => |result| try output.writeJson(ctx.arena, ctx.out, try api.toJson(ctx.arena, result)),
        .err => |e| {
            try output.writeError(ctx.err, try std.fmt.allocPrint(ctx.arena, "{s} ({s})", .{ e.message, e.code }), null);
            return 1;
        },
    }
    return 0;
}

pub const root: Command = .{
    .name = "macterm",
    .abstract = "Control a running Macterm: projects, tabs, panes, zmx sessions.",
    .subcommands = &.{ &status_command, &pane_command, &session_command, &skills_command, &api_command, &help_command },
};

/// Runs one argument line (without the program name) and returns the exit
/// code.
pub fn run(ctx: Context, words: []const []const u8) error{ OutOfMemory, WriteFailed }!u8 {
    switch (try command.parse(ctx.arena, &root, words)) {
        .help => |path| {
            try command.writeHelp(ctx.out, path);
            return 0;
        },
        .usage_error => |e| {
            try command.writeUsageError(ctx.err, e.path, e.message);
            return command.usage_exit;
        },
        .run => |parsed| {
            const c = parsed.command();
            if (c == &status_command) return status(ctx, parsed);
            if (c == &pane_run_command) return paneRun(ctx, parsed);
            if (c == &pane_key_command) return paneKey(ctx, parsed);
            if (c == &pane_dump_command) return paneDump(ctx, parsed);
            if (c == &pane_inspect_command) return paneInspect(ctx, parsed);
            if (c == &session_list_command) return sessionList(ctx, parsed);
            if (c == &session_info_command) return sessionInfo(ctx, parsed);
            if (c == &session_kill_command) return sessionKill(ctx, parsed);
            if (c == &skills_command) return skillsRun(ctx, parsed);
            if (c == &api_list_command) return apiList(ctx, parsed);
            if (c == &api_describe_command) return apiDescribe(ctx, parsed);
            if (c == &api_call_command) return apiCall(ctx, parsed);
            unreachable;
        },
    }
}

// ── status ──────────────────────────────────────────────────────────────────

/// What `status` prints, with the JSON keys of v1. `activeProject` and
/// `activeProjectID` come with the model (design 010); until then they are
/// absent, as v1 printed them with no active project.
pub const Status = struct {
    version: []const u8,
    pid: ?i64 = null,
    activeProject: ?[]const u8 = null,
    activeProjectID: ?[]const u8 = null,
};

/// `status`: the server's build and pid. It sends `ping`, so that a server
/// that answers the handshake but no request is not reported as up.
fn status(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    switch (conn.request(m.Ping, .{}) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => {},
        .err => |e| {
            try output.writeError(ctx.err, e.message, null);
            return 1;
        },
    }
    try writeStatus(ctx, .{ .version = conn.hello.build, .pid = if (conn.pid) |p| p else null }, parsed.flag("--json"));
    return 0;
}

fn writeStatus(ctx: Context, s: Status, json: bool) error{ OutOfMemory, WriteFailed }!void {
    if (json) {
        var fields: std.json.ObjectMap = .empty;
        try fields.put(ctx.arena, "version", .{ .string = s.version });
        if (s.pid) |pid| try fields.put(ctx.arena, "pid", .{ .integer = pid });
        if (s.activeProject) |p| try fields.put(ctx.arena, "activeProject", .{ .string = p });
        if (s.activeProjectID) |p| try fields.put(ctx.arena, "activeProjectID", .{ .string = p });
        var data: std.json.ObjectMap = .empty;
        try data.put(ctx.arena, "status", .{ .object = fields });
        return output.writeJson(ctx.arena, ctx.out, .{ .object = data });
    }
    try ctx.out.print("Macterm {s}", .{s.version});
    if (s.pid) |pid| try ctx.out.print(" (pid {d})", .{pid});
    if (s.activeProject) |p| try ctx.out.print(" \u{2014} active project: {s}", .{p});
    try ctx.out.writeByte('\n');
}

// ── Pane targets ────────────────────────────────────────────────────────────

/// The session that a pane verb acts on, or the text of a failure (exit 1).
pub const Target = union(enum) { session: []const u8, failed: []const u8 };

/// `--session`, or else `MACTERM_SESSION` when no `--tab` or `--pane` names
/// another pane (v1's `PaneTarget`). `--project`, `--tab` and `--pane` name a
/// pane in the model (design 010), which this CLI does not read yet.
pub fn paneTarget(env: *const std.process.Environ.Map, parsed: command.Parsed) Target {
    if (nonEmpty(parsed.value("--session"))) |name| return .{ .session = name };
    const in_tab = parsed.value("--tab") != null or parsed.value("--pane") != null;
    if (!in_tab) if (nonEmpty(env.get("MACTERM_SESSION"))) |name| return .{ .session = name };
    if (in_tab or parsed.value("--project") != null)
        return .{ .failed = "--project, --tab and --pane are not available in this CLI yet: use --session <name>" };
    return .{ .failed = "no pane to act on: use --session <name>, or run the command in a Macterm pane" };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

fn targetOrExit(ctx: Context, parsed: command.Parsed) error{WriteFailed}!?[]const u8 {
    switch (paneTarget(ctx.env, parsed)) {
        .session => |name| return name,
        .failed => |message| {
            try output.writeError(ctx.err, message, "run `macterm session list` to see live sessions");
            return null;
        },
    }
}

// ── pane run ────────────────────────────────────────────────────────────────

/// What `pane run` types, or the usage error of a stray flag.
pub const RunLine = union(enum) { text: []const u8, stray: []const u8 };

/// The words of `pane run`: plain words before `--` and every word after it
/// are typed. A word with a dash before `--` is refused: it is a mistyped
/// flag or a flag of the typed command, and a guess types into the wrong
/// place. A lone `-` is a word.
pub fn runLine(arena: std.mem.Allocator, words: []const []const u8) error{OutOfMemory}!RunLine {
    var typed: std.ArrayList([]const u8) = .empty;
    var after = false;
    for (words) |word| {
        if (!after and std.mem.eql(u8, word, "--")) {
            after = true;
            continue;
        }
        if (!after and word.len > 1 and word[0] == '-') return .{ .stray = word };
        try typed.append(arena, word);
    }
    return .{ .text = try std.mem.join(arena, " ", typed.items) };
}

/// `word` quoted for a POSIX shell, bare when it needs no quotes (v1's
/// `shellQuoted`).
fn writeShellWord(w: *std.Io.Writer, word: []const u8) std.Io.Writer.Error!void {
    var bare = word.len > 0;
    for (word) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "@%+=:,./_-", c) != null)) bare = false;
    }
    if (bare) return w.writeAll(word);
    try w.writeByte('\'');
    for (word) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    try w.writeByte('\'');
}

/// The usage error of a stray flag, with the same line moved after `--`.
fn writeStray(ctx: Context, parsed: command.Parsed, stray: []const u8) error{ OutOfMemory, WriteFailed }!void {
    var fix: std.Io.Writer.Allocating = .init(ctx.arena);
    const w = &fix.writer;
    try w.writeAll("macterm pane run");
    if (parsed.flag("--no-submit")) try w.writeAll(" --no-submit");
    for ([_][]const u8{ "--project", "--tab", "--pane", "--session", "--socket" }) |name| {
        if (parsed.value(name)) |v| {
            try w.print(" {s} ", .{name});
            try writeShellWord(w, v);
        }
    }
    if (parsed.flag("--json")) try w.writeAll(" --json");
    try w.writeAll(" --");
    var typed: std.ArrayList([]const u8) = .empty;
    var after = false;
    for (parsed.positionals) |word| {
        if (!after and std.mem.eql(u8, word, "--")) {
            after = true;
            continue;
        }
        try typed.append(ctx.arena, word);
    }
    for (typed.items) |word| {
        try w.writeByte(' ');
        try writeShellWord(w, word);
    }
    const message = try std.fmt.allocPrint(ctx.arena, "`{s}` is not a `pane run` option, so nothing was typed. To type it, put the command line after `--`:\n  {s}", .{ stray, fix.written() });
    try command.writeUsageError(ctx.err, parsed.path, message);
}

fn paneRun(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const text = switch (try runLine(ctx.arena, parsed.positionals)) {
        .text => |t| t,
        .stray => |word| {
            try writeStray(ctx, parsed, word);
            return command.usage_exit;
        },
    };
    if (text.len == 0) {
        try output.writeError(ctx.err, "nothing to run", null);
        return 1;
    }
    const id = (try targetOrExit(ctx, parsed)) orelse return 1;
    return simple(ctx, parsed, m.SessionSend, .{ .id = id, .text = .{ .bytes = text }, .submit = !parsed.flag("--no-submit") });
}

// ── pane key ────────────────────────────────────────────────────────────────

fn paneKey(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const raw = parsed.positionals[0];
    if (chord.parse(raw) == null) {
        const message = try std.fmt.allocPrint(ctx.arena, "unrecognized key combination '{s}'", .{raw});
        try output.writeError(ctx.err, message, "use a name such as ctrl+c, escape, up or ctrl+\\ (see `macterm pane key --help`)");
        return 1;
    }
    const id = (try targetOrExit(ctx, parsed)) orelse return 1;
    return simple(ctx, parsed, m.SessionKey, .{ .id = id, .chord = raw });
}

/// Sends a request whose result has nothing to print. `--json` prints the
/// empty payload, as v1 printed a reply with no data.
fn simple(ctx: Context, parsed: command.Parsed, comptime M: type, args: M.Args) error{ OutOfMemory, WriteFailed }!u8 {
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    switch (conn.request(M, args) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => {},
        .err => |e| return serverError(ctx, e, sessionArg(M, args)),
    }
    if (parsed.flag("--json")) try output.writeJson(ctx.arena, ctx.out, .{ .object = .empty });
    return 0;
}

fn sessionArg(comptime M: type, args: M.Args) ?[]const u8 {
    return if (@hasField(M.Args, "id")) args.id else null;
}

/// The server's error. `not_found` for a session name gets v1's text.
fn serverError(ctx: Context, e: m.ErrorInfo, session: ?[]const u8) error{ OutOfMemory, WriteFailed }!u8 {
    if (std.mem.eql(u8, e.code, "not_found")) if (session) |name| {
        try writeNoSession(ctx, name);
        return 1;
    };
    try output.writeError(ctx.err, e.message, null);
    return 1;
}

fn writeNoSession(ctx: Context, name: []const u8) error{ OutOfMemory, WriteFailed }!void {
    const message = try std.fmt.allocPrint(ctx.arena, "no zmx session named \"{s}\"", .{name});
    try output.writeError(ctx.err, message, "run `macterm session list` to see live sessions");
}

// ── pane dump ───────────────────────────────────────────────────────────────

/// What `pane dump` prints, with the JSON keys of v1. `id` is the pane's,
/// from the model (design 010): absent until then.
pub const Dump = struct {
    id: ?[]const u8 = null,
    session: []const u8,
    scrollback: bool,
    bytes: usize,
    text: []const u8,
};

fn paneDump(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const id = (try targetOrExit(ctx, parsed)) orelse return 1;
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    const scrollback = parsed.flag("--scrollback");
    const result = switch (conn.request(m.SessionHistory, .{ .id = id, .scrollback = scrollback }) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => |r| r,
        .err => |e| return serverError(ctx, e, id),
    };
    const text = result.text.bytes;
    try writeDump(ctx, .{ .session = id, .scrollback = scrollback, .bytes = text.len, .text = text }, parsed.flag("--json"));
    if (result.truncated)
        try ctx.err.print("macterm: the text is longer than one reply holds: this is its last {d} KiB\n", .{text.len / 1024});
    return 0;
}

/// The text as it is, with one newline at the end (v1's `renderDump`).
fn writeDump(ctx: Context, d: Dump, json: bool) error{ OutOfMemory, WriteFailed }!void {
    if (json) {
        var data: std.json.ObjectMap = .empty;
        try data.put(ctx.arena, "dump", try toJson(ctx.arena, d));
        return output.writeJson(ctx.arena, ctx.out, .{ .object = data });
    }
    if (d.text.len == 0) return;
    try ctx.out.writeAll(d.text);
    if (d.text[d.text.len - 1] != '\n') try ctx.out.writeByte('\n');
}

// ── pane inspect ────────────────────────────────────────────────────────────

/// What `pane inspect` prints, with the JSON keys of v1. The cell and
/// surface sizes, the content scale and read-only are the GUI's, and `id` is
/// the model's: null until the server asks the GUI (design 011 §1).
pub const Inspect = struct {
    id: ?[]const u8 = null,
    session: []const u8,
    cols: i64,
    rows: i64,
    cellWidthPx: ?i64 = null,
    cellHeightPx: ?i64 = null,
    widthPx: ?i64 = null,
    heightPx: ?i64 = null,
    scrollbackTotal: ?u64 = null,
    scrollbackOffset: ?u64 = null,
    scrollbackLen: ?u64 = null,
    altScreen: ?bool = null,
    contentScale: ?f64 = null,
    foregroundPID: ?i64 = null,
    foregroundArgv: ?[]const []const u8 = null,
    processExited: bool,
    /// Null when the session cannot read the foreground.
    needsConfirmQuit: ?bool = null,
    readOnly: ?bool = null,
};

fn paneInspect(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const id = (try targetOrExit(ctx, parsed)) orelse return 1;
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    const t = switch (conn.request(m.SessionInspect, .{ .id = id }) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => |r| r.terminal,
        .err => |e| return serverError(ctx, e, id),
    };
    try writeInspect(ctx, try inspectOf(ctx.arena, id, t), parsed.flag("--json"));
    return 0;
}

pub fn inspectOf(arena: std.mem.Allocator, session: []const u8, t: m.TerminalState) error{OutOfMemory}!Inspect {
    var argv: ?[]const []const u8 = null;
    if (t.foreground_argv) |words| {
        const list = try arena.alloc([]const u8, words.len);
        for (words, list) |word, *out| out.* = try arena.dupe(u8, word.bytes);
        argv = list;
    }
    return .{
        .session = try arena.dupe(u8, session),
        .cols = t.cols,
        .rows = t.rows,
        .scrollbackTotal = t.scrollback_total,
        .scrollbackOffset = t.scrollback_offset,
        .scrollbackLen = t.scrollback_len,
        .altScreen = t.alt_screen,
        .foregroundPID = t.foreground_pid,
        .foregroundArgv = argv,
        .processExited = t.exited,
        .needsConfirmQuit = if (t.exited) false else t.busy,
    };
}

fn writeInspect(ctx: Context, i: Inspect, json: bool) error{ OutOfMemory, WriteFailed }!void {
    if (json) {
        var data: std.json.ObjectMap = .empty;
        try data.put(ctx.arena, "inspect", try toJson(ctx.arena, i));
        return output.writeJson(ctx.arena, ctx.out, .{ .object = data });
    }
    const a = ctx.arena;
    const dash = "-";
    const pair = struct {
        fn f(arena: std.mem.Allocator, x: ?i64, y: ?i64) ![]const u8 {
            if (x == null or y == null) return "-";
            return std.fmt.allocPrint(arena, "{d}\u{d7}{d}", .{ x.?, y.? });
        }
    }.f;
    const scrollback = if (i.scrollbackTotal) |total|
        try std.fmt.allocPrint(a, "{d} total, {s} offset, {s} len", .{ total, try optText(a, i.scrollbackOffset), try optText(a, i.scrollbackLen) })
    else
        dash;
    const fg = if (i.foregroundPID) |pid| fg: {
        const argv = if (i.foregroundArgv) |words| try std.mem.join(a, " ", words) else "";
        break :fg if (argv.len == 0) try std.fmt.allocPrint(a, "{d}", .{pid}) else try std.fmt.allocPrint(a, "{d} ({s})", .{ pid, argv });
    } else dash;
    // Swift prints a whole Double with ".0".
    const scale = if (i.contentScale) |v|
        (if (v == @floor(v)) try std.fmt.allocPrint(a, "{d}.0", .{v}) else try std.fmt.allocPrint(a, "{d}", .{v}))
    else
        dash;
    try output.writeColumns(a, ctx.out, &.{
        &.{ "session", i.session },
        &.{ "grid", try pair(a, i.cols, i.rows) },
        &.{ "cell px", try pair(a, i.cellWidthPx, i.cellHeightPx) },
        &.{ "surface px", try pair(a, i.widthPx, i.heightPx) },
        &.{ "scrollback", scrollback },
        &.{ "alt-screen", try optText(a, i.altScreen) },
        &.{ "content scale", scale },
        &.{ "foreground", fg },
        &.{ "process exited", if (i.processExited) "true" else "false" },
        &.{ "needs confirm quit", try optText(a, i.needsConfirmQuit) },
        &.{ "read-only", try optText(a, i.readOnly) },
    });
}

fn optText(arena: std.mem.Allocator, v: anytype) error{OutOfMemory}![]const u8 {
    const x = v orelse return "-";
    return switch (@TypeOf(x)) {
        bool => if (x) "true" else "false",
        else => std.fmt.allocPrint(arena, "{d}", .{x}),
    };
}

// ── session list, info, kill ────────────────────────────────────────────────

/// One session, with the JSON keys of v1. `paneID` is the pane that shows
/// it, from the model (design 010).
pub const SessionRow = struct {
    name: []const u8,
    clients: ?i64 = null,
    leaderPID: ?i64 = null,
    paneID: ?[]const u8 = null,
};

/// `panes`: the rows say which pane shows each session. Until the model
/// (design 010) the CLI cannot say, and the last column is `-`.
fn writeSessions(ctx: Context, rows: []const SessionRow, panes: bool, json: bool) error{ OutOfMemory, WriteFailed }!void {
    if (json) {
        var list: std.json.Array = .init(ctx.arena);
        for (rows) |row| try list.append(try toJson(ctx.arena, row));
        var data: std.json.ObjectMap = .empty;
        try data.put(ctx.arena, "sessions", .{ .array = list });
        return output.writeJson(ctx.arena, ctx.out, .{ .object = data });
    }
    const table = try ctx.arena.alloc([]const []const u8, rows.len);
    for (rows, table) |row, *cells| {
        const pane: []const u8 = if (!panes) "-" else if (row.paneID != null) "attached-pane" else "orphan";
        cells.* = try ctx.arena.dupe([]const u8, &.{
            row.name,
            try std.fmt.allocPrint(ctx.arena, "clients:{s}", .{if (row.clients) |n| try std.fmt.allocPrint(ctx.arena, "{d}", .{n}) else "?"}),
            if (row.leaderPID) |pid| try std.fmt.allocPrint(ctx.arena, "pid:{d}", .{pid}) else "pid:-",
            pane,
        });
    }
    try output.writeColumns(ctx.arena, ctx.out, table);
}

fn rowOf(arena: std.mem.Allocator, s: m.Session) error{OutOfMemory}!SessionRow {
    return .{ .name = try arena.dupe(u8, s.id), .clients = if (s.clients) |n| n else null, .leaderPID = s.shell_pid };
}

fn sessionList(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    const sessions = switch (conn.request(m.SessionList, .{}) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => |r| r.sessions,
        .err => |e| return serverError(ctx, e, null),
    };
    // Only running sessions, as v1 listed them.
    var rows: std.ArrayList(SessionRow) = .empty;
    for (sessions) |s| if (s.state == .running) try rows.append(ctx.arena, try rowOf(ctx.arena, s));
    try writeSessions(ctx, rows.items, false, parsed.flag("--json"));
    return 0;
}

fn sessionInfo(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    const name = parsed.positionals[0];
    var conn = switch (try connect(ctx, parsed)) {
        .ok => |c| c,
        .exit => |code| return code,
    };
    defer conn.close();
    const s = switch (conn.request(m.SessionInfo, .{ .id = name }) catch |err| return requestFailed(ctx, conn, err)) {
        .ok => |r| r.session,
        .err => |e| return serverError(ctx, e, name),
    };
    if (s.state != .running) {
        try writeNoSession(ctx, name);
        return 1;
    }
    try writeSessions(ctx, &.{try rowOf(ctx.arena, s)}, false, parsed.flag("--json"));
    return 0;
}

fn sessionKill(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!u8 {
    return simple(ctx, parsed, m.SessionKill, .{ .id = parsed.positionals[0] });
}

/// A struct as a JSON object: a null field is left out, as `JSONEncoder`
/// leaves out a nil optional.
fn toJson(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}!std.json.Value {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var map: std.json.ObjectMap = .empty;
            inline for (info.field_names, info.field_types) |name, F| {
                const v = @field(value, name);
                if (@typeInfo(F) == .optional) {
                    if (v) |inner| try map.put(arena, name, try toJson(arena, inner));
                } else try map.put(arena, name, try toJson(arena, v));
            }
            return .{ .object = map };
        },
        .bool => return .{ .bool = value },
        .int, .comptime_int => return .{ .integer = @intCast(value) },
        .float => return .{ .float = value },
        .pointer => {
            if (T == []const u8) return .{ .string = value };
            var list: std.json.Array = .init(arena);
            for (value) |item| try list.append(try toJson(arena, item));
            return .{ .array = list };
        },
        else => @compileError("no JSON form for " ++ @typeName(T)),
    }
}

// ── The connection ──────────────────────────────────────────────────────────

const Connected = union(enum) { ok: client.Connection, exit: u8 };

/// Connects as `--socket` and the environment say, or prints why not and
/// gives the exit code.
fn connect(ctx: Context, parsed: command.Parsed) error{ OutOfMemory, WriteFailed }!Connected {
    const pin = parsed.value("--socket");
    const paths = try client.candidates(ctx.arena, ctx.env, pin);
    switch (try client.connect(ctx.arena, paths)) {
        .ok => |c| return .{ .ok = c },
        .failed => |message| {
            try output.writeError(ctx.err, message, null);
            return .{ .exit = 1 };
        },
        .no_server => |attempts| {
            var text: std.Io.Writer.Allocating = .init(ctx.arena);
            const w = &text.writer;
            if (attempts.len == 0) {
                try output.writeError(ctx.err, "no runtime folder: set MACTERM_RUNTIME_DIR, or use --socket", null);
                return .{ .exit = 2 };
            }
            try w.writeAll("could not reach the Macterm server:");
            for (attempts) |a| try w.print("\n  {s}: {s}", .{ a.path, a.reason });
            if (pin == null or pin.?.len == 0)
                try w.writeAll("\nIs Macterm running? Start it, or use --socket for a different location.");
            try output.writeError(ctx.err, text.written(), null);
            return .{ .exit = 2 };
        },
    }
}

fn requestFailed(ctx: Context, conn: client.Connection, err: client.Connection.RequestError) error{ OutOfMemory, WriteFailed }!u8 {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoReply => {
            try ctx.err.print("macterm: the server at {s} stopped answering\n", .{conn.path});
            return 2;
        },
        error.Protocol => {
            try ctx.err.print("macterm: the server at {s} sent a reply that does not decode\n", .{conn.path});
            return 1;
        },
    }
}

// ── Tests: the golden files ─────────────────────────────────────────────────

const testing = std.testing;
const contract = @import("contract.zig");

const golden_cases_json = @embedFile("golden/cases.json");

/// The golden help text of each command that prints it byte for byte. A
/// group prints only the subcommands that are ported, so its help is checked
/// by structure alone.
const golden_help = .{
    .{ [_]*const Command{&status_command}, @embedFile("golden/help/status.txt") },
    .{ [_]*const Command{ &pane_command, &pane_inspect_command }, @embedFile("golden/help/pane-inspect.txt") },
    .{ [_]*const Command{ &pane_command, &pane_dump_command }, @embedFile("golden/help/pane-dump.txt") },
    .{ [_]*const Command{ &pane_command, &pane_run_command }, @embedFile("golden/help/pane-run.txt") },
    .{ [_]*const Command{ &pane_command, &pane_key_command }, @embedFile("golden/help/pane-key.txt") },
    .{ [_]*const Command{&session_command}, @embedFile("golden/help/session.txt") },
    .{ [_]*const Command{ &session_command, &session_list_command }, @embedFile("golden/help/session-list.txt") },
    .{ [_]*const Command{ &session_command, &session_info_command }, @embedFile("golden/help/session-info.txt") },
    .{ [_]*const Command{ &session_command, &session_kill_command }, @embedFile("golden/help/session-kill.txt") },
    .{ [_]*const Command{&skills_command}, @embedFile("golden/help/skills.txt") },
};

fn collapse(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \n");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    return out.items;
}

/// The commands that v1 did not have (design 011 §4). The contract has no
/// line for them.
const new_in_v2 = [_]*const Command{&api_command};

fn expectCommandMatchesContract(arena: std.mem.Allocator, spec: contract.Contract, path: []const *const Command) !void {
    const c = path[path.len - 1];
    const words = try arena.alloc([]const u8, path.len - 1);
    for (path[1..], words) |p, *w| w.* = p.name;
    const golden = spec.find(words) orelse {
        std.debug.print("macterm {f}: not in the contract\n", .{std.json.fmt(words, .{})});
        return error.NotInContract;
    };
    try testing.expectEqualStrings(golden.abstract, c.abstract);
    try testing.expectEqual(golden.hidden, c.hidden);
    try testing.expect(!golden.debug);
    if (c == &help_command) return;

    var usage: std.Io.Writer.Allocating = .init(arena);
    try command.writeUsage(&usage.writer, path);
    try testing.expectEqualStrings(golden.usage.?, usage.written());
    // A group's default, when the default is ported.
    if (c.default) |d| try testing.expectEqualStrings(golden.default.?, d.name);
    if (golden.default) |name| for (c.subcommands) |sub| {
        if (std.mem.eql(u8, sub.name, name)) try testing.expect(c.default == sub);
    };
    try testing.expectEqualStrings(golden.discussion orelse "", c.discussion orelse "");

    // Options: the same names, values and abstracts, in the same order.
    var visible: std.ArrayList(contract.Contract.Option) = .empty;
    for (golden.options) |o| if (!o.hidden) try visible.append(arena, o);
    var all: std.ArrayList(Option) = .empty;
    try all.appendSlice(arena, c.options);
    try all.append(arena, command.help_option);
    var n: usize = 0;
    for (all.items) |o| {
        defer n += 1;
        try testing.expect(n < visible.items.len);
        const g = visible.items[n];
        try testing.expectEqual(g.names.len, o.names.len);
        for (g.names, o.names) |a, b| try testing.expectEqualStrings(a, b);
        try testing.expectEqualStrings(g.value orelse "", o.value orelse "");
        try testing.expectEqualStrings(try collapse(arena, g.abstract), try collapse(arena, o.abstract));
    }
    try testing.expectEqual(visible.items.len, n);

    try testing.expectEqual(golden.arguments.len, c.arguments.len);
    for (golden.arguments, c.arguments) |g, a| {
        try testing.expectEqualStrings(g.name, a.name);
        try testing.expectEqual(g.optional, a.optional);
        try testing.expectEqual(g.repeating, a.repeating);
        try testing.expectEqual(std.mem.eql(u8, g.takes orelse "", "unrecognized"), a.unrecognized);
        try testing.expectEqualStrings(try collapse(arena, g.abstract), try collapse(arena, a.abstract));
    }

    // Subcommands: each ported one is in the contract, in the same order.
    var last: usize = 0;
    for (c.subcommands) |sub| {
        if (std.mem.indexOfScalar(*const Command, &new_in_v2, sub) != null) continue;
        var at: ?usize = null;
        for (golden.subcommands, 0..) |name, k| {
            if (std.mem.eql(u8, name, sub.name)) at = k;
        }
        try testing.expect(at != null and at.? >= last);
        last = at.?;
        const child = try arena.alloc(*const Command, path.len + 1);
        @memcpy(child[0..path.len], path);
        child[path.len] = sub;
        try expectCommandMatchesContract(arena, spec, child);
    }
}

test "every ported command has the abstract, usage, options and arguments of the contract" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spec = try contract.parseContract(arena.allocator());
    try expectCommandMatchesContract(arena.allocator(), spec, &.{&root});
}

test "the help of a ported leaf command is the golden text" {
    inline for (golden_help) |entry| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try command.writeHelp(&out.writer, &([_]*const Command{&root} ++ entry[0]));
        try testing.expectEqualStrings(entry[1], out.written());
    }
}

test "the overview of a group wraps as its golden help" {
    // The overview of `pane` ends at column 80 on one line; that of
    // `session` is short.
    inline for (.{ .{ &pane_command, @embedFile("golden/help/pane.txt") }, .{ &session_command, @embedFile("golden/help/session.txt") } }) |entry| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try command.writeHelp(&out.writer, &.{ &root, entry[0] });
        const golden = entry[1][0 .. std.mem.indexOf(u8, entry[1], "\n\n").? + 2];
        try testing.expect(std.mem.startsWith(u8, out.written(), golden));
    }
}

test "the root help lists the ported commands as the golden text does, and api" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try command.writeHelp(&out.writer, &.{&root});
    try testing.expectEqualStrings(
        \\OVERVIEW: Control a running Macterm: projects, tabs, panes, zmx sessions.
        \\
        \\USAGE: macterm <subcommand>
        \\
        \\OPTIONS:
        \\  -h, --help              Show help information.
        \\
        \\SUBCOMMANDS:
        \\  status                  Show whether Macterm is running and which project is
        \\                          active.
        \\  pane                    List, inspect, split, focus and close panes, and run
        \\                          commands in them.
        \\  session                 Inspect and kill terminal sessions that zmx runs.
        \\  skills                  Print skills that teach AI coding agents to use
        \\                          Macterm. It works with no running app.
        \\  api                     List, describe and call the methods of the server's
        \\                          protocol.
        \\
        \\  See 'macterm help <subcommand>' for detailed help.
        \\
    , out.written());
}

const GoldenCase = struct {
    arguments: []const []const u8,
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
    requests: []const std.json.Value,
};

/// The v1 response of a canned case, as `ControlResponse` holds it.
const CannedStatus = struct {
    ok: bool,
    data: ?struct { status: Status } = null,
    @"error": ?struct { code: []const u8, message: []const u8, action: ?[]const u8 = null } = null,
};

test "status and usage errors print the golden output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spec = try contract.parseContract(arena);
    const inputs = try contract.parseCases(arena);
    const goldens = try std.json.parseFromSliceLeaky([]const GoldenCase, arena, golden_cases_json, .{});
    try testing.expectEqual(inputs.len, goldens.len);

    var env: std.process.Environ.Map = .init(arena);
    try env.put("MACTERM_SESSION", env_session);
    var checked: usize = 0;
    for (inputs, goldens) |input, golden| {
        var out: std.Io.Writer.Allocating = .init(arena);
        var err: std.Io.Writer.Allocating = .init(arena);
        const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
        const exit: u8 = switch (try command.parse(arena, &root, input.arguments)) {
            // A word that is not a command: the other verbs are not ported yet.
            .usage_error => if (spec.find(input.arguments[0..1]) == null) try run(ctx, input.arguments) else continue,
            .run => |parsed| if (try cannedVerb(ctx, parsed, input, golden)) |code| code else if (parsed.command() == &status_command) exit: {
                try testing.expectEqualStrings("ping", input.method.?);
                const canned = try std.json.parseFromValueLeaky(CannedStatus, arena, input.responses.?.object.get("status").?, .{});
                if (canned.ok) {
                    try writeStatus(ctx, canned.data.?.status, parsed.flag("--json"));
                    break :exit 0;
                }
                try output.writeError(ctx.err, canned.@"error".?.message, canned.@"error".?.action);
                break :exit 1;
            } else continue,
            .help => continue,
        };
        testing.expectEqualStrings(golden.stdout, out.written()) catch |e| {
            std.debug.print("case {f}\n", .{std.json.fmt(input.arguments, .{})});
            return e;
        };
        try testing.expectEqualStrings(golden.stderr, err.written());
        try testing.expectEqual(golden.exit, exit);
        checked += 1;
    }
    // Five status lines, the unknown verb, the 15 lines of the session verbs
    // and the stray flag of `pane run`.
    try testing.expectEqual(22, checked);
}

/// The session a golden line acts on when it names none.
const env_session = "macterm-env-session";

/// The v2 method of each ported verb, and the v1 wire command of its line.
fn methodOf(c: *const Command) ?struct { v2: []const u8, v1: []const u8 } {
    if (c == &pane_run_command) return .{ .v2 = "session.send", .v1 = "pane.run" };
    if (c == &pane_key_command) return .{ .v2 = "session.key", .v1 = "pane.key" };
    if (c == &pane_dump_command) return .{ .v2 = "session.history", .v1 = "pane.dump" };
    if (c == &pane_inspect_command) return .{ .v2 = "session.inspect", .v1 = "pane.inspect" };
    if (c == &session_list_command) return .{ .v2 = "session.list", .v1 = "session.list" };
    if (c == &session_info_command) return .{ .v2 = "session.info", .v1 = "session.info" };
    if (c == &session_kill_command) return .{ .v2 = "session.kill", .v1 = "session.kill" };
    return null;
}

fn jsonString(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// A golden line of a ported session verb: checks that the v2 request
/// carries what the v1 request carried, and prints the canned v1 response
/// with this CLI's writers. Null for a line that is not one.
fn cannedVerb(ctx: Context, parsed: command.Parsed, input: contract.Case, golden: GoldenCase) !?u8 {
    const c = parsed.command();
    const names = methodOf(c) orelse return null;
    if (input.method == null) {
        // The stray flag of `pane run`: a usage error before any request.
        if (c != &pane_run_command or input.responses != null) return null;
        try testing.expect(try runLine(ctx.arena, parsed.positionals) == .stray);
        return try run(ctx, input.arguments);
    }
    try testing.expectEqualStrings(names.v2, input.method.?);

    // The request.
    try testing.expectEqual(1, golden.requests.len);
    const req = golden.requests[0].object;
    try testing.expectEqualStrings(names.v1, req.get("command").?.string);
    const v1 = if (req.get("args")) |a| a.object else std.json.ObjectMap.empty;
    if (c == &session_info_command or c == &session_kill_command) {
        try testing.expectEqualStrings(jsonString(v1.get("session")).?, parsed.positionals[0]);
    } else if (c != &session_list_command) {
        const id = switch (paneTarget(ctx.env, parsed)) {
            .session => |name| name,
            .failed => return error.NoTarget,
        };
        try testing.expectEqualStrings(jsonString(v1.get("session")) orelse env_session, id);
    }
    if (c == &pane_run_command) {
        try testing.expectEqualStrings(jsonString(v1.get("run")).?, (try runLine(ctx.arena, parsed.positionals)).text);
        const submit = if (v1.get("submit")) |b| b.bool else true;
        try testing.expectEqual(submit, !parsed.flag("--no-submit"));
    }
    if (c == &pane_key_command) try testing.expectEqualStrings(jsonString(v1.get("key")).?, parsed.positionals[0]);
    if (c == &pane_dump_command) try testing.expectEqual(v1.get("scrollback").?.bool, parsed.flag("--scrollback"));

    // The output.
    const canned = input.responses.?.object.get(names.v1).?.object;
    const json = parsed.flag("--json");
    if (!canned.get("ok").?.bool) {
        const e = canned.get("error").?.object;
        try output.writeError(ctx.err, e.get("message").?.string, jsonString(e.get("action")));
        return 1;
    }
    const data = if (canned.get("data")) |d| d.object else std.json.ObjectMap.empty;
    if (c == &pane_dump_command) {
        try writeDump(ctx, try std.json.parseFromValueLeaky(Dump, ctx.arena, data.get("dump").?, .{}), json);
    } else if (c == &pane_inspect_command) {
        try writeInspect(ctx, try std.json.parseFromValueLeaky(Inspect, ctx.arena, data.get("inspect").?, .{}), json);
    } else if (c == &session_list_command or c == &session_info_command) {
        const rows = try std.json.parseFromValueLeaky([]const SessionRow, ctx.arena, data.get("sessions").?, .{});
        try writeSessions(ctx, rows, true, json);
    } else if (json) try output.writeJson(ctx.arena, ctx.out, .{ .object = .empty });
    return 0;
}

test "status with no server exits 2 and names the socket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
    try testing.expectEqual(2, try run(ctx, &.{ "status", "--socket", "/nonexistent/.server" }));
    try testing.expectEqualStrings("", out.written());
    try testing.expectEqualStrings("macterm: could not reach the Macterm server:\n  /nonexistent/.server: no socket file\n", err.written());
}

// ── Tests: status against a stand-in server ─────────────────────────────────

const lib_posix = @import("../posix.zig");
const socket = @import("../socket.zig");
const frame = @import("../protocol/frame.zig");
const msgpack = @import("../protocol/msgpack.zig");
const build_options = @import("build_options");

/// A server on a real socket that answers one connection, on a thread of
/// its own. It records the method of the request that it got.
const Stub = struct {
    listen_fd: i32,
    build: []const u8,
    reply: enum { ok, err, garbage },
    /// The encoded result of an `ok` reply. The default is an empty map.
    result: []const u8 = &.{0x80},
    err_code: []const u8 = "unavailable",
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    method: []const u8 = "",
    /// The encoded arguments of the request.
    args: []const u8 = &.{0x80},

    fn serve(s: *Stub) void {
        const a = s.arena.allocator();
        var fds = [_]lib_posix.pollfd{.{ .fd = s.listen_fd, .events = lib_posix.POLL.IN, .revents = 0 }};
        _ = lib_posix.poll(&fds, 5000) catch return;
        const fd = std.c.accept(s.listen_fd, null, null);
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        if (s.reply == .garbage) {
            writeAll(fd, "this is not a frame");
            return drain(fd);
        }
        sendMessage(a, fd, m.Hello{ .level = m.level, .min_level = m.min_level, .build = s.build, .role = .server, .epoch = 1, .caps = &.{} });
        _ = readMessage(a, fd) orelse return; // the CLI's hello
        const body = readMessage(a, fd) orelse return;
        const req = switch (m.decodeControl(a, body) catch return) {
            .request => |r| r,
            else => return,
        };
        s.method = req.m;
        if (req.a) |args| s.args = args.bytes;
        switch (s.reply) {
            .ok => sendMessage(a, fd, struct { re: u64, ok: msgpack.Raw }{ .re = req.id, .ok = .{ .bytes = s.result } }),
            .err => sendMessage(a, fd, struct { re: u64, err: m.ErrorInfo }{ .re = req.id, .err = .{ .code = s.err_code, .message = "the stand-in refused" } }),
            .garbage => unreachable,
        }
        drain(fd);
    }

    fn sendMessage(a: std.mem.Allocator, fd: i32, value: anytype) void {
        const body = msgpack.encodeAlloc(a, value) catch return;
        var header: [frame.header_len]u8 = undefined;
        frame.writeHeader(&header, frame.control_channel, .msg, body.len) catch return;
        writeAll(fd, &header);
        writeAll(fd, body);
    }

    fn writeAll(fd: i32, data: []const u8) void {
        var rest = data;
        while (rest.len > 0) {
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n <= 0) return;
            rest = rest[@intCast(n)..];
        }
    }

    /// The body of the next frame, or null at the end of the stream.
    fn readMessage(a: std.mem.Allocator, fd: i32) ?[]const u8 {
        var header: [frame.header_len]u8 = undefined;
        if (!readExact(fd, &header)) return null;
        const len = std.mem.readInt(u32, header[0..4], .little);
        const body = a.alloc(u8, len) catch return null;
        if (!readExact(fd, body)) return null;
        return body;
    }

    fn readExact(fd: i32, buf: []u8) bool {
        var got: usize = 0;
        while (got < buf.len) {
            var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            const ready = lib_posix.poll(&fds, 5000) catch return false;
            if (ready == 0) return false;
            const n = std.c.read(fd, buf[got..].ptr, buf.len - got);
            if (n <= 0) return false;
            got += @intCast(n);
        }
        return true;
    }

    /// Waits until the CLI closes the connection.
    fn drain(fd: i32) void {
        var buf: [256]u8 = undefined;
        while (true) {
            var fds = [_]lib_posix.pollfd{.{ .fd = fd, .events = lib_posix.POLL.IN, .revents = 0 }};
            const ready = lib_posix.poll(&fds, 5000) catch return;
            if (ready == 0 or std.c.read(fd, &buf, buf.len) <= 0) return;
        }
    }
};

const StubRun = struct { exit: u8, out: []const u8, err: []const u8, method: []const u8, args: []const u8, path: []const u8 };

fn runAgainstStub(arena: std.mem.Allocator, build: []const u8, reply: @FieldType(Stub, "reply"), json: bool) !StubRun {
    const words: []const []const u8 = if (json) &.{ "status", "--json" } else &.{"status"};
    return runStub(arena, .{ .listen_fd = -1, .build = build, .reply = reply }, words, &.{});
}

/// Runs `words` with `--socket <stand-in>` against a stand-in that answers as
/// `init` says, with `env` as the environment.
fn runStub(arena: std.mem.Allocator, init: Stub, words: []const []const u8, env_pairs: []const [2][]const u8) !StubRun {
    return runStubWith(arena, init, words, env_pairs, null);
}

/// `runStub` with `in` as stdin and no environment.
fn runStubIn(arena: std.mem.Allocator, init: Stub, words: []const []const u8, in: *std.Io.Reader) !StubRun {
    return runStubWith(arena, init, words, &.{}, in);
}

fn runStubWith(arena: std.mem.Allocator, init: Stub, words: []const []const u8, env_pairs: []const [2][]const u8, in: ?*std.Io.Reader) !StubRun {
    // Short: a socket path has at most 103 bytes on macOS.
    const path = try std.fmt.allocPrint(arena, "/tmp/macterm-cli-test-{d}.sock", .{std.c.getpid()});
    const path_z = try arena.dupeSentinel(u8, path, 0);
    _ = std.c.unlink(path_z);
    const listen_fd = try socket.createSocket(path);
    defer {
        lib_posix.close(listen_fd);
        _ = std.c.unlink(path_z);
    }
    var stub = init;
    stub.listen_fd = listen_fd;
    stub.arena = .init(std.heap.page_allocator);
    defer stub.arena.deinit();
    const thread = try std.Thread.spawn(.{}, Stub.serve, .{&stub});

    var env: std.process.Environ.Map = .init(arena);
    for (env_pairs) |pair| try env.put(pair[0], pair[1]);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer, .in = in };
    // Before a `--`, after which every word is typed.
    const at = for (words, 0..) |w, i| {
        if (std.mem.eql(u8, w, "--")) break i;
    } else words.len;
    const exit = try run(ctx, try std.mem.concat(arena, []const u8, &.{ words[0..at], &.{ "--socket", path }, words[at..] }));
    thread.join();
    return .{ .exit = exit, .out = out.written(), .err = err.written(), .method = try arena.dupe(u8, stub.method), .args = try arena.dupe(u8, stub.args), .path = path };
}

test "status sends ping and prints the server's build and the pid of its socket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The stand-in runs in this process, so its pid is ours.
    const r = try runAgainstStub(arena, build_options.version, .ok, false);
    try testing.expectEqual(0, r.exit);
    try testing.expectEqualStrings("ping", r.method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "Macterm {s} (pid {d})\n", .{ build_options.version, std.c.getpid() }), r.out);
    try testing.expectEqualStrings("", r.err);

    const j = try runAgainstStub(arena, build_options.version, .ok, true);
    try testing.expectEqual(0, j.exit);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{{\n  \"status\" : {{\n    \"pid\" : {d},\n    \"version\" : \"{s}\"\n  }}\n}}\n", .{ std.c.getpid(), build_options.version }), j.out);
}

test "status prints the server's error and exits 1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const r = try runAgainstStub(arena_state.allocator(), build_options.version, .err, false);
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings("", r.out);
    try testing.expectEqualStrings("macterm: the stand-in refused\n", r.err);
}

test "status refuses a server of another build and exits 1" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try runAgainstStub(arena, "0.0.0+other", .ok, false);
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings("", r.method);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "macterm: the server at {s} runs build 0.0.0+other, and this CLI is build {s}\n", .{ r.path, build_options.version }), r.err);
}

test "status exits 1 for a program that does not speak the protocol" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try runAgainstStub(arena, build_options.version, .garbage, false);
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "macterm: the program at {s} does not speak the protocol of the Macterm server\n", .{r.path}), r.err);
}

test "status exits 2 for a path that is not a socket" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = try std.fmt.allocPrint(arena, "/tmp/macterm-cli-test-{d}.file", .{std.c.getpid()});
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path_z);
    var env: std.process.Environ.Map = .init(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
    try testing.expectEqual(2, try run(ctx, &.{ "status", "--socket", path }));
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "macterm: could not reach the Macterm server:\n  {s}: not a socket\n", .{path}), err.written());
}

// ── Tests: the session verbs against a stand-in server ─────────────────────

fn okStub(arena: std.mem.Allocator, comptime M: type, result: M.Result) !Stub {
    return .{ .listen_fd = -1, .build = build_options.version, .reply = .ok, .result = try msgpack.encodeAlloc(arena, result) };
}

fn decodedArgs(arena: std.mem.Allocator, comptime M: type, r: StubRun) !M.Args {
    try testing.expectEqualStrings(M.name, r.method);
    return msgpack.decodeSlice(M.Args, arena, r.args);
}

test "pane run sends session.send to --session, or to MACTERM_SESSION" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const stub = try okStub(a, m.SessionSend, .{});

    const r = try runStub(a, stub, &.{ "pane", "run", "--session", "macterm-x", "ls" }, &.{});
    try testing.expectEqual(0, r.exit);
    try testing.expectEqualStrings("", r.out);
    const args = try decodedArgs(a, m.SessionSend, r);
    try testing.expectEqualStrings("macterm-x", args.id);
    try testing.expectEqualStrings("ls", args.text.bytes);
    try testing.expect(args.submit);

    // Only the words after `--` are typed as they are, dashes too.
    const n = try runStub(a, stub, &.{ "pane", "run", "--no-submit", "--", "git", "commit", "-h" }, &.{.{ "MACTERM_SESSION", "macterm-env" }});
    try testing.expectEqual(0, n.exit);
    const nargs = try decodedArgs(a, m.SessionSend, n);
    try testing.expectEqualStrings("macterm-env", nargs.id);
    try testing.expectEqualStrings("git commit -h", nargs.text.bytes);
    try testing.expect(!nargs.submit);

    const j = try runStub(a, stub, &.{ "pane", "run", "--json", "--session", "macterm-x", "ls" }, &.{});
    try testing.expectEqualStrings("{\n\n}\n", j.out);
}

/// Runs a line that fails before it connects.
fn runOffline(arena: std.mem.Allocator, words: []const []const u8, env_pairs: []const [2][]const u8) !StubRun {
    var env: std.process.Environ.Map = .init(arena);
    for (env_pairs) |pair| try env.put(pair[0], pair[1]);
    var out: std.Io.Writer.Allocating = .init(arena);
    var err: std.Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .arena = arena, .env = &env, .out = &out.writer, .err = &err.writer };
    const exit = try run(ctx, words);
    return .{ .exit = exit, .out = out.written(), .err = err.written(), .method = "", .args = "", .path = "" };
}

test "pane run types nothing for a stray flag, an empty line or no pane" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const stray = try runOffline(a, &.{ "pane", "run", "--session", "it's", "ls", "-la" }, &.{});
    try testing.expectEqual(64, stray.exit);
    try testing.expect(std.mem.indexOf(u8, stray.err, "  macterm pane run --session 'it'\\''s' -- ls -la\n") != null);
    const empty = try runOffline(a, &.{ "pane", "run", "--session", "x", "--" }, &.{});
    try testing.expectEqual(1, empty.exit);
    try testing.expectEqualStrings("macterm: nothing to run\n", empty.err);
    const none = try runOffline(a, &.{ "pane", "run", "ls" }, &.{});
    try testing.expectEqual(1, none.exit);
    try testing.expectEqualStrings("macterm: no pane to act on: use --session <name>, or run the command in a Macterm pane\n  hint: run `macterm session list` to see live sessions\n", none.err);
    // A tab or a pane names another pane than this one: MACTERM_SESSION does not count.
    const tab = try runOffline(a, &.{ "pane", "run", "--tab", "2", "ls" }, &.{.{ "MACTERM_SESSION", "macterm-env" }});
    try testing.expectEqual(1, tab.exit);
    try testing.expect(std.mem.startsWith(u8, tab.err, "macterm: --project, --tab and --pane are not available"));
}

test "pane key sends the chord, and refuses one that does not parse" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try runStub(a, try okStub(a, m.SessionKey, .{}), &.{ "pane", "key", "ctrl+c", "--session", "macterm-x" }, &.{});
    try testing.expectEqual(0, r.exit);
    const args = try decodedArgs(a, m.SessionKey, r);
    try testing.expectEqualStrings("macterm-x", args.id);
    try testing.expectEqualStrings("ctrl+c", args.chord);

    const bad = try runOffline(a, &.{ "pane", "key", "hyper+q", "--session", "macterm-x" }, &.{});
    try testing.expectEqual(1, bad.exit);
    try testing.expectEqualStrings("macterm: unrecognized key combination 'hyper+q'\n  hint: use a name such as ctrl+c, escape, up or ctrl+\\ (see `macterm pane key --help`)\n", bad.err);
}

test "pane dump prints the session's text with one newline at the end" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try runStub(a, try okStub(a, m.SessionHistory, .{ .text = .{ .bytes = "$ ls\nREADME.md\n$" } }), &.{ "pane", "dump", "--scrollback", "--session", "macterm-x" }, &.{});
    try testing.expectEqual(0, r.exit);
    try testing.expectEqualStrings("$ ls\nREADME.md\n$\n", r.out);
    const args = try decodedArgs(a, m.SessionHistory, r);
    try testing.expect(args.scrollback);

    const cut = try runStub(a, try okStub(a, m.SessionHistory, .{ .text = .{ .bytes = "end\n" }, .truncated = true }), &.{ "pane", "dump", "--json", "--session", "macterm-x" }, &.{});
    try testing.expectEqualStrings("{\n  \"dump\" : {\n    \"bytes\" : 4,\n    \"scrollback\" : false,\n    \"session\" : \"macterm-x\",\n    \"text\" : \"end\\n\"\n  }\n}\n", cut.out);
    try testing.expectEqualStrings("macterm: the text is longer than one reply holds: this is its last 0 KiB\n", cut.err);
}

test "pane inspect prints the session's state and - for the GUI's fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const argv = [_]msgpack.Bin{ .{ .bytes = "vim" }, .{ .bytes = "a.txt" } };
    const state: m.TerminalState = .{ .cols = 120, .rows = 40, .scrollback_total = 500, .scrollback_offset = 460, .scrollback_len = 40, .alt_screen = false, .foreground_pid = 901, .foreground_argv = &argv, .busy = true };
    const r = try runStub(a, try okStub(a, m.SessionInspect, .{ .terminal = state }), &.{ "pane", "inspect", "--session", "macterm-x" }, &.{});
    try testing.expectEqual(0, r.exit);
    try testing.expectEqualStrings(
        \\session             macterm-x
        \\grid                120×40
        \\cell px             -
        \\surface px          -
        \\scrollback          500 total, 460 offset, 40 len
        \\alt-screen          false
        \\content scale       -
        \\foreground          901 (vim a.txt)
        \\process exited      false
        \\needs confirm quit  true
        \\read-only           -
        \\
    , r.out);
    try testing.expectEqualStrings("macterm-x", (try decodedArgs(a, m.SessionInspect, r)).id);
}

test "session list prints running sessions, with - where the pane is not known" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const sessions = [_]m.Session{
        .{ .id = "macterm-api-1", .state = .running, .build = "b", .level = 3, .pid = 10, .shell_pid = 777, .clients = 1 },
        .{ .id = "macterm-old-2", .state = .exited, .build = "b", .level = 3 },
        .{ .id = "macterm-new-3", .state = .running, .build = "b", .level = 3 },
    };
    const r = try runStub(a, try okStub(a, m.SessionList, .{ .sessions = &sessions }), &.{ "session", "list" }, &.{});
    try testing.expectEqual(0, r.exit);
    try testing.expectEqualStrings("macterm-api-1  clients:1  pid:777  -\nmacterm-new-3  clients:?  pid:-    -\n", r.out);
    // `session` alone runs `list`.
    const alone = try runStub(a, try okStub(a, m.SessionList, .{ .sessions = &sessions }), &.{ "session", "--json" }, &.{});
    try testing.expectEqualStrings("session.list", alone.method);
    try testing.expect(std.mem.startsWith(u8, alone.out, "{\n  \"sessions\" : [\n    {\n      \"clients\" : 1,\n      \"leaderPID\" : 777,\n"));
}

test "session info and kill name a missing session as v1 did" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const missing: Stub = .{ .listen_fd = -1, .build = build_options.version, .reply = .err, .err_code = "not_found" };
    const info = try runStub(a, missing, &.{ "session", "info", "macterm-gone" }, &.{});
    try testing.expectEqual(1, info.exit);
    try testing.expectEqualStrings("macterm: no zmx session named \"macterm-gone\"\n  hint: run `macterm session list` to see live sessions\n", info.err);
    try testing.expectEqualStrings("macterm-gone", (try decodedArgs(a, m.SessionInfo, info)).id);

    const kill = try runStub(a, try okStub(a, m.SessionKill, .{}), &.{ "session", "kill", "macterm-x", "--json" }, &.{});
    try testing.expectEqual(0, kill.exit);
    try testing.expectEqualStrings("{\n\n}\n", kill.out);
    try testing.expectEqualStrings("macterm-x", (try decodedArgs(a, m.SessionKill, kill)).id);

    // A session whose shell exited is not live, as v1 listed none.
    const exited = try runStub(a, try okStub(a, m.SessionInfo, .{ .session = .{ .id = "macterm-x", .state = .exited, .build = "b", .level = 3 } }), &.{ "session", "info", "macterm-x" }, &.{});
    try testing.expectEqual(1, exited.exit);
}

// ── Tests: skills ───────────────────────────────────────────────────────────

test "skills prints the catalog, one skill, the list and JSON with no server" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try runOffline(arena, &.{ "skills", "macterm-panes" }, &.{});
    try testing.expectEqual(0, one.exit);
    try testing.expectEqualStrings(skills.all[0].text, one.out);

    var catalog: std.Io.Writer.Allocating = .init(arena);
    try skills.writeCatalog(&catalog.writer);
    try testing.expectEqualStrings(catalog.written(), (try runOffline(arena, &.{"skills"}, &.{})).out);
    var list: std.Io.Writer.Allocating = .init(arena);
    try skills.writeList(&list.writer);
    try testing.expectEqualStrings(list.written(), (try runOffline(arena, &.{ "skills", "--list" }, &.{})).out);

    const Payload = struct { skills: []const struct { name: []const u8, description: []const u8, path: []const u8, text: ?[]const u8 = null } };
    const full = try std.json.parseFromSliceLeaky(Payload, arena, (try runOffline(arena, &.{ "skills", "--json" }, &.{})).out, .{});
    try testing.expectEqual(skills.all.len, full.skills.len);
    for (skills.all, full.skills) |s, j| {
        try testing.expectEqualStrings(s.name, j.name);
        try testing.expectEqualStrings(s.description, j.description);
        try testing.expectEqualStrings(s.path, j.path);
        try testing.expectEqualStrings(s.text, j.text.?);
    }
    // `--list` leaves the text out. The slash is escaped, as `JSONEncoder` does.
    const listed = try runOffline(arena, &.{ "skills", "--list", "--json" }, &.{});
    try testing.expect(std.mem.indexOf(u8, listed.out, "\"text\"") == null);
    try testing.expect(std.mem.indexOf(u8, listed.out, "\"path\" : \"macterm-palettes\\/SKILL.md\"") != null);
    try testing.expectEqual(skills.all.len, (try std.json.parseFromSliceLeaky(Payload, arena, listed.out, .{})).skills.len);

    // stdout only on success; the error and its hint go to stderr.
    const unknown = try runOffline(arena, &.{ "skills", "nope" }, &.{});
    try testing.expectEqual(1, unknown.exit);
    try testing.expectEqualStrings("", unknown.out);
    try testing.expectEqualStrings("macterm: no skill named \"nope\"\n  hint: run `macterm skills --list` for their names\n", unknown.err);
    const both = try runOffline(arena, &.{ "skills", "--list", "macterm-panes" }, &.{});
    try testing.expectEqual(1, both.exit);
    try testing.expectEqualStrings("", both.out);
    try testing.expectEqualStrings("macterm: pass a skill name or --list, not both\n", both.err);
}

// ── Tests: api ──────────────────────────────────────────────────────────────

test "api list and describe need no server" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const list = try runOffline(a, &.{ "api", "list" }, &.{});
    try testing.expectEqual(0, list.exit);
    try testing.expect(std.mem.indexOf(u8, list.out, "session.send ") != null);
    try testing.expectEqual(api.methods.len, std.mem.count(u8, list.out, "\n"));
    const json = try runOffline(a, &.{ "api", "list", "--json" }, &.{});
    const Payload = struct { methods: []const struct { name: []const u8, since: u32, doc: []const u8 } };
    try testing.expectEqual(api.methods.len, (try std.json.parseFromSliceLeaky(Payload, a, json.out, .{})).methods.len);

    const d = try runOffline(a, &.{ "api", "describe", "session.history" }, &.{});
    try testing.expectEqual(0, d.exit);
    const described = try std.json.parseFromSliceLeaky(std.json.Value, a, d.out, .{});
    try testing.expectEqualStrings("session.history", described.object.get("name").?.string);

    const unknown = try runOffline(a, &.{ "api", "describe", "session.nope" }, &.{});
    try testing.expectEqual(1, unknown.exit);
    try testing.expectEqualStrings("macterm: no method named \"session.nope\"\n  hint: run `macterm api list` for their names\n", unknown.err);
}

test "api call sends the method with the JSON args and prints the result" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const stub = try okStub(a, m.SessionHistory, .{ .text = .{ .bytes = "$ ls" } });
    const r = try runStub(a, stub, &.{ "api", "call", "session.history", "--args", "{\"id\": \"macterm-x\", \"scrollback\": true}" }, &.{});
    try testing.expectEqual(0, r.exit);
    const args = try decodedArgs(a, m.SessionHistory, r);
    try testing.expectEqualStrings("macterm-x", args.id);
    try testing.expect(args.scrollback);
    try testing.expectEqualStrings("{\n  \"text\" : \"$ ls\",\n  \"truncated\" : false\n}\n", r.out);

    // No --args is {}.
    const ping = try runStub(a, try okStub(a, m.Ping, .{}), &.{ "api", "call", "ping" }, &.{});
    try testing.expectEqual(0, ping.exit);
    try testing.expectEqualStrings("ping", ping.method);
    try testing.expectEqualStrings("{\n\n}\n", ping.out);

    // --args - reads stdin.
    var in: std.Io.Reader = .fixed("{\"id\": \"macterm-in\"}");
    const piped = try runStubIn(a, try okStub(a, m.SessionKill, .{}), &.{ "api", "call", "session.kill", "--args", "-" }, &in);
    try testing.expectEqual(0, piped.exit);
    try testing.expectEqualStrings("macterm-in", (try decodedArgs(a, m.SessionKill, piped)).id);
}

test "api call refuses bad args before it connects, and prints the server's error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = try runOffline(a, &.{ "api", "call", "session.send", "--args", "{\"id\": \"x\"}" }, &.{});
    try testing.expectEqual(1, bad.exit);
    try testing.expectEqualStrings("macterm: args.text: expected a value: the key is required\n  hint: run `macterm api describe session.send` for the arguments\n", bad.err);
    const typo = try runOffline(a, &.{ "api", "call", "session.kill", "--args", "{\"id\": \"x\", \"force\": true}" }, &.{});
    try testing.expectEqualStrings("macterm: args.force: not a key of this type\n  hint: run `macterm api describe session.kill` for the arguments\n", typo.err);
    const not_json = try runOffline(a, &.{ "api", "call", "ping", "--args", "{" }, &.{});
    try testing.expectEqual(1, not_json.exit);
    try testing.expect(std.mem.startsWith(u8, not_json.err, "macterm: the arguments are not JSON\n"));

    const missing: Stub = .{ .listen_fd = -1, .build = build_options.version, .reply = .err, .err_code = "not_found" };
    const r = try runStub(a, missing, &.{ "api", "call", "session.info", "--args", "{\"id\": \"macterm-gone\"}" }, &.{});
    try testing.expectEqual(1, r.exit);
    try testing.expectEqualStrings("", r.out);
    try testing.expectEqualStrings("macterm: the stand-in refused (not_found)\n", r.err);
}
