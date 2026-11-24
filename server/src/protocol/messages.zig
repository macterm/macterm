//! The messages on channel 0 (design/003 §2, §4; design/006 §2).
//!
//! Each message type is a Zig struct, and this file is the one source of the
//! schema: the Swift side and the metadata are made from it (issue 0045).
//! Each type declares:
//!
//! - `name`: the method or message name on the wire;
//! - `since`: the protocol level that added it;
//! - `senders`: the trust levels of the connections that may send it;
//! - `doc`, for a method that a local client may send: one sentence that
//!   `macterm api` shows (design/011 §4).
//!
//! A struct may also declare, for its fields:
//!
//! - `field_doc`: one sentence for each field, for people. `macterm api
//!   describe` shows it as `description`. A `///` comment on a field says
//!   only what a reader of the code needs in addition.
//! - `field_limits`: the limits that the server checks, as JSON Schema
//!   keywords: `.{ .text = .{ .max_length = send_max } }`. The server
//!   still checks each one itself; this only tells a client.
//!
//! A field added to a type of an older level names its level in the type's
//! `field_since` declaration: `pub const field_since = .{ .hint = 2 };`.
//!
//! The add-only rule: never remove or rename a message or a field, and never
//! change a field's type. A new field is optional or has a default, so that
//! an older peer's message still decodes. A peer skips keys it does not know.

const std = @import("std");
const msgpack = @import("msgpack.zig");
const model = @import("../model/model.zig");

const Raw = msgpack.Raw;

/// The level that this build speaks. It counts additions to the protocol.
pub const level: u32 = 3;

/// The lowest level that this build accepts from a peer.
pub const min_level: u32 = 1;

/// What a peer says it is in `hello`. The trust of a connection never comes
/// from this field (design/006 §2).
pub const Role = enum {
    gui,
    cli,
    server,
    session,
    /// `macterm mcp`: a coding agent drives it (design/014 §5). It may send
    /// what the CLI may send, but `session.send` and `session.key` are
    /// refused while the pane reads a password.
    mcp,
    /// A role that a later build added. It decodes, so that the two builds
    /// can still refuse each other clearly.
    unknown,
};

/// How a connection came, and so what its peer may send (design/006 §2).
pub const Trust = enum {
    /// The GUI or the CLI on the local socket, with the peer uid checked.
    local,
    /// A local session process to its server.
    session,
    /// A host's server, through the app's ssh.
    remote,
};

const everyone: []const Trust = &.{ .local, .session, .remote };

// ── Handshake ───────────────────────────────────────────────────────────────

/// The first message in each direction. Its fields of level 1 are frozen for
/// ever, so that any two builds can at least refuse each other clearly. A
/// later field is optional.
pub const Hello = struct {
    pub const name = "hello";
    pub const since = 1;
    pub const senders = everyone;
    pub const field_since = .{ .build_key = 3 };

    level: u32,
    min_level: u32,
    build: []const u8,
    role: Role,
    epoch: u64,
    caps: []const []const u8,
    /// `scripts/build-server.sh` makes the key.
    build_key: ?[]const u8 = null,

    pub const field_doc = .{
        .level = "The highest protocol level that the sender speaks.",
        .min_level = "The lowest protocol level that the sender accepts.",
        .build = "The build of the sender, as text for people.",
        .role = "What the sender is: gui, cli, server or session.",
        .epoch = "A random id for each start of the sender. A new epoch tells a client that the server started again.",
        .caps = "What the build or its platform can do apart from its level (tcc, password-tty). A peer ignores a cap that it does not know.",
        .build_key = "The build key, in lowercase hex. Two builds are the same build only when their keys are equal. Null for a build with no key (a development build).",
    };
};

/// Sent in place of any other message when the peer speaks too low a level.
/// The sender then closes the connection. Its layout is frozen, as `Hello`'s.
pub const Refuse = struct {
    pub const name = "refuse";
    pub const since = 1;
    pub const senders = everyone;

    reason: []const u8,
    needs_level: u32,

    pub const field_doc = .{
        .reason = "Why the sender refuses, as a code and not text for people: level_too_low or build_mismatch.",
        .needs_level = "For level_too_low: the lowest protocol level that the sender accepts. For build_mismatch: the protocol level of the sender.",
    };
};

pub const Negotiation = union(enum) {
    /// Both sides speak this level.
    speak: u32,
    /// Send this, then close.
    refuse: Refuse,
};

/// Decides the level from our `hello` and the peer's. Each side checks only
/// its own `min_level`: if the level is under the peer's, the peer refuses.
///
/// The CLI is always the same build as its server (design/007), so a CLI on
/// either side refuses any other build (`build_mismatch`). The CLI names
/// both builds from the two hellos. `macterm mcp` is the CLI binary, so the
/// same rule holds for it.
pub fn negotiate(mine: Hello, theirs: Hello) Negotiation {
    const speak = @min(mine.level, theirs.level);
    if (speak < mine.min_level) return .{ .refuse = .{
        .reason = "level_too_low",
        .needs_level = mine.min_level,
    } };
    if ((isCli(mine.role) or isCli(theirs.role)) and !std.mem.eql(u8, mine.build, theirs.build))
        return .{ .refuse = .{ .reason = "build_mismatch", .needs_level = mine.level } };
    return .{ .speak = speak };
}

fn isCli(role: Role) bool {
    return role == .cli or role == .mcp;
}

// ── Envelopes ───────────────────────────────────────────────────────────────

/// `{id, m, a}`. The id comes from the client and is unique for its
/// connection epoch, so that a request sent again after a resume is matched
/// and not done two times.
pub const Request = struct {
    id: u64,
    m: []const u8,
    a: ?Raw = null,

    pub const field_doc = .{
        .id = "The id of the request. It is unique for the connection epoch of the client.",
        .m = "The name of the method.",
        .a = "The arguments of the method. Null for an empty argument map.",
    };
};

/// `{re, ok}` or `{re, err}`: exactly one of the two. `decodeControl`
/// refuses a response with both or neither.
pub const Response = struct {
    re: u64,
    ok: ?Raw = null,
    err: ?ErrorInfo = null,

    pub const field_doc = .{
        .re = "The id of the request that this response answers.",
        .ok = "The result of the method. Null when the request failed.",
        .err = "The error. Null when the request worked.",
    };
};

pub const ErrorInfo = struct {
    code: []const u8,
    message: []const u8,
    level: ?u32 = null,

    pub const field_doc = .{
        .code = "The error code: one of error_codes. A receiver reads a code that it does not know as an error with no special handling.",
        .message = "The error, as text for people.",
        .level = "The protocol level that the request needs, when the peer speaks a lower one.",
    };
};

/// The codes of `ErrorInfo.code`. The add-only rule holds: never remove or
/// rename a code.
pub const ErrorCode = enum {
    busy,
    exited,
    forbidden,
    invalid_args,
    not_found,
    refused,
    start_failed,
    starting,
    timeout,
    unavailable,
    unknown_method,
    /// A request that makes an object names an id that the model has
    /// (design/010 §3).
    duplicate_id,
    /// The server could not read `model.json`, or the file is of a newer
    /// build: it changes no model and writes no file (design/010 §2).
    model_readonly,
};

pub const Event = struct {
    e: []const u8,
    a: ?Raw = null,

    pub const field_doc = .{
        .e = "The name of the event.",
        .a = "The fields of the event. Null when the event has none.",
    };
};

/// One consistent state: the receiver applies all of its events at once.
pub const EventBatch = struct {
    pub const field_since = .{ .cause = 3 };

    seq: u64,
    ev: []const Event,
    /// design/010 §3.
    cause: ?u64 = null,

    pub const field_doc = .{
        .seq = "The number of the batch in the epoch of the server.",
        .ev = "The events of the batch. The receiver applies them all at once.",
        .cause = "The id of the request that caused the batch, only on the connection that sent the request. Null on every other connection, and in a batch that control.resume sends again.",
    };
};

// ── Methods ─────────────────────────────────────────────────────────────────

/// A client that lost its link asks for the event batches that it missed
/// (design/003 §7). With the same `epoch` as the server's `hello` and all the
/// batches after `seq` still in the server's ring, the server sends them (as
/// events, before the reply) and `replayed` is true. Otherwise `replayed` is
/// false: the server restarted, or the ring lost a batch, and the client reads
/// the full state (`session.list`). `seq` is the count of batches now.
pub const ControlResume = struct {
    pub const name = "control.resume";
    pub const doc = "Asks for the event batches that this client missed after a lost link.";
    pub const since = 2;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .epoch = "The epoch of the state that the lost connection read.",
            .seq = "The count of event batches that the client read in that epoch.",
            .client = "The client key that state.subscribe gave the lost connection.",
        };

        pub const field_since = .{ .client = 3 };

        epoch: u64,
        seq: u64,
        /// The `client` that `state.subscribe` gave the lost connection.
        /// With the same epoch, this connection takes it, so that a model
        /// request sent again gets its first reply. A client that sends
        /// it keeps the request ids of the lost connection, and counts on
        /// from them.
        client: ?u64 = null,
    };
    pub const Result = struct {
        pub const field_doc = .{
            .replayed = "True: the missed batches came as events before this reply. False: the client must read the full state again.",
            .seq = "The count of event batches now.",
        };

        replayed: bool,
        seq: u64,
    };
};

/// Opens a channel for a session's pane (design/003 §1).
pub const ChannelOpen = struct {
    pub const name = "channel.open";
    pub const doc = "Opens a channel for the pane of a session.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .session = "The id of the session." };

        session: []const u8,
    };
    pub const Result = struct {
        pub const field_doc = .{
            .channel = "The number of the new channel.",
            .epoch = "The epoch of the hello of the session. Null from a session of an older build.",
            .caps = "The caps of the hello of the session (notification, tty-read). Null from a server of an older build.",
        };

        channel: u32,
        /// The `epoch` of the session's `hello`. A client keeps it with its
        /// output offset, and its next `Attach` on a new channel asks to
        /// resume with both (design/003 §7).
        epoch: ?u64 = null,
        /// The `caps` of the session's `hello`. A session keeps the build
        /// that started it, so a client reads here what the session sends:
        /// a relayed channel never sees the session's `hello`.
        caps: ?[]const []const u8 = null,

        pub const field_since = .{ .epoch = 3, .caps = 3 };
    };
};

pub const ChannelClose = struct {
    pub const name = "channel.close";
    pub const doc = "Closes a channel.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .channel = "The number of the channel." };

        channel: u32,
    };
    pub const Result = struct {};
};

/// Stops a channel's pane output, for a pane that no one sees. The session's
/// messages on the channel (its exit, its state) still come (design/003 §6).
pub const ChannelPause = struct {
    pub const name = "channel.pause";
    pub const doc = "Stops the pane output of a channel. The messages of the session still come.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .channel = "The number of the channel." };

        channel: u32,
    };
    pub const Result = struct {};
};

/// Starts a paused channel's output again. A snapshot of the screen comes
/// first on the channel.
pub const ChannelResume = struct {
    pub const name = "channel.resume";
    pub const doc = "Starts the output of a paused channel again, after a snapshot of the screen.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .channel = "The number of the channel." };

        channel: u32,
    };
    pub const Result = struct {};
};

/// Tells a client that the link is up. Any frame does the same; this one gets
/// an answer when nothing else moves (design/005, "Reconnect").
pub const Ping = struct {
    pub const name = "ping";
    pub const doc = "Answers when the server is up.";
    pub const since = 1;
    pub const senders = everyone;

    pub const Args = struct {};
    pub const Result = struct {};
};

/// What the server knows of one session (design/001). The session process
/// holds all of it, so a new server reads it again from each session.
pub const Session = struct {
    pub const field_doc = .{
        .id = "The name of the session: the file name of its socket. The client that asked for the session made it.",
        .state = "The state of the session.",
        .build = "The build of the session, from its hello.",
        .level = "The protocol level of the session, from its hello.",
        .build_key = "The build key of the session, from its hello. Null when the session did not say.",
        .pid = "The session process. Null when state is refused.",
        .shell_pid = "The shell, or the command, of the session.",
        .pty = "The path of the slave side of the pty.",
        .cols = "The width of the terminal in cells.",
        .rows = "The height of the terminal in cells.",
        .code = "The exit code, when state is exited and the shell exited.",
        .signal = "The signal number, when state is exited and a signal ended the shell.",
        .clients = "The count of clients that show the session. Null when the session did not say.",
        .unseen = "The pane has output that no one saw.",
        .failed = "The last command of the pane failed.",
        .bell = "The pane rang the bell.",
    };
    pub const field_since = .{ .build_key = 3 };

    id: []const u8,
    state: SessionState,
    build: []const u8,
    level: u32,
    build_key: ?[]const u8 = null,
    pid: ?i64 = null,
    shell_pid: ?i64 = null,
    pty: ?msgpack.Bin = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    code: ?u8 = null,
    signal: ?u8 = null,
    /// The clients that sent `attach`.
    clients: ?u16 = null,
    /// The flags of the session's `attention` message. All false for a
    /// pane that has nothing to show.
    unseen: bool = false,
    failed: bool = false,
    bell: bool = false,
};

pub const SessionState = enum {
    running,
    /// The shell ended. The session keeps the status until a client reads
    /// it: the `exit` on a channel, or a `session.list` or `session.info`
    /// that shows this state. Then the server ends the session.
    exited,
    /// The session and the server have no level in common. The server
    /// cannot read its state or end it.
    refused,
    /// A state that a later build added.
    unknown,
};

/// The largest pane size, in cells. The server and a session cut a larger
/// one to it.
pub const max_cells = 1000;

/// Starts a session process (design/001). The server answers when the
/// session's socket accepts connections and the session sent its state.
pub const SessionCreate = struct {
    pub const name = "session.create";
    pub const doc = "Starts a session. The reply comes when the session accepts connections.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "Made by the client: letters, digits, '-', '_' and '.', not '.' or '-' first. A request sent again with this id starts no second session.",
            .cwd = "The folder of the session, an absolute path. Null is the home folder.",
            .command = "The command in place of a login shell.",
            .cols = std.fmt.comptimePrint("The width of the terminal in cells. The server cuts it to {d}.", .{max_cells}),
            .rows = std.fmt.comptimePrint("The height of the terminal in cells. The server cuts it to {d}.", .{max_cells}),
            .env = "The environment of the session, as NAME=value entries, in place of the environment of the server.",
            .replace_exited = "True: a session of this id whose shell exited ends, and a new one starts after the old one is gone. False: the request then fails with exited.",
        };

        pub const field_since = .{ .replace_exited = 3 };
        pub const field_limits = .{ .cols = .{ .minimum = 1 }, .rows = .{ .minimum = 1 } };

        /// `session.validName` checks it.
        id: []const u8,
        cwd: ?msgpack.Bin = null,
        command: ?[]const msgpack.Bin = null,
        cols: u16 = 80,
        rows: u16 = 24,
        /// The session's environment, as `NAME=value` entries, in place of
        /// the server's. The server sets its own runtime directory in it.
        /// A pane's client sends its own, so that the shell gets the
        /// environment that the terminal made for it.
        env: ?[]const msgpack.Bin = null,
        replace_exited: bool = false,
    };
    pub const Result = struct {
        pub const field_doc = .{ .session = "The new session." };

        session: Session,
    };
};

pub const SessionList = struct {
    pub const name = "session.list";
    pub const doc = "Lists the sessions of the server.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct {
        pub const field_doc = .{ .sessions = "Every session of the server." };

        sessions: []const Session,
    };
};

pub const SessionInfo = struct {
    pub const name = "session.info";
    pub const doc = "Shows one session.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The id of the session." };

        id: []const u8,
    };
    pub const Result = struct {
        pub const field_doc = .{ .session = "The session." };

        session: Session,
    };
};

/// Ends a session. A running session ends its shell (SIGHUP to the shell's
/// process group, then SIGKILL). An exited session gives its status to no
/// one more and ends. The server answers when the session process is gone.
pub const SessionKill = struct {
    pub const name = "session.kill";
    pub const doc = "Ends a session and its shell.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The id of the session." };

        id: []const u8,
    };
    pub const Result = struct {};
};

/// A client shows the pane to the user: the session clears its attention
/// flags (`Attention`). Only a local client may send it (the GUI or the CLI
/// of the same user, over the socket that checks the peer's uid, design/006
/// §2). On a host, the app's connection through ssh is `local` to that
/// host's server, so the app can send it there. It reveals nothing and
/// changes no program. A program in a pane is also a local client and can
/// clear a flag, as it can send `session.kill`. A host's server cannot send
/// it to the Mac: `remote` is not a sender. The reply goes after the session
/// sent the flags again, so every client already has the event.
pub const PaneSeen = struct {
    pub const name = "pane.seen";
    pub const doc = "Clears the attention flags of a session.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The id of the session." };

        id: []const u8,
    };
    pub const Result = struct {};
};

/// The most bytes that `session.send` types at a time.
pub const send_max = 64 * 1024;

/// Types text into a session's pty, as it is: no paste brackets, as v1's
/// `pane run` typed it (`macterm pane run`, design/011 §1). With `submit`,
/// a newline follows. The reply goes when the server gave the bytes to the
/// session. A client that may create a session may type into one, so this
/// gives no new access.
pub const SessionSend = struct {
    pub const name = "session.send";
    pub const doc = "Types text into a session as it is. With submit, a newline follows.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The id of the session.",
            .text = "The text to type. The limit is in bytes.",
            .submit = "True: a newline follows the text.",
        };
        pub const field_limits = .{ .text = .{ .max_length = send_max } };

        id: []const u8,
        text: msgpack.Bin,
        submit: bool = true,
    };
    pub const Result = struct {};
};

/// Sends one key press to a session (`macterm pane key`). The session
/// encodes the chord with the key modes of its own terminal (cursor keys,
/// the kitty flags), so a program gets what a keyboard would send it. The
/// chord grammar is that of keybinds (`chord.zig`).
pub const SessionKey = struct {
    pub const name = "session.key";
    pub const doc = "Sends one key press to a session, for example ctrl+c.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The id of the session.",
            .chord = "The key press: ctrl+c, escape, up or shift+1, for example.",
        };

        id: []const u8,
        chord: []const u8,
    };
    pub const Result = struct {};
};

/// The text of a session's terminal (`macterm pane dump`): the screen, or
/// the scrollback and the screen. It needs no client that shows the pane.
pub const SessionHistory = struct {
    pub const name = "session.history";
    pub const doc = "Gives the text of the screen of a session, or of its scrollback and screen.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The id of the session.",
            .scrollback = "True: the scrollback and the screen. False: the screen only.",
            .tail_lines = "The last lines of the text only. With no value, all the lines.",
        };
        pub const field_limits = .{ .tail_lines = .{ .minimum = 1 } };

        id: []const u8,
        scrollback: bool = false,
        tail_lines: ?u32 = null,
    };
    pub const Result = struct {
        pub const field_doc = .{
            .text = "The text of the terminal.",
            .truncated = "Only the end of the text is here, because the text was longer than a frame holds or than tail_lines.",
            .lines_cut = "The lines that tail_lines removed. Lines that the frame limit removed are not counted.",
        };

        text: msgpack.Bin,
        truncated: bool = false,
        lines_cut: u64 = 0,
    };
};

/// The longest marker of `session.wait`, in bytes.
pub const wait_text_max = 1024;
/// The longest time that `session.wait` waits.
pub const wait_max_ms = 600_000;
/// The longest line that `session.wait` gives back. A longer line keeps its
/// start.
pub const wait_line_max = 4096;
/// With no marker, `session.wait` ends when no run is in progress and the
/// pane printed nothing for this time.
pub const wait_quiet_ms = 500;

/// Waits in the session until a line of its terminal starts with a marker,
/// or, with no marker, until no run is in progress and the pane is quiet
/// (`wait_quiet_ms`). The session process waits, so a client does not poll
/// `session.history`. The reply goes when the wait ends, at the latest after
/// `timeout_ms`.
pub const SessionWait = struct {
    pub const name = "session.wait";
    pub const doc = "Waits until a line of the terminal of a session starts with a marker, or until no command runs in it.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The id of the session.",
            .text = "The marker. The wait ends when a line of the scrollback or the screen starts with it. The line of the typed command starts with the prompt, so it does not match. With no marker, the wait ends when no command runs and the pane printed nothing for 500 ms.",
            .timeout_ms = "The longest time to wait, in milliseconds.",
        };
        pub const field_limits = .{
            .text = .{ .min_length = 1, .max_length = wait_text_max },
            .timeout_ms = .{ .maximum = wait_max_ms },
        };

        id: []const u8,
        text: ?[]const u8 = null,
        timeout_ms: u32 = 30_000,
    };
    pub const Result = struct {
        pub const field_doc = .{
            .end = "Why the wait ended: matched (a line starts with the marker), done (no command runs), exited (the shell exited) or timeout.",
            .line = "With matched: the newest line that starts with the marker, cut at 4 KiB.",
        };

        end: WaitEnd,
        line: ?msgpack.Bin = null,
    };
};

pub const WaitEnd = enum {
    matched,
    done,
    exited,
    timeout,
    unknown,
};

/// The state of a session's terminal (`macterm pane inspect`).
pub const SessionInspect = struct {
    pub const name = "session.inspect";
    pub const doc = "Gives the state of the terminal of a session.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The id of the session." };

        id: []const u8,
    };
    pub const Result = struct {
        pub const field_doc = .{ .terminal = "The state of the terminal of the session." };

        terminal: TerminalState,
    };
};

/// What a session knows of its terminal. The cell and surface sizes are the
/// GUI's, and not here.
pub const TerminalState = struct {
    pub const since = 3;
    pub const field_doc = .{
        .cols = "The width of the terminal in cells.",
        .rows = "The height of the terminal in cells.",
        .scrollback_total = "The rows of the scrollback and the screen.",
        .scrollback_offset = "The row of the top of the viewport in them.",
        .scrollback_len = "The rows of the viewport.",
        .alt_screen = "The alternate screen is active.",
        .foreground_pid = "The process group that holds the pty. Null when the session cannot read it.",
        .foreground_argv = "The arguments of the leader of that group, cut at 1 KiB in all. Null when the session cannot read them.",
        .busy = "A program other than the shell holds the pty. Null when the session cannot read it.",
        .exited = "The shell exited.",
    };

    cols: u16,
    rows: u16,
    /// Ghostty's scrollbar.
    scrollback_total: u64,
    scrollback_offset: u64,
    scrollback_len: u64,
    alt_screen: bool,
    foreground_pid: ?i64 = null,
    foreground_argv: ?[]const msgpack.Bin = null,
    busy: ?bool = null,
    exited: bool = false,
};

/// The server exits and leaves every session running, so that a newer app
/// can start its own server (design/002).
pub const ServerExit = struct {
    pub const name = "server.exit";
    pub const doc = "Stops the server. The sessions continue to run.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct {};
};

/// The most stdout that `command.run` returns. The server reads and drops
/// the rest, so that the command does not stop on a full pipe.
pub const run_output_max = 512 * 1024;

/// The longest `command.run` that a client can ask for.
pub const run_timeout_max_ms = 60_000;

/// Runs a command on the server's machine to its end, and returns what it
/// wrote to stdout. It is not a session: it has no pty, stdin and stderr are
/// `/dev/null`, and it has the server's environment. The app's background
/// reads of a host use it, over the host's one connection (0058). A client
/// that may create a session may run a command in one, so this gives no new
/// access.
pub const CommandRun = struct {
    pub const name = "command.run";
    pub const doc = "Runs a command on the machine of the server to its end, and gives its stdout.";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .argv = "The program, an absolute path, then its arguments.",
            .cwd = "The folder, an absolute path. Null is the home folder.",
            .timeout_ms = "After this time, the process group of the command gets SIGKILL and the request fails with timeout.",
        };
        pub const field_limits = .{
            .argv = .{ .min_items = 1 },
            .timeout_ms = .{ .minimum = 1, .maximum = run_timeout_max_ms },
        };

        argv: []const msgpack.Bin,
        cwd: ?msgpack.Bin = null,
        timeout_ms: u32 = 5000,
    };
    pub const Result = struct {
        pub const field_doc = .{
            .output = std.fmt.comptimePrint("The stdout of the command, at most {d} bytes.", .{run_output_max}),
            .truncated = "The command wrote more than output holds. The rest is not in output.",
            .code = "The exit code, when the command exited.",
            .signal = "The signal number, when a signal ended the command.",
        };

        output: msgpack.Bin,
        truncated: bool = false,
        code: ?u8 = null,
        signal: ?u8 = null,
    };
};

/// The bytes of the secret of `link.open`: a ChaCha20-Poly1305 key.
pub const link_secret_len = 32;

/// Opens a roaming link (design/009): the server opens a UDP port and
/// answers with it. Both sides seal every packet with `secret`, which the client
/// makes and that goes only in this request, over the connection's own
/// confidentiality (ssh). The client then speaks the same frames over the
/// link, as a client of its own, and may move to a new network with no login.
/// A server with the link off, or with no free port, answers with an error
/// and the client stays on this connection.
pub const LinkOpen = struct {
    pub const name = "link.open";
    pub const doc = "Opens a roaming link on a UDP port.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .secret = "Random bytes that seal each packet. The limit is in bytes. The server keeps them in memory only.",
            .key_id = "Names the key in each packet. The client makes it, and no other link of this server has it.",
        };
        pub const field_limits = .{ .secret = .{ .min_length = link_secret_len, .max_length = link_secret_len } };

        secret: msgpack.Secret,
        key_id: u32,
    };
    pub const Result = struct {
        pub const field_doc = .{ .port = "The UDP port on the host." };

        port: u16,
    };
};

/// Ends a link that this connection opened. Its end ends all of its links
/// too.
pub const LinkClose = struct {
    pub const name = "link.close";
    pub const doc = "Ends a roaming link that this connection opened.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .key_id = "The key id of the link." };

        key_id: u32,
    };
    pub const Result = struct {};
};

// ── The model (design/010 §3) ───────────────────────────────────────────────
//
// Only the Mac server has a model (`model_ipc.zig`). A request that makes an
// object carries the object's id, which the client made. The server refuses
// an id that the model has with `duplicate_id`, and an unknown id with
// `not_found`. A request changes the model completely or not at all. Its
// events go in one batch before the reply, with the request's id in
// `EventBatch.cause` on the requester's connection.
//
// `rebalance` is on the request: null takes the `auto_tiling` of
// `model.options`.

pub const ProjectId = model.ProjectId;
pub const TabId = model.TabId;
pub const PaneId = model.PaneId;
pub const SplitId = model.SplitId;

/// The zoomed pane of a tab. The server keeps zoom in memory only.
pub const Zoom = struct {
    pub const field_doc = .{
        .tab = "The tab.",
        .pane = "The zoomed pane of the tab.",
    };

    tab: TabId,
    pane: PaneId,
};

/// A pane that left the model. The server ends a local pane's session
/// itself. A client that owns the link to `host` ends a remote one
/// (design/010 §5).
pub const RemovedPane = struct {
    pub const field_doc = .{
        .id = "The pane.",
        .session = "The id of the session of the pane.",
        .host = "The host of the session. Null for a pane of this Mac.",
    };

    id: PaneId,
    session: []const u8,
    host: ?[]const u8 = null,
};

/// The full state: the model and the sessions. A client reads it once, then
/// follows the event batches from `seq`. Every client gets every batch; this
/// request only reads.
pub const StateSubscribe = struct {
    pub const name = "state.subscribe";
    pub const doc = "Gives the full state: the model and the sessions.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct {
        pub const field_doc = .{
            .epoch = "A random id for each start of the server.",
            .seq = "The count of event batches in epoch that this state includes.",
            .model = "The model. Null on a server with no model.",
            .zoomed = "The zoomed pane of each tab that has one.",
            .readonly = "The server cannot write the model: every model request except model.options fails with model_readonly.",
            .sessions = "Every session of the server.",
            .client = "The key of this connection for the ring of request ids. A client that resumes on a new connection sends it in control.resume.",
        };

        epoch: u64,
        seq: u64,
        /// A host's server, or a server that the app did not give
        /// `MACTERM_STATE_DIR`, has no model.
        model: ?model.ModelData = null,
        zoomed: []const Zoom = &.{},
        /// The server could not read `model.json`, or the file is of a newer
        /// build.
        readonly: bool = false,
        sessions: []const Session,
        client: u64,
    };
};

pub const ProjectCreate = struct {
    pub const name = "project.create";
    pub const doc = "Makes a project with capability fields that never change.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The id of the new project. The client makes it.",
            .name = "The name of the project.",
            .path = "A local path, or user@host:dir. Can be empty.",
            .color = "The color tag of the project.",
            .parent = "The project that holds it. Null is the top level.",
            .created_at = "Unix time in milliseconds.",
            .sidebar = "Where the sidebar shows the project: tree, top, bottom or none. It never changes.",
            .single_tab = "True: the project holds at most one tab. It never changes.",
            .removable = "True: project.remove can remove the project. It never changes.",
            .alias = "One short word that finds the project: pinned, for example. It is unique, and never changes.",
        };

        id: ProjectId,
        name: []const u8,
        path: []const u8 = "",
        color: ?[]const u8 = null,
        parent: ?ProjectId = null,
        created_at: i64 = 0,
        /// The capability fields (design/010 §11). The defaults make a
        /// project of the tree. An `alias` that a project has fails with
        /// `duplicate_id`.
        sidebar: model.ProjectSidebar = .tree,
        single_tab: bool = false,
        removable: bool = true,
        alias: ?[]const u8 = null,
    };
    pub const Result = struct {};
};

/// Changes the fields that are not null. An empty `color` removes the
/// color. An empty `parent` moves the project to the top level.
pub const ProjectSet = struct {
    pub const name = "project.set";
    pub const doc = "Changes the fields of a project that are not null.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The project to change.",
            .name = "The new name.",
            .path = "The new path: a local path, or user@host:dir.",
            .color = "The new color tag. An empty string removes the color.",
            .parent = "The new parent project. An empty string moves the project to the top level.",
        };

        id: ProjectId,
        name: ?[]const u8 = null,
        path: ?[]const u8 = null,
        color: ?[]const u8 = null,
        parent: ?ProjectId = null,
    };
    pub const Result = struct {};
};

/// Sets the order of the children of `parent` (the top level when null):
/// `ids` holds each child once.
pub const ProjectReorder = struct {
    pub const name = "project.reorder";
    pub const doc = "Sets the order of the child projects of a project, or of the top level.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .parent = "The project whose children to order. Null is the top level.",
            .ids = "Each child project one time, in the new order.",
        };

        parent: ?ProjectId = null,
        ids: []const ProjectId,
    };
    pub const Result = struct {};
};

/// Removes a project and its tabs. A project that holds projects fails
/// with `invalid_args`, and a project that is not `removable` with
/// `refused`.
pub const ProjectRemove = struct {
    pub const name = "project.remove";
    pub const doc = "Removes a project that holds no projects, with its tabs.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The project to remove." };

        id: ProjectId,
    };
    pub const Result = struct {
        pub const field_doc = .{ .panes = "The panes that left the model." };

        panes: []const RemovedPane = &.{},
    };
};

/// Makes a tab. `root` is one pane, or a tree (a layout, a grid), with the
/// ids that the client made. The tab's focus is its first pane.
pub const TabCreate = struct {
    pub const name = "tab.create";
    pub const doc = "Makes a tab with one pane or a tree of panes.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .project = "The project of the new tab.",
            .id = "The id of the new tab. The client makes it.",
            .index = "The position of the tab in its project. Null puts it at the end.",
            .root = "One pane, or a tree of panes, with the ids that the client made.",
            .title = "The title of the tab.",
            .focus = "True: the tab becomes the active tab of its project.",
        };

        project: ProjectId,
        id: TabId,
        index: ?u32 = null,
        root: model.SplitNode,
        title: ?[]const u8 = null,
        focus: bool = true,
    };
    pub const Result = struct {};
};

pub const TabClose = struct {
    pub const name = "tab.close";
    pub const doc = "Closes a tab.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The tab to close." };

        id: TabId,
    };
    pub const Result = struct {
        pub const field_doc = .{ .panes = "The panes that left the model." };

        panes: []const RemovedPane = &.{},
    };
};

/// Sets the tab's title. Null removes it.
pub const TabSet = struct {
    pub const name = "tab.set";
    pub const doc = "Sets the title of a tab. Null removes it.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The tab.",
            .title = "The new title. Null removes it.",
        };

        id: TabId,
        title: ?[]const u8 = null,
    };
    pub const Result = struct {};
};

/// The active tab of a project.
pub const TabSelect = struct {
    pub const name = "tab.select";
    pub const doc = "Sets the active tab of a project.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .project = "The project of the tab.",
            .id = "The tab that becomes active.",
        };

        project: ProjectId,
        id: TabId,
    };
    pub const Result = struct {};
};

pub const TabReorder = struct {
    pub const name = "tab.reorder";
    pub const doc = "Moves a tab to a position in its project.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .project = "The project of the tab.",
            .id = "The tab to move.",
            .index = "The new position of the tab.",
        };

        project: ProjectId,
        id: TabId,
        index: u32,
    };
    pub const Result = struct {};
};

/// Moves a tab to another project (Pinned and Scratch Tabs included) and
/// makes it the active tab there. No session moves.
pub const TabMove = struct {
    pub const name = "tab.move";
    pub const doc = "Moves a tab to another project and makes it the active tab there.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The tab to move.",
            .to_project = "The project that gets the tab.",
            .index = "The position of the tab there. Null puts it at the end.",
        };

        id: TabId,
        to_project: ProjectId,
        index: ?u32 = null,
    };
    pub const Result = struct {};
};

/// Puts the tree of tab `src` into tab `dst`, next to `target_pane` on
/// `zone`, or at the edge of the tab when `target_pane` is null. `src`
/// closes; no pane leaves the model.
pub const TabMerge = struct {
    pub const name = "tab.merge";
    pub const doc = "Puts the panes of one tab into another tab, and closes the first tab.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .src = "The tab whose panes move. It closes.",
            .dst = "The tab that gets the panes.",
            .target_pane = "The pane of dst next to which the panes go. Null is the edge of the tab.",
            .zone = "The side of the target where the panes go.",
            .split_id = "The id of the new split. The client makes it.",
            .rebalance = "True: every ratio of the tab is even after the change. Null takes auto_tiling of model.options.",
        };

        src: TabId,
        dst: TabId,
        target_pane: ?PaneId = null,
        zone: model.tree.Zone,
        split_id: SplitId,
        rebalance: ?bool = null,
    };
    pub const Result = struct {};
};

/// The direction of a new split. `auto` splits along the longer side of
/// the target's session (its `cols` and `rows`, a cell twice as high as it
/// is wide), and side by side when the server does not know the size.
pub const SplitDir = enum {
    horizontal,
    vertical,
    auto,
    unknown,
};

pub const PaneSplit = struct {
    pub const name = "pane.split";
    pub const doc = "Splits a pane and puts a new pane next to it.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .tab = "The tab of the pane.",
            .target = "The pane to split.",
            .new = "The new pane, with the id that the client made.",
            .split_id = "The id of the new split. The client makes it.",
            .dir = "The direction of the split. Auto splits along the longer side of the target.",
            .position = "The side of the split that the new pane takes.",
            .ratio = std.fmt.comptimePrint("The ratio of the first side, from {d} to {d}. Null is 0.5.", .{ model.tree.min_ratio, model.tree.max_ratio }),
            .focus = "True: the new pane gets the focus, and a zoom ends.",
            .rebalance = "True: every ratio of the tab is even after the change. Null takes auto_tiling of model.options.",
        };

        tab: TabId,
        target: PaneId,
        new: model.Pane,
        split_id: SplitId,
        dir: SplitDir,
        position: model.tree.Position = .second,
        ratio: ?f64 = null,
        focus: bool = true,
        rebalance: ?bool = null,
    };
    pub const Result = struct {};
};

/// Closes a pane. The last pane of a tab closes the tab. The next focus
/// comes from the tab's history.
pub const PaneClose = struct {
    pub const name = "pane.close";
    pub const doc = "Closes a pane. The last pane of a tab closes the tab.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The pane to close.",
            .rebalance = "True: every ratio of the tab is even after the change. Null takes auto_tiling of model.options.",
        };

        id: PaneId,
        rebalance: ?bool = null,
    };
    pub const Result = struct {
        pub const field_doc = .{ .panes = "The panes that left the model." };

        panes: []const RemovedPane = &.{},
    };
};

/// Moves a pane next to pane `dest` on `zone`, in its tab or in another.
pub const PaneMove = struct {
    pub const name = "pane.move";
    pub const doc = "Moves a pane next to another pane.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The pane to move.",
            .dest = "The pane next to which it goes, in this tab or in another.",
            .zone = "The side of dest where the pane goes.",
            .split_id = "The id of the new split. The client makes it.",
            .rebalance = "True: every ratio of the tab is even after the change. Null takes auto_tiling of model.options.",
        };

        id: PaneId,
        dest: PaneId,
        zone: model.tree.Zone,
        split_id: SplitId,
        rebalance: ?bool = null,
    };
    pub const Result = struct {};
};

/// Moves a pane out of its tab into a new tab `tab_id`, in `project` (the
/// pane's own when null).
pub const PaneSeparate = struct {
    pub const name = "pane.separate";
    pub const doc = "Moves a pane out of its tab into a new tab.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The pane to move.",
            .tab_id = "The id of the new tab. The client makes it.",
            .project = "The project of the new tab. Null is the project of the pane.",
        };

        id: PaneId,
        tab_id: TabId,
        project: ?ProjectId = null,
    };
    pub const Result = struct {};
};

pub const PaneFocus = struct {
    pub const name = "pane.focus";
    pub const doc = "Sets the focused pane of a tab.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .id = "The pane that gets the focus." };

        id: PaneId,
    };
    pub const Result = struct {};
};

/// Zooms a pane of the tab, or with a null `pane` ends the zoom.
pub const PaneZoom = struct {
    pub const name = "pane.zoom";
    pub const doc = "Zooms a pane of a tab. A null pane ends the zoom.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .tab = "The tab.",
            .pane = "The pane to zoom. Null ends the zoom.",
        };

        tab: TabId,
        pane: ?PaneId = null,
    };
    pub const Result = struct {};
};

/// The ratio of a split, kept inside 0.15 to 0.85.
pub const SplitRatio = struct {
    pub const name = "split.ratio";
    pub const doc = "Sets the ratio of a split, from 0.15 to 0.85.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .id = "The split.",
            .ratio = std.fmt.comptimePrint("The ratio of the first side. The server moves a value out of {d} to {d} into that range, and refuses a value that is not finite.", .{ model.tree.min_ratio, model.tree.max_ratio }),
        };

        id: SplitId,
        ratio: f64,
    };
    pub const Result = struct {};
};

/// The key window's selection. `tab` becomes the active tab of the
/// project. A project with `sidebar: none` fails with `refused`.
pub const SelectSet = struct {
    pub const name = "select.set";
    pub const doc = "Sets the selection of the key window.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .project = "The project that the key window shows.",
            .tab = "The tab that becomes the active tab of the project.",
        };

        project: ?ProjectId = null,
        tab: ?TabId = null,
    };
    pub const Result = struct {};
};

/// Puts the client's conversion of the v1 files in place of the model, one
/// time (design/010 §8). The server refuses it when the model has
/// `imported_v1`, and refuses a model that does not validate with
/// `invalid_args` and the path of the first fault. The stored model has
/// `imported_v1`.
pub const ModelImport = struct {
    pub const name = "model.import";
    pub const doc = "Puts the conversion of the v1 files in place of the model, one time.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{
            .model = "The model that the client made from the v1 files.",
            .source = "What the client read, for the log: workspaces_v3.json, for example.",
        };

        model: model.ModelData,
        source: []const u8 = "",
    };
    pub const Result = struct {};
};

/// Puts the client's copy of its own model in place of this one, any number
/// of times (design/010 §9, step 3: the shadow stage). The app
/// sends it after each save while it still owns the model, so that the
/// server's model, its file and its events follow the app's. It ends no
/// session and leaves `imported_v1` false. The server refuses it with
/// `refused` when the model has `imported_v1`, and refuses a model that
/// does not validate as `model.import` does. Step 7 removes it.
pub const ModelReplace = struct {
    pub const name = "model.replace";
    pub const doc = "Puts the copy of the model of the client in place of the model of the server.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .model = "The model of the client." };

        model: model.ModelData,
    };
    pub const Result = struct {};
};

/// The client's defaults for a request that does not say. The server keeps
/// them in memory only.
pub const ModelOptions = struct {
    pub const name = "model.options";
    pub const doc = "Sets the defaults of this client for requests that do not give them.";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        pub const field_doc = .{ .auto_tiling = "True: a model request with a null rebalance makes every ratio of the tab even." };

        auto_tiling: bool,
    };
    pub const Result = struct {};
};

/// Every request method. A new method goes here.
pub const methods = .{
    ControlResume,  ChannelOpen,    ChannelClose,  ChannelPause, ChannelResume, Ping,           SessionCreate,
    SessionList,    SessionInfo,    SessionKill,   PaneSeen,     SessionSend,   SessionKey,     SessionHistory,
    SessionInspect, ServerExit,     CommandRun,    LinkOpen,     LinkClose,     StateSubscribe, ProjectCreate,
    ProjectSet,     ProjectReorder, ProjectRemove, TabCreate,    TabClose,      TabSet,         TabSelect,
    TabReorder,     TabMove,        TabMerge,      PaneSplit,    PaneClose,     PaneMove,       PaneSeparate,
    PaneFocus,      PaneZoom,       SplitRatio,    SelectSet,    ModelImport,   ModelReplace,   ModelOptions,
    SessionWait,
};

/// The methods that change the model. The server answers one of them sent
/// again from the ring of request ids, and does it only one time.
pub const model_writes = .{
    ProjectCreate, ProjectSet, ProjectReorder, ProjectRemove, TabCreate, TabClose,    TabSet,
    TabSelect,     TabReorder, TabMove,        TabMerge,      PaneSplit, PaneClose,   PaneMove,
    PaneSeparate,  PaneFocus,  PaneZoom,       SplitRatio,    SelectSet, ModelImport, ModelReplace,
    ModelOptions,
};

// ── Events ──────────────────────────────────────────────────────────────────

/// A session stopped running: its shell exited, or the session process is
/// gone. Sent once for each session. A session process that ended with no
/// exit message gives no code and no signal.
pub const SessionExit = struct {
    pub const name = "session.exit";
    pub const since = 1;
    pub const senders = everyone;

    id: []const u8,
    code: ?u8 = null,
    signal: ?u8 = null,

    pub const field_doc = .{
        .id = "The id of the session.",
        .code = "The exit code, when the shell exited.",
        .signal = "The signal number, when a signal ended the shell.",
    };
};

/// A pane's attention flags changed (the session's `attention` message,
/// design/004 §6). Sent for each change, also a clear by `pane.seen`.
pub const PaneAttention = struct {
    pub const name = "pane.attention";
    pub const since = 1;
    pub const senders = everyone;

    id: []const u8,
    unseen: bool,
    failed: bool,
    bell: bool,

    pub const field_doc = .{
        .id = "The id of the session of the pane.",
        .unseen = "True: a run ended, or the bell rang, and no client showed the pane since.",
        .failed = "True with unseen: the run that ended failed.",
        .bell = "True: the bell rang and no client showed the pane since.",
    };
};

/// Every event type. A new event goes here. Each one declares `name`,
/// `since` and `senders`, as a method does, and its fields are the event's
/// `a`. No event may hold a `Secret` (design/006 §1); `schema.check` refuses
/// one.
// The model's events (design/010 §3). Each one carries whole objects, so
// the newest value for a key wins when events merge. One request makes one
// batch.

/// The fields of a project without its tabs: `tab.order` and `tab.set`
/// carry those.
pub const ProjectInfo = struct {
    id: ProjectId,
    name: []const u8,
    path: []const u8,
    color: ?[]const u8 = null,
    sort_order: i64 = 0,
    created_at: i64 = 0,
    parent: ?ProjectId = null,
    sidebar: model.ProjectSidebar = .tree,
    single_tab: bool = false,
    removable: bool = true,
    alias: ?[]const u8 = null,

    pub const field_doc = .{
        .id = "The id of the project.",
        .name = "The name of the project.",
        .path = "A local path, or user@host:dir. Can be empty.",
        .color = "The color tag of the project. Null when the project has none.",
        .sort_order = "Orders the projects that have the same parent.",
        .created_at = "When the project was made, in Unix time in milliseconds.",
        .parent = "The project that holds it. Null or empty is the top level.",
        .sidebar = "Where the sidebar shows the project: tree is a row of the project tree; top and bottom show its tabs as rows above or below the tree, with no project row; none is a project that no window shows. project.create sets it, and it never changes.",
        .single_tab = "True: the project holds at most one tab. project.create sets it, and it never changes.",
        .removable = "True: project.remove can remove the project. project.create sets it, and it never changes.",
        .alias = "A short word that finds the project (pinned, scratch, quick). It is unique in the model. project.create sets it, and it never changes.",
    };

    pub fn of(p: model.Project) ProjectInfo {
        return .{
            .id = p.id,
            .name = p.name,
            .path = p.path,
            .color = p.color,
            .sort_order = p.sort_order,
            .created_at = p.created_at,
            .parent = p.parent,
            .sidebar = p.sidebar,
            .single_tab = p.single_tab,
            .removable = p.removable,
            .alias = p.alias,
        };
    }
};

/// A project was made or changed.
pub const ProjectChanged = struct {
    pub const name = "project.set";
    pub const since = 3;
    pub const senders = everyone;

    project: ProjectInfo,

    pub const field_doc = .{
        .project = "The project, without its tabs.",
    };
};

pub const ProjectRemoved = struct {
    pub const name = "project.remove";
    pub const since = 3;
    pub const senders = everyone;

    id: ProjectId,

    pub const field_doc = .{
        .id = "The id of the project that was removed.",
    };
};

/// The order of the children of `parent` (the top level when null).
pub const ProjectOrder = struct {
    pub const name = "project.order";
    pub const since = 3;
    pub const senders = everyone;

    parent: ?ProjectId = null,
    ids: []const ProjectId,

    pub const field_doc = .{
        .parent = "The project whose children are in ids. Null is the top level.",
        .ids = "Each child project, in its order.",
    };
};

/// A tab was made or changed: the whole tab with its tree.
pub const TabChanged = struct {
    pub const name = "tab.set";
    pub const since = 3;
    pub const senders = everyone;

    project: ProjectId,
    tab: model.Tab,
    zoomed: ?PaneId = null,

    pub const field_doc = .{
        .project = "The project of the tab.",
        .tab = "The whole tab, with its split tree.",
        .zoomed = "The zoomed pane of the tab. Null when no pane is zoomed.",
    };
};

pub const TabRemoved = struct {
    pub const name = "tab.remove";
    pub const since = 3;
    pub const senders = everyone;

    project: ProjectId,
    id: TabId,

    pub const field_doc = .{
        .project = "The project of the tab.",
        .id = "The id of the tab that was removed.",
    };
};

/// The tabs of a project, their order or its active tab changed.
pub const TabOrder = struct {
    pub const name = "tab.order";
    pub const since = 3;
    pub const senders = everyone;

    project: ProjectId,
    ids: []const TabId,
    active_tab: ?TabId = null,

    pub const field_doc = .{
        .project = "The project of the tabs.",
        .ids = "Each tab of the project, in its order.",
        .active_tab = "The tab that the project shows. Null when it shows no tab.",
    };
};

pub const SelectionChanged = struct {
    pub const name = "selection";
    pub const since = 3;
    pub const senders = everyone;

    active_project: ?ProjectId = null,

    pub const field_doc = .{
        .active_project = "The project that is selected. Null when no project is selected.",
    };
};

/// A pane left the model (`RemovedPane`).
pub const PaneRemoved = struct {
    pub const name = "pane.removed";
    pub const since = 3;
    pub const senders = everyone;

    id: PaneId,
    session: []const u8,
    host: ?[]const u8 = null,

    pub const field_doc = .{
        .id = "The id of the pane.",
        .session = "The id of the session of the pane.",
        .host = "The host of the session. Null for a pane of this Mac.",
    };
};

pub const events = .{
    SessionExit, PaneAttention,    ProjectChanged, ProjectRemoved, ProjectOrder, TabChanged, TabRemoved,
    TabOrder,    SelectionChanged, PaneRemoved,
};

/// True if a connection with this trust may send message `M`. A message from
/// a sender outside the list gets an error reply and a log line; the link
/// stays up (design/006 §2).
pub fn maySend(comptime M: type, trust: Trust) bool {
    return std.mem.findScalar(Trust, M.senders, trust) != null;
}

pub fn encodeRequest(w: *std.Io.Writer, id: u64, comptime M: type, args: M.Args) std.Io.Writer.Error!void {
    try msgpack.encode(w, struct { id: u64, m: []const u8, a: M.Args }{ .id = id, .m = M.name, .a = args });
}

pub fn encodeResult(w: *std.Io.Writer, re: u64, comptime M: type, result: M.Result) std.Io.Writer.Error!void {
    try msgpack.encode(w, struct { re: u64, ok: M.Result }{ .re = re, .ok = result });
}

pub fn decodeArgs(comptime M: type, arena: std.mem.Allocator, req: Request) msgpack.DecodeError!M.Args {
    return msgpack.decodeSlice(M.Args, arena, if (req.a) |a| a.bytes else &.{0x80});
}

/// `error.ErrorResponse` if the response is an error: read `res.err`.
pub fn decodeResult(
    comptime M: type,
    arena: std.mem.Allocator,
    res: Response,
) (msgpack.DecodeError || error{ErrorResponse})!M.Result {
    const ok = res.ok orelse return error.ErrorResponse;
    return msgpack.decodeSlice(M.Result, arena, ok.bytes);
}

// ── A session's pane channel ────────────────────────────────────────────────

/// A `msg` frame on a pane channel: `{t, a}`. `t` names one of
/// `pane_messages`, `a` holds its fields. A receiver ignores a `t` that it
/// does not know.
///
/// On a direct session socket the pane channel is `pane_channel`
/// (design/003 §1). A client sends `Attach` before it gets any pane output;
/// a client that never sends it (a server that reads the exit status) gets
/// only the session's messages.
pub const PaneMessage = struct {
    t: []const u8,
    a: ?Raw = null,

    pub const field_doc = .{
        .t = "The name of the pane message. A receiver ignores a name that it does not know.",
        .a = "The fields of the message. Null when the message has none.",
    };
};

/// The channel of the pane on a direct session socket.
pub const pane_channel: u32 = 1;

const from_client: []const Trust = &.{.local};
const from_session: []const Trust = &.{.session};

/// The session's state, sent once after `hello`, and again when it changes.
pub const State = struct {
    pub const name = "state";
    pub const since = 1;
    pub const senders = from_session;

    pid: i64,
    /// Its parent is the session, so the session reads its exit status.
    shell_pid: i64,
    pty: msgpack.Bin,
    cols: u16,
    rows: u16,
    /// The session sends `state` again to its other connections (the
    /// server's) each time this count changes.
    clients: ?u16 = null,

    pub const field_doc = .{
        .pid = "The pid of the session process.",
        .shell_pid = "The pid of the shell, or of the command, that the session started.",
        .pty = "The path of the slave side of the pty. Not UTF-8 on every system.",
        .cols = "The width of the terminal in cells.",
        .rows = "The height of the terminal in cells.",
        .clients = "The number of clients that sent attach.",
    };
};

/// The first message of a client that shows the pane: its size. When the
/// pane has output, the session answers with a snapshot (`SnapshotStart`,
/// `bytes`, `SnapshotEnd`), laid out for that size when the client leads.
/// A size over 1000 cells is cut to 1000; a size of 0 is ignored.
pub const Attach = struct {
    pub const name = "attach";
    pub const since = 1;
    pub const senders = from_client;

    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
    foreground: bool = false,
    tty: bool = false,
    /// design/003 §7. If the session still holds the output after the
    /// offset, it answers with `Resumed` and the missing bytes, and no
    /// snapshot. Otherwise it sends a snapshot.
    resume_epoch: ?u64 = null,
    resume_offset: ?u64 = null,

    pub const field_doc = .{
        .cols = "The width of the terminal in cells.",
        .rows = "The height of the terminal in cells.",
        .xpixel = "The width of the terminal in pixels. 0 when the client does not know it.",
        .ypixel = "The height of the terminal in pixels. 0 when the client does not know it.",
        .foreground = "True: the client wants foreground messages. The session reads the foreground of the pty only while a client that asked for them is connected.",
        .tty = "True: the client wants tty_mode messages. The session reads the line modes of the pty only while a client that asked for them is connected.",
        .resume_epoch = "To resume after a lost link: the epoch of the hello of the session. Send both resume fields or none.",
        .resume_offset = "To resume after a lost link: the offset after the last output byte that the client got. Send both resume fields or none.",
    };

    pub const field_since = .{ .resume_epoch = 2, .resume_offset = 2, .tty = 3 };
};

/// The client's new size. Only the leader's size reaches the pty.
pub const Resize = struct {
    pub const name = "resize";
    pub const since = 1;
    pub const senders = from_client;

    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,

    pub const field_doc = .{
        .cols = "The width of the terminal in cells.",
        .rows = "The height of the terminal in cells.",
        .xpixel = "The width of the terminal in pixels. 0 when the client does not know it.",
        .ypixel = "The height of the terminal in pixels. 0 when the client does not know it.",
    };
};

/// The client takes leadership without input (zmx 0003). It then sends its
/// size with `Resize`.
pub const Claim = struct {
    pub const name = "claim";
    pub const since = 1;
    pub const senders = from_client;
};

/// Tells a client that it leads (its size is the pty's) or that it does not:
/// at its first attach, and at each change.
/// When the leader leaves, the client that attached first of those left
/// leads. A client that starts to lead sends its size.
pub const Lead = struct {
    pub const name = "lead";
    pub const since = 1;
    pub const senders = from_session;

    leader: bool,

    pub const field_doc = .{
        .leader = "True: the client leads, and its size is the size of the pty.",
    };
};

/// The `bytes` frames up to `SnapshotEnd` are a snapshot of the terminal,
/// not output.
pub const SnapshotStart = struct {
    pub const name = "snapshot.start";
    pub const since = 1;
    pub const senders = from_session;

    scrollback: bool,
    offset: ?u64 = null,

    pub const field_doc = .{
        .scrollback = "True: the snapshot holds the scrollback. False after dropped output: it holds the screen only, and clears the old screen first.",
        .offset = "The output offset that the screen in this snapshot shows: the output bytes that follow start here. A client that counts its output bytes takes this as its offset.",
    };

    pub const field_since = .{ .offset = 2 };
};

/// The answer to an `Attach` that asked to resume, when the session still
/// holds the output after the client's offset: the output bytes from that
/// offset follow at once, then the live output. No snapshot comes. A client
/// that gets `SnapshotStart` in place of this has to show the snapshot.
pub const Resumed = struct {
    pub const name = "resumed";
    pub const since = 2;
    pub const senders = from_session;

    offset: u64,

    pub const field_doc = .{
        .offset = "The offset of the first output byte that follows. It is the offset of the client.",
    };
};

pub const SnapshotEnd = struct {
    pub const name = "snapshot.end";
    pub const since = 1;
    pub const senders = from_session;
};

/// The shell exited. The session keeps the status, and sends this to every
/// client that connects, until one sends `Take`.
pub const Exit = struct {
    pub const name = "exit";
    pub const since = 1;
    pub const senders = from_session;

    code: ?u8 = null,
    signal: ?u8 = null,

    pub const field_doc = .{
        .code = "The exit code, when the shell exited.",
        .signal = "The signal number, when a signal ended the shell.",
    };
};

/// The client has the exit status. The session then ends.
pub const Take = struct {
    pub const name = "take";
    pub const since = 1;
    pub const senders = from_client;
};

/// The client ends the session: the session sends SIGHUP to the shell's
/// process group, SIGKILL 0.5 s later if it still runs, and then ends. It
/// sends no `exit`.
pub const End = struct {
    pub const name = "end";
    pub const since = 1;
    pub const senders = from_client;
};

/// The client asks for a snapshot of the screen, after it dropped output or
/// did not show it (a server's relay, design/003 §6). The session drops the
/// output that waits for that client and sends the snapshot, with no
/// scrollback. A client that does not show the pane gets nothing.
pub const Refresh = struct {
    pub const name = "refresh";
    pub const since = 1;
    pub const senders = from_client;
};

// The session's events (design/003 §5, design/004 §6). The session reads
// them from its own terminal and pty, so they are right for a client that
// does not show the pane. Every greeted client gets them; a client that
// connects gets the current title, cwd, foreground, progress, status and
// program status after `State`. Each one is sent before the pane output
// that follows it.
//
// Title, cwd, progress, program status and bell coalesce: the first in a
// quiet period goes at once, later ones in the next `coalesce_ms` merge and
// go at its end, newest value wins. Activity goes at most once in
// `activity_ms`, and the rest is dropped. Foreground, marks and status are
// never held.

/// The window in which title, cwd, progress, program status and bell
/// coalesce.
pub const coalesce_ms = 16;

/// The output heartbeat goes at most once in this time (v1's libghostty
/// `OUTPUT_ACTIVITY`): leading edge, the rest dropped, never deferred.
pub const activity_ms = 500;

/// The terminal title (OSC 0 and OSC 2).
pub const Title = struct {
    pub const name = "title";
    pub const since = 1;
    pub const senders = from_session;

    title: msgpack.Bin,

    pub const field_doc = .{
        .title = "The title, as the program sent it. Not UTF-8 from every program.",
    };
};

/// The working directory that the shell reports (OSC 7).
pub const Cwd = struct {
    pub const name = "cwd";
    pub const since = 1;
    pub const senders = from_session;

    url: msgpack.Bin,

    pub const field_doc = .{
        .url = "The OSC 7 payload, as the shell sent it: usually a percent-encoded file:// URL. The receiver decodes it.",
    };
};

/// The process group that holds the pty (zmx 0010). Sent when the group or
/// its leader's name changes, and to a client that connects or catches up.
pub const Foreground = struct {
    pub const name = "foreground";
    pub const since = 1;
    pub const senders = from_session;

    idle: bool,
    shell: ?bool = null,
    comm: msgpack.Bin,
    args: msgpack.Bin,

    pub const field_doc = .{
        .idle = "True: the foreground group is the own shell of the session.",
        .shell = "True: comm is in /etc/shells of the host. Null when the host has no /etc/shells.",
        .comm = "The name of the process: the executable path on macOS, the kernel comm on Linux.",
        .args = "The command line, with its arguments joined by spaces.",
    };
};

/// The server asks the session for one key press (`session.key`). The
/// session ignores a chord that does not parse.
pub const Key = struct {
    pub const name = "key";
    pub const since = 3;
    pub const senders = from_client;

    chord: []const u8,

    pub const field_doc = .{
        .chord = "The key press, in the keybind grammar of the app: ctrl+c, for example.",
    };
};

/// The server asks for the terminal's text (`session.history`). The session
/// answers with `History`, in the order of the requests.
pub const HistoryRead = struct {
    pub const name = "history_read";
    pub const since = 3;
    pub const senders = from_client;

    scrollback: bool = false,

    pub const field_doc = .{
        .scrollback = "True: the text includes the scrollback. False: the screen only.",
    };
};

pub const History = struct {
    pub const name = "history";
    pub const since = 3;
    pub const senders = from_session;

    text: msgpack.Bin,
    truncated: bool = false,

    pub const field_doc = .{
        .text = "The text of the terminal.",
        .truncated = "True: the text was too long, and only its end is here.",
    };
};

/// The server asks for the pty's line modes now, before it types for an
/// `mcp` client (design/014 §5). The session answers with `TtyMode`, in the
/// order of the requests, also when no client asked for `tty_mode`. A
/// session that cannot read the modes answers a password read, so that the
/// server refuses the input. A session has the `tty-read` cap when it
/// answers this message.
pub const TtyRead = struct {
    pub const name = "tty_read";
    pub const since = 3;
    pub const senders = from_client;
};

/// The cap in a session's `hello` that says it answers `TtyRead`.
pub const tty_read_cap = "tty-read";

/// The cap of a session that sends `DesktopNotification`. A client takes a
/// notification from the terminal it feeds only when the session has no
/// such cap: a session of an older build.
pub const notification_cap = "notification";

/// The server asks the session to wait (`session.wait`). The session
/// answers with `Waited` and the same `tag` when the wait ends. Waits end in
/// any order.
pub const Wait = struct {
    pub const name = "wait";
    pub const since = 3;
    pub const senders = from_client;

    tag: u64,
    text: ?[]const u8 = null,
    timeout_ms: u32,

    pub const field_doc = .{
        .tag = "The id of the wait. Waited carries the same tag.",
        .text = "The marker. The wait ends when a line starts with it. Null: the wait ends when no command runs and the pane is quiet.",
        .timeout_ms = "The longest time to wait, in milliseconds.",
    };
};

/// The client of a `session.wait` left: the session stops the wait with
/// this tag and sends no `waited`.
pub const WaitCancel = struct {
    pub const name = "wait_cancel";
    pub const since = 3;
    pub const senders = from_client;

    tag: u64,

    pub const field_doc = .{ .tag = "The tag of the wait to stop." };
};

pub const Waited = struct {
    pub const name = "waited";
    pub const since = 3;
    pub const senders = from_session;

    tag: u64,
    end: WaitEnd,
    line: ?msgpack.Bin = null,

    pub const field_doc = .{
        .tag = "The tag of the wait that ended.",
        .end = "Why the wait ended: matched, done, exited or timeout.",
        .line = "With matched: the newest line that starts with the marker, cut at 4 KiB.",
    };
};

/// The server asks for the terminal's state (`session.inspect`). The session
/// answers with `Inspect`, in the order of the requests.
pub const InspectRead = struct {
    pub const name = "inspect_read";
    pub const since = 3;
    pub const senders = from_client;
};

pub const Inspect = struct {
    pub const name = "inspect";
    pub const since = 3;
    pub const senders = from_session;

    terminal: TerminalState,

    pub const field_doc = .{
        .terminal = "The state of the terminal of the session.",
    };
};

/// How the pty reads input (`termios` `ICANON` and `ECHO`). A password read
/// is canonical with echo off. Sent when a mode changes, and to a client
/// that connects or catches up, if its `attach` asked for it.
pub const TtyMode = struct {
    pub const name = "tty_mode";
    pub const since = 3;
    pub const senders = from_session;

    canonical: bool,
    echo: bool,

    pub const field_doc = .{
        .canonical = "True: the pty reads input one line at a time (ICANON).",
        .echo = "True: the pty echoes input (ECHO).",
    };
};

pub const MarkKind = enum {
    /// The shell starts to draw a prompt (OSC 133;A).
    prompt,
    /// The prompt is drawn and the user can type (OSC 133;B).
    input,
    /// The user submitted a command and it runs (OSC 133;C).
    output,
    /// The command finished (OSC 133;D).
    end,
    unknown,
};

/// A step of a command, from shell integration (OSC 133). A client that
/// greets, refreshes or catches up while the shell waits for input also gets
/// an `input` mark: it tells the current state, not a new step.
pub const Mark = struct {
    pub const name = "mark";
    pub const since = 1;
    pub const senders = from_session;
    pub const field_since = .{ .output_tail = 3 };

    kind: MarkKind,
    command: ?msgpack.Bin = null,
    exit_code: ?i32 = null,
    /// `events.outputTail` makes it.
    output_tail: ?msgpack.Bin = null,

    pub const field_doc = .{
        .kind = "The step: prompt, input, output or end.",
        .command = "For output and end: the command line. It is the text of the shell when the shell sent one, else the input cells of the prompt. Null when there is neither.",
        .exit_code = "For end: the exit code, when the shell sent one.",
        .output_tail = "For end with a nonzero exit code: the last rows of the output of the command, as text. Null when there is no output.",
    };
};

pub const ProgressState = enum {
    remove,
    set,
    @"error",
    indeterminate,
    pause,
    unknown,
};

/// A progress report (OSC 9;4).
pub const Progress = struct {
    pub const name = "progress";
    pub const since = 1;
    pub const senders = from_session;

    state: ProgressState,
    percent: ?u8 = null,

    pub const field_doc = .{
        .state = "The state of the progress report: remove, set, error, indeterminate or pause.",
        .percent = "The progress, from 0 to 100. Null when the program sent none.",
    };
};

/// A program asked for a desktop notification (OSC 9 or OSC 777). The
/// session sends each one once, to each client that is attached then, and
/// does not drop it for a client that is behind. A client that attaches
/// later does not get it. A session with this message has the
/// `notification_cap`.
pub const DesktopNotification = struct {
    pub const name = "notification";
    pub const since = 3;
    pub const senders = from_session;

    title: msgpack.Bin,
    body: msgpack.Bin,

    pub const field_doc = .{
        .title = "The title, as the program sent it. Empty for OSC 9, which has a body only.",
        .body = "The body, as the program sent it. Not UTF-8 from every program.",
    };
};

/// The program rang the bell (BEL).
pub const Bell = struct {
    pub const name = "bell";
    pub const since = 1;
    pub const senders = from_session;
};

/// The pane printed output (the heartbeat, `activity_ms`).
pub const Activity = struct {
    pub const name = "activity";
    pub const since = 1;
    pub const senders = from_session;
};

pub const RunState = enum {
    /// No command ran yet.
    idle,
    running,
    done,
    unknown,
};

/// The pane's run (`events.Watch`): `running` from OSC 133;C, a progress
/// report that sets work, a new group in front after a Return to a shell
/// with no marks or to a program (a nested shell), or output after a Return
/// to a program in raw mode (an agent). `done` from OSC 133;D, a report that
/// ends it, the shell or the group that took the Return back in front, or
/// 3 s with no output while a program in raw mode is in front.
pub const Status = struct {
    pub const name = "status";
    pub const since = 1;
    pub const senders = from_session;

    state: RunState,
    /// v1's red dot. The exit code does not count: it judges the command,
    /// not the run.
    failed: bool = false,

    pub const field_doc = .{
        .state = "The run state of the pane: idle (no command ran yet), running or done.",
        .failed = "True with done: a progress report said error.",
    };
};

/// What the pane shows that the user did not see yet (design/004 §6). The
/// session keeps it for as long as the pane lives, so a client that attaches
/// later, with the app quit in between, gets it with the current state.
/// `unseen` is set when a run ends (`status` goes to `done`) and when the
/// bell rings; `failed` says that the run that ended failed. A new run
/// clears `unseen` and `failed`. `Seen` clears all three. A client sends it
/// when it shows the pane in the active app.
pub const Attention = struct {
    pub const name = "attention";
    pub const since = 1;
    pub const senders = from_session;

    unseen: bool = false,
    failed: bool = false,
    bell: bool = false,

    pub const field_doc = .{
        .unseen = "True: a run ended, or the bell rang, and no client showed the pane since.",
        .failed = "True with unseen: the run that ended failed.",
        .bell = "True: the bell rang and no client showed the pane since.",
    };
};

/// A client showed the pane to the user: clear the attention flags. The
/// session answers with `attention`, also when nothing changed.
pub const Seen = struct {
    pub const name = "seen";
    pub const since = 1;
    pub const senders = from_client;
};

pub const ProgramState = enum {
    /// At rest, waits for the user's next instruction.
    idle,
    working,
    /// Finished work that the user did not look at yet.
    done,
    /// Cannot continue until the user does something.
    blocked,
    @"error",
    unknown,
};

/// What a blocked program needs from the user.
pub const ProgramNeed = enum {
    /// Approval to do something.
    permission,
    /// An answer that the user types.
    question,
    /// A login, a token or another credential.
    auth,
    unknown,
};

/// One record of a program's status (OSC 7501).
pub const ProgramRecord = struct {
    id: []const u8 = "",
    state: ProgramState,
    kind: ?ProgramNeed = null,
    progress: ?u8 = null,
    app: ?[]const u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,

    pub const field_doc = .{
        .id = "The id of the record: names joined by /, where a/b is a child of a. Empty for the root record, which is the program itself.",
        .state = "The state of the record: idle, working, done, blocked or error.",
        .kind = "With blocked: what the program needs: permission, question or auth.",
        .progress = "With working or blocked: the progress, from 0 to 100. Null when the program gave none.",
        .app = "A stable name for the program: cargo, for example. A record that gave none has the app of its nearest ancestor that gave one, the root record included.",
        .title = "A short label for the record, decoded: UTF-8 with no control characters. It is still the text of the program.",
        .msg = "One line that says what the record does or waits for, decoded as title.",
    };
};

/// The records of the program status protocol (OSC 7501). Each change sends
/// all of them. It coalesces as the title does.
///
/// The session keeps the records as the protocol's terminal does: a report
/// replaces its record, `clear` removes a record and the records under it, a
/// new shell prompt (OSC 133;A) and the shell's exit remove the `working`,
/// `blocked` and `idle` records, and a full reset removes every record. It
/// keeps at most `max_program_records`, and removes the record that changed
/// least recently to make space. `done` and `error` stay until the program
/// replaces or clears them.
pub const ProgramStatus = struct {
    pub const name = "program_status";
    pub const since = 1;
    pub const senders = from_session;

    records: []const ProgramRecord,

    pub const field_doc = .{
        .records = "Every record that the pane holds now, oldest first. An empty list clears them all.",
    };
};

/// The most records that a pane keeps (the protocol requires 64 or more).
pub const max_program_records = 64;

/// Every message on a pane channel. A new one goes here.
pub const pane_messages = .{
    State,               Attach,  Resize,     Claim,       Lead,     SnapshotStart, SnapshotEnd, Exit,   Take,          End,        Refresh,
    Title,               Cwd,     Foreground, Mark,        Progress, Bell,          Activity,    Status, ProgramStatus, Attention,  Seen,
    Resumed,             TtyMode, Key,        HistoryRead, History,  InspectRead,   Inspect,     Wait,   Waited,        WaitCancel, TtyRead,
    DesktopNotification,
};

pub fn encodePane(w: *std.Io.Writer, comptime M: type, value: M) std.Io.Writer.Error!void {
    try msgpack.encode(w, struct { t: []const u8, a: M }{ .t = M.name, .a = value });
}

/// Decodes the fields of a pane message whose `t` is `M.name`.
pub fn decodePane(comptime M: type, arena: std.mem.Allocator, msg: PaneMessage) msgpack.DecodeError!M {
    return msgpack.decodeSlice(M, arena, if (msg.a) |a| a.bytes else &.{0x80});
}

// ── Reading channel 0 ───────────────────────────────────────────────────────

pub const Control = union(enum) {
    hello: Hello,
    refuse: Refuse,
    request: Request,
    response: Response,
    events: EventBatch,
    /// A message of a kind that a later build added. Ignore it.
    unknown,
};

/// Decodes one message from the body of a channel-0 frame. The keys name its
/// kind: `m` a request, `re` a response, `seq` an event batch, `needs_level`
/// a refusal, `level` a hello. These keys are frozen with the shapes.
pub fn decodeControl(arena: std.mem.Allocator, body: []const u8) msgpack.DecodeError!Control {
    const Kind = enum { request, response, events, refuse, hello, unknown };
    var kind: Kind = .unknown;
    var r: msgpack.Reader = .{ .bytes = body };
    const count = try r.readMapLen();
    for (0..count) |_| {
        const key = try r.decode([]const u8, arena);
        try r.skip();
        const k: Kind = if (std.mem.eql(u8, key, "m"))
            .request
        else if (std.mem.eql(u8, key, "re"))
            .response
        else if (std.mem.eql(u8, key, "seq"))
            .events
        else if (std.mem.eql(u8, key, "needs_level"))
            .refuse
        else if (std.mem.eql(u8, key, "level"))
            .hello
        else
            .unknown;
        if (@backingInt(k) < @backingInt(kind)) kind = k;
    }
    return switch (kind) {
        .request => .{ .request = try msgpack.decodeSlice(Request, arena, body) },
        .response => {
            const res = try msgpack.decodeSlice(Response, arena, body);
            if ((res.ok == null) == (res.err == null)) return error.WrongType;
            return .{ .response = res };
        },
        .events => .{ .events = try msgpack.decodeSlice(EventBatch, arena, body) },
        .refuse => .{ .refuse = try msgpack.decodeSlice(Refuse, arena, body) },
        .hello => .{ .hello = try msgpack.decodeSlice(Hello, arena, body) },
        .unknown => .unknown,
    };
}
