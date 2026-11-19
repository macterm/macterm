//! The messages on channel 0 (design/003 §2, §4; design/006 §2).
//!
//! Each message type is a Zig struct, and this file is the one source of the
//! schema: the Swift side and the metadata are made from it (issue 0045).
//! Each type declares:
//!
//! - `name`: the method or message name on the wire;
//! - `since`: the protocol level that added it;
//! - `senders`: the trust levels of the connections that may send it.
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
    /// A random id for each server start. A new epoch tells a client that
    /// the server restarted.
    epoch: u64,
    /// What the build or its platform can do apart from its level (`tcc`,
    /// `password-tty`). A peer ignores a cap it does not know.
    caps: []const []const u8,
    /// The build key (`scripts/build-server.sh`): lowercase hex. Null for a
    /// build with no key (a development build). `build` is text for people;
    /// two builds are the same build only when their keys are equal.
    build_key: ?[]const u8 = null,
};

/// Sent in place of any other message when the peer speaks too low a level.
/// The sender then closes the connection. Its layout is frozen, as `Hello`'s.
pub const Refuse = struct {
    pub const name = "refuse";
    pub const since = 1;
    pub const senders = everyone;

    /// A code, not text for people: `level_too_low`.
    reason: []const u8,
    /// The lowest level that the sender accepts.
    needs_level: u32,
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
/// both builds from the two hellos.
pub fn negotiate(mine: Hello, theirs: Hello) Negotiation {
    const speak = @min(mine.level, theirs.level);
    if (speak < mine.min_level) return .{ .refuse = .{
        .reason = "level_too_low",
        .needs_level = mine.min_level,
    } };
    if ((mine.role == .cli or theirs.role == .cli) and !std.mem.eql(u8, mine.build, theirs.build))
        return .{ .refuse = .{ .reason = "build_mismatch", .needs_level = mine.level } };
    return .{ .speak = speak };
}

// ── Envelopes ───────────────────────────────────────────────────────────────

/// `{id, m, a}`. The id comes from the client and is unique for its
/// connection epoch, so that a request sent again after a resume is matched
/// and not done two times.
pub const Request = struct {
    id: u64,
    m: []const u8,
    /// The method's `Args`. Null for an empty argument map.
    a: ?Raw = null,
};

/// `{re, ok}` or `{re, err}`: exactly one of the two. `decodeControl`
/// refuses a response with both or neither.
pub const Response = struct {
    re: u64,
    /// The method's `Result`.
    ok: ?Raw = null,
    err: ?ErrorInfo = null,
};

pub const ErrorInfo = struct {
    /// An `ErrorCode` tag. A receiver reads a code that it does not know as
    /// an error with no special handling.
    code: []const u8,
    message: []const u8,
    /// The level that the request needs, when the error is that the peer
    /// speaks a lower one.
    level: ?u32 = null,
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
};

/// One consistent state: the receiver applies all of its events at once.
pub const EventBatch = struct {
    pub const field_since = .{ .cause = 3 };

    /// Counts batches within one epoch.
    seq: u64,
    ev: []const Event,
    /// The id of the request that caused the batch, only on the connection
    /// that sent the request (design/010 §3). Null on every other
    /// connection, and in a batch that `control.resume` sends again.
    cause: ?u64 = null,
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
    pub const since = 2;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
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
    pub const Result = struct { replayed: bool, seq: u64 };
};

/// Opens a channel for a session's pane (design/003 §1).
pub const ChannelOpen = struct {
    pub const name = "channel.open";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { session: []const u8 };
    pub const Result = struct { channel: u32 };
};

pub const ChannelClose = struct {
    pub const name = "channel.close";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { channel: u32 };
    pub const Result = struct {};
};

/// Stops a channel's pane output, for a pane that no one sees. The session's
/// messages on the channel (its exit, its state) still come (design/003 §6).
pub const ChannelPause = struct {
    pub const name = "channel.pause";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { channel: u32 };
    pub const Result = struct {};
};

/// Starts a paused channel's output again. A snapshot of the screen comes
/// first on the channel.
pub const ChannelResume = struct {
    pub const name = "channel.resume";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { channel: u32 };
    pub const Result = struct {};
};

/// Tells a client that the link is up. Any frame does the same; this one gets
/// an answer when nothing else moves (design/005, "Reconnect").
pub const Ping = struct {
    pub const name = "ping";
    pub const since = 1;
    pub const senders = everyone;

    pub const Args = struct {};
    pub const Result = struct {};
};

/// What the server knows of one session (design/001). The session process
/// holds all of it, so a new server reads it again from each session.
pub const Session = struct {
    pub const field_since = .{ .build_key = 3 };

    /// The session's name: the file name of its socket. The client that
    /// asked for the session made it.
    id: []const u8,
    state: SessionState,
    /// The session's build and level, from its `hello`.
    build: []const u8,
    level: u32,
    /// The session's build key, from its `hello`. Null when the session did
    /// not say (a build with no key).
    build_key: ?[]const u8 = null,
    /// The session process. Null when `state` is `refused`.
    pid: ?i64 = null,
    /// The shell (or the command) of the session.
    shell_pid: ?i64 = null,
    /// The path of the pty's slave side.
    pty: ?msgpack.Bin = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    /// The exit code, when `state` is `exited` and the shell exited.
    code: ?u8 = null,
    /// The signal number, when `state` is `exited` and a signal ended the
    /// shell.
    signal: ?u8 = null,
    /// The clients that show the session (they sent `attach`). Null when
    /// the session did not say (a session of an older build).
    clients: ?u16 = null,
    /// The pane's attention flags, from the session's `attention` message.
    /// All false for a pane that has nothing to show.
    unseen: bool = false,
    failed: bool = false,
    bell: bool = false,
};

pub const SessionState = enum {
    running,
    /// The shell ended. The session keeps the status until a client sends
    /// `session.kill`.
    exited,
    /// The session and the server have no level in common. The server
    /// cannot read its state or end it.
    refused,
    /// A state that a later build added.
    unknown,
};

/// Starts a session process (design/001). The server answers when the
/// session's socket accepts connections and the session sent its state.
pub const SessionCreate = struct {
    pub const name = "session.create";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        /// Made by the client, so that a request sent again finds the session
        /// that the first one started, and starts no second one. Only
        /// letters, digits, `-`, `_` and `.`; not `.` first.
        id: []const u8,
        /// The session's folder, an absolute path. Null is the home folder.
        cwd: ?msgpack.Bin = null,
        /// The command in place of a login shell.
        command: ?[]const msgpack.Bin = null,
        cols: u16 = 80,
        rows: u16 = 24,
        /// The session's environment, as `NAME=value` entries, in place of
        /// the server's. The server sets its own runtime directory in it.
        /// A pane's client sends its own, so that the shell gets the
        /// environment that the terminal made for it.
        env: ?[]const msgpack.Bin = null,
    };
    pub const Result = struct { session: Session };
};

pub const SessionList = struct {
    pub const name = "session.list";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct { sessions: []const Session };
};

pub const SessionInfo = struct {
    pub const name = "session.info";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: []const u8 };
    pub const Result = struct { session: Session };
};

/// Ends a session. A running session ends its shell (SIGHUP to the shell's
/// process group, then SIGKILL). An exited session gives its status to no
/// one more and ends. The server answers when the session process is gone.
pub const SessionKill = struct {
    pub const name = "session.kill";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: []const u8 };
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
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: []const u8 };
    pub const Result = struct {};
};

/// The server exits and leaves every session running, so that a newer app
/// can start its own server (design/002).
pub const ServerExit = struct {
    pub const name = "server.exit";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct {};
};

/// Runs a command on the server's machine to its end, and returns what it
/// wrote to stdout. It is not a session: it has no pty, stdin and stderr are
/// `/dev/null`, and it has the server's environment. The app's background
/// reads of a host use it, over the host's one connection (0058). A client
/// that may create a session may run a command in one, so this gives no new
/// access.
pub const CommandRun = struct {
    pub const name = "command.run";
    pub const since = 1;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        /// The program, an absolute path, then its arguments.
        argv: []const msgpack.Bin,
        /// The folder, an absolute path. Null is the home folder.
        cwd: ?msgpack.Bin = null,
        /// After this, the command's process group gets SIGKILL and the
        /// request fails with `timeout`. The server allows at most 60 s.
        timeout_ms: u32 = 5000,
    };
    pub const Result = struct {
        /// stdout, at most 512 KiB.
        output: msgpack.Bin,
        /// The command wrote more than that. The rest is not in `output`.
        truncated: bool = false,
        /// The exit code, when the command exited.
        code: ?u8 = null,
        /// The signal number, when a signal ended the command.
        signal: ?u8 = null,
    };
};

/// Opens a roaming link (design/009): the server opens a UDP port and
/// answers with it. Both sides seal every packet with `secret`, which the client
/// makes and that goes only in this request, over the connection's own
/// confidentiality (ssh). The client then speaks the same frames over the
/// link, as a client of its own, and may move to a new network with no login.
/// A server with the link off, or with no free port, answers with an error
/// and the client stays on this connection.
pub const LinkOpen = struct {
    pub const name = "link.open";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        /// 32 random bytes. The server keeps it in memory only.
        secret: msgpack.Secret,
        /// Names the key in each packet. The client makes it, and no other
        /// link of this server has it.
        key_id: u32,
    };
    pub const Result = struct {
        /// The UDP port on the host.
        port: u16,
    };
};

/// Ends a link that this connection opened. Its end ends all of its links
/// too.
pub const LinkClose = struct {
    pub const name = "link.close";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { key_id: u32 };
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
pub const WorkspaceId = model.WorkspaceId;
pub const TabId = model.TabId;
pub const PaneId = model.PaneId;
pub const SplitId = model.SplitId;

/// The zoomed pane of a tab. The server keeps zoom in memory only.
pub const Zoom = struct {
    tab: TabId,
    pane: PaneId,
};

/// A pane that left the model. The server ends a local pane's session
/// itself. A client that owns the link to `host` ends a remote one
/// (design/010 §5).
pub const RemovedPane = struct {
    id: PaneId,
    session: []const u8,
    /// Null for a pane of this Mac.
    host: ?[]const u8 = null,
};

/// The full state: the model and the sessions. A client reads it once, then
/// follows the event batches from `seq`. Every client gets every batch; this
/// request only reads.
pub const StateSubscribe = struct {
    pub const name = "state.subscribe";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {};
    pub const Result = struct {
        epoch: u64,
        /// The count of batches in `epoch` that this state includes.
        seq: u64,
        /// Null on a server with no model: a host's server, or a server
        /// that the app did not give `MACTERM_STATE_DIR`.
        model: ?model.ModelData = null,
        /// The zoomed pane of each tab that has one.
        zoomed: []const Zoom = &.{},
        /// The server could not read `model.json`, or the file is of a newer
        /// build. Every model request fails with `model_readonly`.
        readonly: bool = false,
        sessions: []const Session,
        /// This connection's key for the ring of request ids. A client
        /// that resumes on a new connection sends it in `control.resume`.
        client: u64,
    };
};

pub const ProjectCreate = struct {
    pub const name = "project.create";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        id: ProjectId,
        name: []const u8,
        /// A local path, or `user@host:dir`. Empty for a group.
        path: []const u8 = "",
        color: ?[]const u8 = null,
        /// The group that holds it. Null is the top level.
        parent: ?ProjectId = null,
        kind: model.ProjectKind = .project,
        /// Unix time in milliseconds.
        created_at: i64 = 0,
    };
    pub const Result = struct {};
};

/// Changes the fields that are not null. An empty `color` removes the
/// color. An empty `parent` moves the project to the top level.
pub const ProjectSet = struct {
    pub const name = "project.set";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
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
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        parent: ?ProjectId = null,
        ids: []const ProjectId,
    };
    pub const Result = struct {};
};

/// Removes a project and its workspace, or an empty group.
pub const ProjectRemove = struct {
    pub const name = "project.remove";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: ProjectId };
    /// The panes that left the model.
    pub const Result = struct { panes: []const RemovedPane = &.{} };
};

/// Makes a workspace that is not a project's: pinned, scratch, quick or
/// widget. The client gives the id (a fixed id, or a widget's id).
pub const WorkspaceCreate = struct {
    pub const name = "workspace.create";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: WorkspaceId, kind: model.Kind };
    pub const Result = struct {};
};

/// Removes a workspace that is not a project's, with its tabs.
pub const WorkspaceRemove = struct {
    pub const name = "workspace.remove";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: WorkspaceId };
    /// The panes that left the model.
    pub const Result = struct { panes: []const RemovedPane = &.{} };
};

/// Makes a tab. `root` is one pane, or a tree (a layout, a grid), with the
/// ids that the client made. The tab's focus is its first pane.
pub const TabCreate = struct {
    pub const name = "tab.create";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        workspace: WorkspaceId,
        id: TabId,
        /// At the end when null.
        index: ?u32 = null,
        root: model.Node,
        title: ?[]const u8 = null,
        /// The tab becomes the workspace's active tab.
        focus: bool = true,
    };
    pub const Result = struct {};
};

pub const TabClose = struct {
    pub const name = "tab.close";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: TabId };
    /// The panes that left the model.
    pub const Result = struct { panes: []const RemovedPane = &.{} };
};

/// Sets the tab's title. Null removes it.
pub const TabSet = struct {
    pub const name = "tab.set";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: TabId, title: ?[]const u8 = null };
    pub const Result = struct {};
};

/// The active tab of a workspace.
pub const TabSelect = struct {
    pub const name = "tab.select";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { workspace: WorkspaceId, id: TabId };
    pub const Result = struct {};
};

pub const TabReorder = struct {
    pub const name = "tab.reorder";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { workspace: WorkspaceId, id: TabId, index: u32 };
    pub const Result = struct {};
};

/// Moves a tab to another workspace (pinned and scratch included) and makes
/// it the active tab there. No session moves.
pub const TabMove = struct {
    pub const name = "tab.move";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        id: TabId,
        to_workspace: WorkspaceId,
        index: ?u32 = null,
    };
    pub const Result = struct {};
};

/// Puts the tree of tab `src` into tab `dst`, next to `target_pane` on
/// `zone`, or at the edge of the tab when `target_pane` is null. `src`
/// closes; no pane leaves the model.
pub const TabMerge = struct {
    pub const name = "tab.merge";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
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
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        tab: TabId,
        target: PaneId,
        new: model.Pane,
        split_id: SplitId,
        dir: SplitDir,
        position: model.tree.Position = .second,
        /// 0.5 when null.
        ratio: ?f64 = null,
        /// The new pane gets the focus, and a zoom ends.
        focus: bool = true,
        rebalance: ?bool = null,
    };
    pub const Result = struct {};
};

/// Closes a pane. The last pane of a tab closes the tab. The next focus
/// comes from the tab's history.
pub const PaneClose = struct {
    pub const name = "pane.close";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: PaneId, rebalance: ?bool = null };
    /// The panes that left the model.
    pub const Result = struct { panes: []const RemovedPane = &.{} };
};

/// Moves a pane next to pane `dest` on `zone`, in its tab or in another.
pub const PaneMove = struct {
    pub const name = "pane.move";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        id: PaneId,
        dest: PaneId,
        zone: model.tree.Zone,
        split_id: SplitId,
        rebalance: ?bool = null,
    };
    pub const Result = struct {};
};

/// Moves a pane out of its tab into a new tab `tab_id`, in `workspace` (the
/// pane's own when null).
pub const PaneSeparate = struct {
    pub const name = "pane.separate";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        id: PaneId,
        tab_id: TabId,
        workspace: ?WorkspaceId = null,
    };
    pub const Result = struct {};
};

pub const PaneFocus = struct {
    pub const name = "pane.focus";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: PaneId };
    pub const Result = struct {};
};

/// Zooms a pane of the tab, or with a null `pane` ends the zoom.
pub const PaneZoom = struct {
    pub const name = "pane.zoom";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { tab: TabId, pane: ?PaneId = null };
    pub const Result = struct {};
};

/// The ratio of a split, kept inside 0.15 to 0.85.
pub const SplitRatio = struct {
    pub const name = "split.ratio";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { id: SplitId, ratio: f64 };
    pub const Result = struct {};
};

/// The key window's selection. `tab` becomes the active tab of the
/// project's workspace.
pub const SelectSet = struct {
    pub const name = "select.set";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
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
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct {
        model: model.ModelData,
        /// What the client read, for the log (`workspaces_v3.json`).
        source: []const u8 = "",
    };
    pub const Result = struct {};
};

/// The client's defaults for a request that does not say. The server keeps
/// them in memory only.
pub const ModelOptions = struct {
    pub const name = "model.options";
    pub const since = 3;
    pub const senders: []const Trust = &.{.local};

    pub const Args = struct { auto_tiling: bool };
    pub const Result = struct {};
};

/// Every request method. A new method goes here.
pub const methods = .{
    ControlResume,   ChannelOpen,    ChannelClose,  ChannelPause, ChannelResume,  Ping,          SessionCreate,
    SessionList,     SessionInfo,    SessionKill,   PaneSeen,     ServerExit,     CommandRun,    LinkOpen,
    LinkClose,       StateSubscribe, ProjectCreate, ProjectSet,   ProjectReorder, ProjectRemove, WorkspaceCreate,
    WorkspaceRemove, TabCreate,      TabClose,      TabSet,       TabSelect,      TabReorder,    TabMove,
    TabMerge,        PaneSplit,      PaneClose,     PaneMove,     PaneSeparate,   PaneFocus,     PaneZoom,
    SplitRatio,      SelectSet,      ModelImport,   ModelOptions,
};

/// The methods that change the model. The server answers one of them sent
/// again from the ring of request ids, and does it only one time.
pub const model_writes = .{
    ProjectCreate, ProjectSet,   ProjectReorder, ProjectRemove, WorkspaceCreate, WorkspaceRemove, TabCreate,
    TabClose,      TabSet,       TabSelect,      TabReorder,    TabMove,         TabMerge,        PaneSplit,
    PaneClose,     PaneMove,     PaneSeparate,   PaneFocus,     PaneZoom,        SplitRatio,      SelectSet,
    ModelImport,   ModelOptions,
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
};

/// Every event type. A new event goes here. Each one declares `name`,
/// `since` and `senders`, as a method does, and its fields are the event's
/// `a`. No event may hold a `Secret` (design/006 §1); `schema.check` refuses
/// one.
// The model's events (design/010 §3). Each one carries whole objects, so
// the newest value for a key wins when events merge. One request makes one
// batch.

/// A project was made or changed.
pub const ProjectChanged = struct {
    pub const name = "project.set";
    pub const since = 3;
    pub const senders = everyone;

    project: model.Project,
};

pub const ProjectRemoved = struct {
    pub const name = "project.remove";
    pub const since = 3;
    pub const senders = everyone;

    id: ProjectId,
};

/// The order of the children of `parent` (the top level when null).
pub const ProjectOrder = struct {
    pub const name = "project.order";
    pub const since = 3;
    pub const senders = everyone;

    parent: ?ProjectId = null,
    ids: []const ProjectId,
};

/// A tab was made or changed: the whole tab with its tree.
pub const TabChanged = struct {
    pub const name = "tab.set";
    pub const since = 3;
    pub const senders = everyone;

    workspace: WorkspaceId,
    tab: model.Tab,
    zoomed: ?PaneId = null,
};

pub const TabRemoved = struct {
    pub const name = "tab.remove";
    pub const since = 3;
    pub const senders = everyone;

    workspace: WorkspaceId,
    id: TabId,
};

/// A workspace was made, or its tabs, their order or its active tab
/// changed.
pub const TabOrder = struct {
    pub const name = "tab.order";
    pub const since = 3;
    pub const senders = everyone;

    workspace: WorkspaceId,
    kind: model.Kind,
    ids: []const TabId,
    active_tab: ?TabId = null,
};

/// A workspace that is not a project's was removed.
pub const WorkspaceRemoved = struct {
    pub const name = "workspace.remove";
    pub const since = 3;
    pub const senders = everyone;

    id: WorkspaceId,
};

pub const SelectionChanged = struct {
    pub const name = "selection";
    pub const since = 3;
    pub const senders = everyone;

    active_project: ?ProjectId = null,
};

/// A pane left the model (`RemovedPane`).
pub const PaneRemoved = struct {
    pub const name = "pane.removed";
    pub const since = 3;
    pub const senders = everyone;

    id: PaneId,
    session: []const u8,
    host: ?[]const u8 = null,
};

pub const events = .{
    SessionExit, PaneAttention,    ProjectChanged,   ProjectRemoved, ProjectOrder, TabChanged, TabRemoved,
    TabOrder,    WorkspaceRemoved, SelectionChanged, PaneRemoved,
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

    /// The session process.
    pid: i64,
    /// The shell (or the command) that the session started. Its parent is
    /// the session, so the session reads its exit status.
    shell_pid: i64,
    /// The path of the pty's slave side. Not UTF-8 on every system.
    pty: msgpack.Bin,
    cols: u16,
    rows: u16,
    /// The clients that sent `attach`. The session sends `state` again to
    /// its other connections (the server's) each time this count changes.
    clients: ?u16 = null,
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
    /// The client wants `foreground` messages. The session reads the pty's
    /// foreground only while a client that asked for them is connected.
    foreground: bool = false,
    /// The client wants `tty_mode` messages. The session reads the pty's line
    /// modes only while a client that asked for them is connected.
    tty: bool = false,
    /// A client that lost its link asks to resume (design/003 §7): the
    /// `epoch` of the session's `hello` and the offset after the last output
    /// byte that it got. If the session still holds the output after that
    /// offset, it answers with `Resumed` and the missing bytes, and no
    /// snapshot. Otherwise it sends a snapshot. Both fields or none.
    resume_epoch: ?u64 = null,
    resume_offset: ?u64 = null,

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
};

/// The `bytes` frames up to `SnapshotEnd` are a snapshot of the terminal,
/// not output. `scrollback` is false for a snapshot after dropped output:
/// it holds the screen only, and clears the old screen first.
pub const SnapshotStart = struct {
    pub const name = "snapshot.start";
    pub const since = 1;
    pub const senders = from_session;

    scrollback: bool,
    /// The output offset that the screen in this snapshot shows: the output
    /// bytes that follow it start here. A client that counts the output
    /// bytes it gets takes this as its offset (`Attach.resume_offset`).
    offset: ?u64 = null,

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

    /// The offset of the first byte that follows. The client's own offset.
    offset: u64,
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

    /// The exit code, when the shell exited.
    code: ?u8 = null,
    /// The signal number, when a signal ended the shell.
    signal: ?u8 = null,
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

    /// As the program sent it. Not UTF-8 on every program.
    title: msgpack.Bin,
};

/// The working directory that the shell reports (OSC 7).
pub const Cwd = struct {
    pub const name = "cwd";
    pub const since = 1;
    pub const senders = from_session;

    /// The OSC 7 payload as the shell sent it: usually a `file://` URL,
    /// percent-encoded. The receiver decodes it.
    url: msgpack.Bin,
};

/// The process group that holds the pty (zmx 0010). Sent when the group or
/// its leader's name changes, and to a client that connects or catches up.
pub const Foreground = struct {
    pub const name = "foreground";
    pub const since = 1;
    pub const senders = from_session;

    /// The group is the session's own shell.
    idle: bool,
    /// `comm` is in the host's `/etc/shells`. Null when the host has none.
    shell: ?bool = null,
    /// The process name: the executable path on macOS, the kernel `comm` on
    /// Linux.
    comm: msgpack.Bin,
    /// The command line, its arguments joined by spaces.
    args: msgpack.Bin,
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

    kind: MarkKind,
    /// For `output` and `end`: the command line. The shell's own text when
    /// it sent one, else the input cells of the prompt. Null when there is
    /// neither.
    command: ?msgpack.Bin = null,
    /// For `end`: the exit code, when the shell sent one.
    exit_code: ?i32 = null,
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
    /// 0 to 100, when the program sent one.
    percent: ?u8 = null,
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

/// The pane's run, derived from the marks and the progress reports only:
/// `running` from OSC 133;C or a progress report that sets work, `done` from
/// OSC 133;D or a report that ends it. A shell with no integration and a
/// program with no progress report stay `idle`.
pub const Status = struct {
    pub const name = "status";
    pub const since = 1;
    pub const senders = from_session;

    state: RunState,
    /// With `done`: a progress report said error (v1's red dot). The exit
    /// code does not count: it judges the command, not the run.
    failed: bool = false,
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

    /// A run ended, or the bell rang, and no client showed the pane since.
    unseen: bool = false,
    /// With `unseen`: the ended run failed (`Status.failed`).
    failed: bool = false,
    /// The bell rang and no client showed the pane since.
    bell: bool = false,
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
    /// The record's id: names joined by `/`, where `a/b` is a child of `a`.
    /// Empty for the root record, which is the program itself.
    id: []const u8 = "",
    state: ProgramState,
    /// With `blocked`: what the program needs.
    kind: ?ProgramNeed = null,
    /// With `working` or `blocked`: 0 to 100. Null when the program gave
    /// none.
    progress: ?u8 = null,
    /// A stable name for the program (`cargo`, `claude-code`). A record that
    /// gave none has the `app` of its nearest ancestor that gave one, the
    /// root record included.
    app: ?[]const u8 = null,
    /// A short label for the record, decoded. UTF-8 with no control
    /// characters; still the program's text.
    title: ?[]const u8 = null,
    /// One line that says what the record does or waits for, decoded. As
    /// `title`.
    msg: ?[]const u8 = null,
};

/// Every record of the program status protocol (OSC 7501) that the pane
/// holds now, oldest first. Each change sends all of them, so an empty list
/// clears them all. It coalesces as the title does.
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
};

/// The most records that a pane keeps (the protocol requires 64 or more).
pub const max_program_records = 64;

/// Every message on a pane channel. A new one goes here.
pub const pane_messages = .{
    State,   Attach,  Resize,     Claim, Lead,     SnapshotStart, SnapshotEnd, Exit,   Take,          End,       Refresh,
    Title,   Cwd,     Foreground, Mark,  Progress, Bell,          Activity,    Status, ProgramStatus, Attention, Seen,
    Resumed, TtyMode,
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
