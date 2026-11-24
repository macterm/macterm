//! The session's own events (design/003 §5, design/004 §6).
//!
//! `Watch` holds the session's terminal and listens to what the terminal
//! parses: the title, the cwd, the OSC 133 marks, the OSC 9;4 progress,
//! the OSC 7501 program status and the bell. It coalesces them (the rules are on `messages.coalesce_ms`),
//! derives the run status, and keeps the events in `ready`, in order, until
//! the session sends them. The foreground is the session's: it reads the pty,
//! not the terminal.
//!
//! Nothing here reads a clock: each call takes the time in milliseconds, so
//! the tests drive time by hand.

const std = @import("std");
const terminal = @import("terminal.zig");
const util = @import("util.zig");
const protocol = @import("protocol/protocol.zig");
const ghostty_vt = terminal.ghostty_vt;
const m = protocol.messages;

const Handler = ghostty_vt.TerminalStream.Handler;
const SemanticPrompt = Handler.SemanticPrompt;
const SemanticContent = ghostty_vt.Cell.SemanticContent;
const ProgressReport = ghostty_vt.osc.Command.ProgressReport;
const ProgramStatus = ghostty_vt.osc.Command.ProgramStatus;
const program_status = ghostty_vt.osc.program_status;

/// One event that waits to go out. The slices belong to the `Watch`.
pub const Event = union(enum) {
    title: []const u8,
    cwd: []const u8,
    mark: struct { kind: m.MarkKind, command: ?[]const u8 = null, exit_code: ?i32 = null, output_tail: ?[]const u8 = null },
    progress: m.Progress,
    bell,
    activity,
    status: m.Status,
    /// The flags that wait for a client to see them (`Watch.attention`).
    attention: m.Attention,
    /// Every program status record, from `Watch.programRecords`.
    program: []m.ProgramRecord,
};

/// The values that coalesce.
const Key = enum { title, cwd, progress, program, bell };

/// What started the run that runs now.
const RunSource = enum {
    /// OSC 133;C. 133;D or the next prompt ends it.
    mark,
    /// An OSC 9;4 report. Its end ends it.
    progress,
    /// A process group that took the foreground after a submission to a
    /// shell with no marks or to a program (a nested shell). The return of
    /// the shell, or of the group that took the submission, ends it.
    foreground,
    /// A submission to a program in raw mode, with output after it.
    agent,
};

/// Input that submits a line: a plain Return, as CR, as LF (`pane run`
/// submits with LF) or as a key press of the kitty keyboard protocol
/// (`CSI 13 u`, `CSI 13 ; 1 u`). A Return with a modifier (Shift+Enter adds
/// a line in an agent), a key release and a paste are not a submission.
pub fn isSubmission(data: []const u8) bool {
    if (std.mem.startsWith(u8, data, "\x1b[200~")) return false;
    if (std.mem.indexOfAny(u8, data, "\r\n") != null) return true;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, data, at, "\x1b[")) |i| {
        at = i + 2;
        if (std.mem.startsWith(u8, data[at..], "13u")) return true;
        const key = util.parseKittyCsiU(data[at..]) orelse continue;
        // Caps Lock and Num Lock (bits 64 and 128) are no modifier of the key.
        if (key.key_code == 13 and key.modifiers & ~@as(u32, 0xc0) == 0 and key.event_type != 3) return true;
    }
    return false;
}

/// The pty's foreground, as the session reads it.
pub const Foreground = struct {
    /// The shell's own group is in front.
    idle: bool = true,
    /// The tty is not in canonical mode: a full-screen program or an agent
    /// reads each key.
    raw: bool = false,
    /// The foreground process group, or 0 when not known.
    pgrp: i32 = 0,
};

/// A program that takes the foreground within this time after a submission
/// is the user's command.
pub const submit_window_ms = 2000;

/// A run with a raw program in front ends after this time with no output:
/// an agent finished its reply. Output that comes later than this after a
/// submission to a raw program does not start a run either: a reply that
/// sparse cannot be told from output that nobody asked for.
pub const quiet_ms = 3000;

/// Output in this time after a submission to a raw program starts no run:
/// it is the echo of the key, or the redraw of the input line.
pub const echo_ms = 250;

/// A program status record, and when it last changed.
const Record = struct {
    rec: m.ProgramRecord,
    changed: u64,
};

const Hold = struct {
    /// When the last one went out.
    sent_at: ?i64 = null,
    /// A newer one waits for the end of the window.
    held: bool = false,
};

pub const Watch = struct {
    gpa: std.mem.Allocator,
    term: ghostty_vt.Terminal,
    ready: std.ArrayList(Event) = .empty,
    /// The time of the bytes that the terminal parses now.
    now_ms: i64 = 0,
    holds: [std.enums.values(Key).len]Hold = @splat(.{}),
    activity_at: ?i64 = null,
    /// The last progress report; null after `remove`.
    progress: ?m.Progress = null,
    status: m.Status = .{ .state = .idle },
    /// What the user did not see yet. A run that ends and the bell set it,
    /// a new run clears `unseen` and `failed`, and `seen` clears it all.
    attention: m.Attention = .{},
    run_by: RunSource = .mark,
    /// A primary prompt mark came: the marks own the runs of the shell's
    /// commands, and a submission to the shell arms no foreground run.
    has_marks: bool = false,
    fg: Foreground = .{},
    /// A submission to the group in front (`fg_armed_pgrp`): the shell with
    /// no marks, or a program (a nested shell) that the marks do not cover.
    fg_armed_at: ?i64 = null,
    fg_armed_pgrp: i32 = 0,
    /// The group that took the submission of a `.foreground` run: the run
    /// ends when it is in front again.
    fg_owner: i32 = 0,
    /// A submission to a raw program, with no reply yet.
    agent_armed_at: ?i64 = null,
    /// The last output, or the start of the run or of raw mode when later.
    quiet_from: i64 = 0,
    /// The command that runs now, for its `end` mark.
    command: ?[]u8 = null,
    /// Where the cursor was at the command's output mark, tracked on the
    /// primary screen (never removed) so that it follows its row as the
    /// output scrolls. Null when the command did not start there.
    output_start: ?*ghostty_vt.Pin = null,
    /// An input mark came, and no output or end mark since: the input
    /// cells above the cursor are the user's command.
    at_input: bool = false,
    /// The program status records (OSC 7501), oldest first. Their slices
    /// belong to the watch.
    records: std.ArrayList(Record) = .empty,
    /// Counts the record changes, to find the least recently changed one.
    record_seq: u64 = 0,
    /// Bytes for the pty: the terminal's replies to queries.
    reply: std.ArrayList(u8) = .empty,
    /// No client leads, so no terminal of a client answers the queries: the
    /// session's terminal answers every query. While a client leads, it
    /// answers only the OSC 7501 support query (`onWritePty`).
    answers_all: bool = true,

    pub fn init(gpa: std.mem.Allocator, term: ghostty_vt.Terminal) Watch {
        return .{ .gpa = gpa, .term = term };
    }

    pub fn deinit(w: *Watch) void {
        w.clearReady();
        w.ready.deinit(w.gpa);
        if (w.command) |c| w.gpa.free(c);
        w.setOutputStart(false);
        for (w.records.items) |r| freeRecord(w.gpa, r.rec);
        w.records.deinit(w.gpa);
        w.reply.deinit(w.gpa);
        w.term.deinit(w.gpa);
    }

    /// Connects the terminal's effects to this watch. `handler` must parse
    /// into `w.term`, and `w` must not move after this.
    pub fn install(w: *Watch, handler: *Handler) void {
        std.debug.assert(handler.terminal == &w.term);
        handler.effects.title_changed = &onTitle;
        handler.effects.pwd_changed = &onPwd;
        handler.effects.bell = &onBell;
        handler.effects.progress_report = &onProgress;
        handler.effects.semantic_prompt = &onSemanticPrompt;
        handler.effects.reset = &onReset;
        // Also makes the terminal answer the OSC 7501 support query.
        handler.effects.program_status = &onProgramStatus;
        handler.effects.write_pty = &onWritePty;
        handler.effects.device_attributes = &onDeviceAttributes;
    }

    /// Parses pty output at time `now`.
    pub fn feed(w: *Watch, stream: anytype, data: []const u8, now: i64) void {
        w.now_ms = now;
        stream.nextSlice(data);
        if (data.len == 0) return;
        w.quiet_from = @max(w.quiet_from, now);
        w.agentOutput(now);
        if (w.activity_at) |at| if (now - at < m.activity_ms) return;
        w.activity_at = now;
        w.push(.activity);
    }

    /// The user submitted input (`isSubmission`) at `now`. The session
    /// reads the foreground first.
    pub fn submitted(w: *Watch, now: i64) void {
        w.now_ms = now;
        // The marks are the session shell's: a nested shell (sh from zsh)
        // sends none, so a submission to it arms the foreground rule too.
        if (!w.fg.idle or !w.has_marks) {
            w.fg_armed_at = now;
            w.fg_armed_pgrp = w.fg.pgrp;
        }
        if (!w.fg.idle and w.fg.raw) w.agent_armed_at = now;
    }

    /// The session read the foreground at `now`.
    ///
    /// - The shell's return ends a run that the foreground or an agent
    ///   started. The return of the group that took the submission ends a
    ///   `.foreground` run: a nested shell is back at its prompt.
    /// - Another group that takes the foreground within `submit_window_ms`
    ///   of a submission starts a run. The session shell with marks does
    ///   not arm it (`submitted`): it sends 133;C for the command, and its
    ///   prompt hooks take the foreground with no submission.
    pub fn foreground(w: *Watch, next: Foreground, now: i64) void {
        w.now_ms = now;
        const was = w.fg;
        w.fg = next;
        if (next.idle) {
            w.agent_armed_at = null;
            // The program that took the submission ended: a prompt hook
            // that takes the foreground next is not its command.
            if (!was.idle) w.fg_armed_at = null;
            if (!was.idle and w.status.state == .running and (w.run_by == .foreground or w.run_by == .agent))
                w.setStatus(.done, false);
            return;
        }
        if (w.status.state == .running and w.run_by == .foreground and w.fg_owner != 0 and
            next.pgrp == w.fg_owner and was.pgrp != w.fg_owner)
        {
            w.setStatus(.done, false);
        } else if (w.fg_armed_at) |at| {
            // A group of 0 is not known: then only the shell's leave counts.
            const moved = if (next.pgrp != 0 and w.fg_armed_pgrp != 0) next.pgrp != w.fg_armed_pgrp else was.idle;
            if (moved) {
                // The submission was a command: the output after it is not
                // the reply of an agent.
                w.fg_armed_at = null;
                w.agent_armed_at = null;
                if (now - at < submit_window_ms and w.status.state != .running) {
                    w.startRun(.foreground);
                    w.fg_owner = w.fg_armed_pgrp;
                }
            }
        }
        if (next.raw and !(was.raw and !was.idle)) w.quiet_from = @max(w.quiet_from, now);
    }

    /// The session must read the foreground on a timer: a program that
    /// prints nothing can take the foreground after a submission.
    pub fn watchesForeground(w: *const Watch, now: i64) bool {
        const at = w.fg_armed_at orelse return false;
        return now - at < submit_window_ms;
    }

    /// Output from `echo_ms` to `quiet_ms` after a submission to a raw
    /// program starts a run: the program replies.
    fn agentOutput(w: *Watch, now: i64) void {
        const at = w.agent_armed_at orelse return;
        if (now - at >= quiet_ms or w.fg.idle or !w.fg.raw) {
            w.agent_armed_at = null;
            return;
        }
        if (now - at < echo_ms) return;
        w.agent_armed_at = null;
        w.startRun(.agent);
    }

    /// When a run with a raw program in front ends for quiet output, or
    /// null. A run that progress started ends at its report.
    fn quietDeadline(w: *const Watch) ?i64 {
        if (w.status.state != .running or w.run_by == .progress) return null;
        if (w.fg.idle or !w.fg.raw) return null;
        return w.quiet_from + quiet_ms;
    }

    /// Sends the held values whose window ended by `now`.
    pub fn flush(w: *Watch, now: i64) void {
        w.now_ms = now;
        for (&w.holds, 0..) |*h, i| {
            if (!h.held or now - h.sent_at.? < m.coalesce_ms) continue;
            h.held = false;
            h.sent_at = now;
            w.emit(@enumFromInt(i));
        }
        if (w.quietDeadline()) |due| if (now >= due) w.setStatus(.done, false);
    }

    /// When the next held value is due, or null when none waits.
    pub fn deadline(w: *const Watch) ?i64 {
        var next: ?i64 = w.quietDeadline();
        for (w.holds) |h| {
            if (!h.held) continue;
            const due = h.sent_at.? + m.coalesce_ms;
            next = if (next) |n| @min(n, due) else due;
        }
        return next;
    }

    /// The events that tell a new client the current state, into `out`.
    /// The slices belong to the terminal and stay valid until it parses,
    /// except the `program` records: free them with `freeProgram`.
    pub fn current(w: *Watch, out: *std.ArrayList(Event)) !void {
        if (w.term.getTitle()) |t| if (t.len > 0) try out.append(w.gpa, .{ .title = t });
        if (w.term.getPwd()) |p| if (p.len > 0) try out.append(w.gpa, .{ .cwd = p });
        if (w.progress) |p| try out.append(w.gpa, .{ .progress = p });
        if (w.status.state != .idle) try out.append(w.gpa, .{ .status = w.status });
        // The shell waits for input (after 133;B, before 133;C). A client
        // that greets after the mark learns it here: `PaneSession` holds
        // its first input until then.
        if (w.at_input) try out.append(w.gpa, .{ .mark = .{ .kind = .input } });
        if (w.attention.unseen or w.attention.bell) try out.append(w.gpa, .{ .attention = w.attention });
        if (w.records.items.len > 0) {
            const records = try w.programRecords();
            out.append(w.gpa, .{ .program = records }) catch |err| {
                freeProgram(w.gpa, records);
                return err;
            };
        }
    }

    /// Frees the events that went out.
    pub fn clearReady(w: *Watch) void {
        for (w.ready.items) |e| freeEvent(w.gpa, e);
        w.ready.clearRetainingCapacity();
    }

    fn push(w: *Watch, e: Event) void {
        w.ready.append(w.gpa, e) catch {
            std.log.warn("event dropped: out of memory", .{});
            freeEvent(w.gpa, e);
        };
    }

    /// The first value in a quiet period goes at once; later ones wait for
    /// the end of the window, where the newest goes.
    fn coalesce(w: *Watch, key: Key) void {
        const h = &w.holds[@intFromEnum(key)];
        if (h.sent_at) |at| if (w.now_ms - at < m.coalesce_ms) {
            h.held = true;
            return;
        };
        h.sent_at = w.now_ms;
        h.held = false;
        w.emit(key);
    }

    fn emit(w: *Watch, key: Key) void {
        switch (key) {
            .title => w.pushCopy(.title, w.term.getTitle() orelse ""),
            .cwd => w.pushCopy(.cwd, w.term.getPwd() orelse ""),
            .progress => w.push(.{ .progress = w.progress orelse .{ .state = .remove } }),
            .program => w.push(.{ .program = w.programRecords() catch return }),
            .bell => w.push(.bell),
        }
    }

    fn pushCopy(w: *Watch, comptime tag: std.meta.Tag(Event), value: []const u8) void {
        const copy = w.gpa.dupe(u8, value) catch return;
        w.push(@unionInit(Event, @tagName(tag), copy));
    }

    fn setStatus(w: *Watch, state: m.RunState, failed: bool) void {
        if (w.status.state == state and w.status.failed == failed) return;
        w.status = .{ .state = state, .failed = failed };
        w.push(.{ .status = w.status });
        switch (state) {
            .done => w.setAttention(.{ .unseen = true, .failed = failed, .bell = w.attention.bell }),
            .running => w.setAttention(.{ .bell = w.attention.bell }),
            else => {},
        }
    }

    fn setAttention(w: *Watch, next: m.Attention) void {
        if (std.meta.eql(w.attention, next)) return;
        w.attention = next;
        w.push(.{ .attention = next });
    }

    /// A client showed the pane to the user. Pushes the flags also when they
    /// were clear, so that the client that asked gets its answer.
    pub fn seen(w: *Watch) void {
        w.attention = .{};
        w.push(.{ .attention = w.attention });
    }

    fn startRun(w: *Watch, source: RunSource) void {
        if (w.status.state == .running) return;
        w.run_by = source;
        w.quiet_from = w.now_ms;
        w.setStatus(.running, false);
    }

    fn mark(w: *Watch, e: SemanticPrompt) void {
        switch (e.kind) {
            .prompt_start => {
                // A continuation or right prompt is part of the same prompt.
                if (e.prompt_kind != .primary) return;
                w.has_marks = true;
                w.fg_armed_at = null;
                w.at_input = false;
                w.endPromptRecords();
                // A new prompt ends the command, also when the shell sent no
                // 133;D (after a full reset, for one).
                if (w.status.state == .running and w.run_by != .progress) {
                    w.setCommand(null);
                    w.setOutputStart(false);
                    w.setStatus(.done, false);
                }
                w.push(.{ .mark = .{ .kind = .prompt } });
            },
            .input_start => {
                w.at_input = true;
                w.push(.{ .mark = .{ .kind = .input } });
            },
            .output_start => {
                // A 133;C with no input mark before it (in a file that
                // `cat` prints) has no command to read.
                const command = if (e.command.len > 0)
                    w.gpa.dupe(u8, e.command) catch null
                else if (w.at_input)
                    inputText(w.gpa, &w.term)
                else
                    null;
                w.at_input = false;
                w.setCommand(command);
                w.setOutputStart(true);
                w.push(.{ .mark = .{ .kind = .output, .command = w.dupeCommand() } });
                w.startRun(.mark);
                // The command owns the run now: a progress report that
                // started it does not end it.
                w.run_by = .mark;
            },
            .command_end => {
                w.at_input = false;
                // Only a failure carries its output: the app keeps the tail
                // of a failed command, and nothing else reads it.
                const failed = if (e.exit_code) |code| code != 0 else false;
                w.push(.{ .mark = .{
                    .kind = .end,
                    .command = w.dupeCommand(),
                    .exit_code = e.exit_code,
                    .output_tail = if (failed) w.outputTail() else null,
                } });
                w.setOutputStart(false);
                w.setCommand(null);
                if (w.status.state == .running) w.setStatus(.done, false);
            },
            else => {},
        }
    }

    /// Drops the output start, and with `at_cursor` tracks a new one at the
    /// cursor of the primary screen.
    fn setOutputStart(w: *Watch, at_cursor: bool) void {
        const pages = &w.term.screens.get(.primary).?.pages;
        if (w.output_start) |p| pages.untrackPin(p);
        w.output_start = null;
        if (!at_cursor or w.term.screens.active_key != .primary) return;
        w.output_start = pages.trackPin(w.term.screens.active.cursor.page_pin.*) catch null;
    }

    /// The text of the output cells from the output mark to the cursor, at
    /// most the last `output_tail_rows` rows: the end of what the command
    /// printed, a line for each row that does not wrap. Read at the
    /// command's end mark, before the shell prints its next prompt, so what
    /// comes after the end (a `clear`, the next command) does not change it.
    /// Null when the command did not start on the primary screen, the
    /// primary screen is not active now, the cursor is above the start (the
    /// command moved it there, as a `clear` inside it does), or the command
    /// printed nothing.
    fn outputTail(w: *Watch) ?[]u8 {
        const start_pin = w.output_start orelse return null;
        if (w.term.screens.active_key != .primary) return null;
        const cursor = w.term.screens.active.cursor.page_pin.*;
        const top = switch (cursor.upOverflow(output_tail_rows - 1)) {
            .offset => |p| p,
            .overflow => |o| o.end,
        }.left(cursor.x);
        // A start above `top` is long output. A start after the cursor is a
        // command that moved the cursor up past its start: the rows above
        // are not known to be its output.
        const start = if (start_pin.isBetween(top, cursor))
            start_pin.*
        else if (cursor.before(start_pin.*))
            return null
        else
            top;
        return cellText(w.gpa, start, cursor, .output);
    }

    fn setCommand(w: *Watch, command: ?[]u8) void {
        if (w.command) |c| w.gpa.free(c);
        w.command = command;
    }

    fn dupeCommand(w: *Watch) ?[]const u8 {
        const c = w.command orelse return null;
        return w.gpa.dupe(u8, c) catch null;
    }

    fn report(w: *Watch, r: ProgressReport) void {
        const state: m.ProgressState = switch (r.state) {
            .remove => .remove,
            .set => .set,
            .@"error" => .@"error",
            .indeterminate => .indeterminate,
            .pause => .pause,
        };
        w.progress = if (state == .remove) null else .{ .state = state, .percent = r.progress };
        w.coalesce(.progress);
        switch (state) {
            .set, .indeterminate => w.startRun(.progress),
            // v1's rule: error ends the run as a failure, whatever started it.
            .@"error" => if (w.status.state == .running) w.setStatus(.done, true),
            // Remove and pause end only a run that a report started: a
            // command that 133;C started ends at 133;D.
            .remove, .pause => if (w.status.state == .running and w.run_by == .progress) w.setStatus(.done, false),
            .unknown => {},
        }
    }

    /// Applies one report: a `clear` removes the record and the records
    /// under it (every record with no id), any other state replaces the
    /// record.
    fn programReport(w: *Watch, r: ProgramStatus.Report) void {
        const id = r.readOption(.id) orelse "";
        if (r.state == .clear) {
            if (!w.removeRecords(id, .clear)) return;
        } else {
            w.putRecord(id, r) catch {
                std.log.warn("program status dropped: out of memory", .{});
                return;
            };
        }
        w.coalesce(.program);
    }

    fn putRecord(w: *Watch, id: []const u8, r: ProgramStatus.Report) !void {
        var rec: m.ProgramRecord = .{
            .state = switch (r.state) {
                .idle => .idle,
                .working => .working,
                .done => .done,
                .blocked => .blocked,
                .@"error" => .@"error",
                .clear => unreachable,
            },
            .kind = if (r.readOption(.kind)) |k| switch (k) {
                .permission => .permission,
                .question => .question,
                .auth => .auth,
            } else null,
            .progress = r.readOption(.progress),
        };
        errdefer freeRecord(w.gpa, rec);
        rec.id = try w.gpa.dupe(u8, id);
        if (r.readOption(.app)) |a| rec.app = try w.gpa.dupe(u8, a);
        rec.title = try decodeText(w.gpa, r, .title);
        rec.msg = try decodeText(w.gpa, r, .msg);

        w.record_seq += 1;
        for (w.records.items) |*old| if (std.mem.eql(u8, old.rec.id, id)) {
            freeRecord(w.gpa, old.rec);
            old.* = .{ .rec = rec, .changed = w.record_seq };
            return;
        };
        try w.records.ensureUnusedCapacity(w.gpa, 1);
        if (w.records.items.len >= m.max_program_records) {
            var oldest: usize = 0;
            for (w.records.items, 0..) |o, i| {
                if (o.changed < w.records.items[oldest].changed) oldest = i;
            }
            freeRecord(w.gpa, w.records.orderedRemove(oldest).rec);
        }
        w.records.appendAssumeCapacity(.{ .rec = rec, .changed = w.record_seq });
    }

    const Removal = enum {
        /// The record `id` and the records under it; every record for "".
        clear,
        /// The records of a program that no longer runs.
        ended,
    };

    /// True if a record went.
    fn removeRecords(w: *Watch, id: []const u8, how: Removal) bool {
        var removed = false;
        var i: usize = 0;
        while (i < w.records.items.len) {
            const rec = w.records.items[i].rec;
            const goes = switch (how) {
                .clear => id.len == 0 or (std.mem.startsWith(u8, rec.id, id) and
                    (rec.id.len == id.len or rec.id[id.len] == '/')),
                // `working` and `blocked` must go at a new shell prompt and
                // when the shell exits; `idle` may, and goes, so that no record outlives its
                // program. `done` and `error` wait for the user.
                .ended => rec.state != .done and rec.state != .@"error",
            };
            if (!goes) {
                i += 1;
                continue;
            }
            freeRecord(w.gpa, w.records.orderedRemove(i).rec);
            removed = true;
        }
        return removed;
    }

    fn endPromptRecords(w: *Watch) void {
        if (w.removeRecords("", .ended)) w.coalesce(.program);
    }

    /// The shell exited: the records of the program that ran go, with no
    /// hold, so that the event goes before the exit.
    pub fn shellExited(w: *Watch, now: i64) void {
        w.now_ms = now;
        if (!w.removeRecords("", .ended)) return;
        w.holds[@intFromEnum(Key.program)] = .{ .sent_at = now };
        w.emit(.program);
    }

    /// A copy of every record, with the `app` that each one inherits.
    fn programRecords(w: *Watch) ![]m.ProgramRecord {
        const out = try w.gpa.alloc(m.ProgramRecord, w.records.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| freeRecord(w.gpa, r);
            w.gpa.free(out);
        }
        for (w.records.items) |r| {
            const app = w.inheritedApp(r.rec.id);
            out[n] = try dupeRecord(w.gpa, r.rec, app);
            n += 1;
        }
        return out;
    }

    /// The `app` of the record `id`, else of its nearest ancestor that has
    /// one. The root record is the ancestor of every other record.
    fn inheritedApp(w: *const Watch, id: []const u8) ?[]const u8 {
        var at: ?[]const u8 = id;
        while (at) |path| {
            for (w.records.items) |r| if (std.mem.eql(u8, r.rec.id, path)) {
                if (r.rec.app) |a| return a;
                break;
            };
            at = if (path.len == 0)
                null
            else if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash|
                path[0..slash]
            else
                "";
        }
        return null;
    }

    fn fromHandler(h: *Handler) *Watch {
        return @fieldParentPtr("term", h.terminal);
    }

    fn onTitle(h: *Handler) void {
        fromHandler(h).coalesce(.title);
    }

    fn onPwd(h: *Handler) void {
        fromHandler(h).coalesce(.cwd);
    }

    fn onBell(h: *Handler) void {
        const w = fromHandler(h);
        var next = w.attention;
        next.bell = true;
        w.setAttention(next);
        w.coalesce(.bell);
    }

    fn onProgress(h: *Handler, r: ProgressReport) void {
        fromHandler(h).report(r);
    }

    fn onProgramStatus(h: *Handler, r: ProgramStatus.Report) void {
        fromHandler(h).programReport(r);
    }

    /// Keeps the replies to the queries. Some programs wait for a reply:
    /// fish waits 10 s for DA1.
    ///
    /// - While a client leads, keeps only the OSC 7501 support reply. The
    ///   leader's terminal answers every other query, and a second answer
    ///   would reach the program as input. That terminal does not answer
    ///   this one.
    /// - While no client leads, keeps every reply but the OSC color reports
    ///   and the kitty graphics replies. The session does not know the
    ///   app's colors, and the images are not the session's.
    fn onWritePty(h: *Handler, data: []const u8) void {
        const w = fromHandler(h);
        if (!std.mem.startsWith(u8, data, "\x1b]7501;")) {
            if (!w.answers_all) return;
            if (std.mem.startsWith(u8, data, "\x1b]") or std.mem.startsWith(u8, data, "\x1b_")) return;
        }
        w.reply.appendSlice(w.gpa, data) catch {};
    }

    /// The device attributes of Ghostty, which the app's terminal reports:
    /// a program sees the same terminal with a client and without one.
    fn onDeviceAttributes(_: *Handler) ghostty_vt.device_attributes.Attributes {
        return .{ .secondary = .{ .firmware_version = 10 } };
    }

    fn onSemanticPrompt(h: *Handler, e: SemanticPrompt) void {
        fromHandler(h).mark(e);
    }

    /// A full reset clears the title and the cwd with no callback. The run
    /// ends at the next 133;D or prompt. The terminal cleared the program
    /// status records before this, through `onProgramStatus`.
    fn onReset(h: *Handler) void {
        const w = fromHandler(h);
        w.coalesce(.title);
        w.coalesce(.cwd);
    }
};

fn freeEvent(gpa: std.mem.Allocator, e: Event) void {
    switch (e) {
        .title, .cwd => |s| gpa.free(s),
        .mark => |mk| {
            if (mk.command) |c| gpa.free(c);
            if (mk.output_tail) |t| gpa.free(t);
        },
        .program => |records| freeProgram(gpa, records),
        else => {},
    }
}

/// Frees the records of a `program` event.
pub fn freeProgram(gpa: std.mem.Allocator, records: []m.ProgramRecord) void {
    for (records) |r| freeRecord(gpa, r);
    gpa.free(records);
}

fn freeRecord(gpa: std.mem.Allocator, r: m.ProgramRecord) void {
    gpa.free(r.id);
    if (r.app) |a| gpa.free(a);
    if (r.title) |t| gpa.free(t);
    if (r.msg) |t| gpa.free(t);
}

/// A copy of `r` that owns its slices, with `app` in place of its own.
fn dupeRecord(gpa: std.mem.Allocator, r: m.ProgramRecord, app: ?[]const u8) !m.ProgramRecord {
    var out: m.ProgramRecord = .{ .state = r.state, .kind = r.kind, .progress = r.progress };
    errdefer freeRecord(gpa, out);
    out.id = try gpa.dupe(u8, r.id);
    if (app) |a| out.app = try gpa.dupe(u8, a);
    if (r.title) |t| out.title = try gpa.dupe(u8, t);
    if (r.msg) |t| out.msg = try gpa.dupe(u8, t);
    return out;
}

/// The decoded text of `title` or `msg`, or null when the report has none.
fn decodeText(gpa: std.mem.Allocator, r: ProgramStatus.Report, comptime key: ProgramStatus.Option) !?[]u8 {
    if (r.readOption(key) == null) return null;
    var buf: [program_status.max_msg_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    r.writeText(key, &writer) catch unreachable;
    return try gpa.dupe(u8, writer.buffered());
}

/// The most rows above the cursor that `inputText` reads.
pub const max_input_rows = 100;

/// The text of the input cells from the prompt above the cursor to the
/// cursor: what the user typed, with no prompt text, a line for each row
/// that does not wrap. Null when no prompt starts in the `max_input_rows`
/// above the cursor, or when there is no input.
///
/// Not `PageList.highlightSemanticContent`: it ends the input at the first
/// output cell, and the empty cells after the first row of a command that
/// spans rows are output cells.
pub fn inputText(gpa: std.mem.Allocator, term: *ghostty_vt.Terminal) ?[]u8 {
    const screen = term.screens.active;
    // With no prompt ever seen, the search below walks the whole screen.
    if (!screen.semantic_prompt.seen) return null;
    const cursor = screen.cursor.page_pin.*;
    var prompts = cursor.promptIterator(.left_up, cursor.up(max_input_rows));
    const prompt = prompts.next() orelse return null;

    return cellText(gpa, prompt, cursor, .input);
}

/// The most rows that `Watch.outputTail` reads, the cursor's row with them.
pub const output_tail_rows = 20;

/// The text of the cells with `content` from `start` to `end`, a line for
/// each row that does not wrap, with no spaces at the ends of the rows and
/// no blank lines at the ends. Null when there is no such text.
fn cellText(gpa: std.mem.Allocator, start: ghostty_vt.Pin, end: ghostty_vt.Pin, content: SemanticContent) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var cells = start.cellIterator(.right_down, end);
    var last: ?ghostty_vt.Pin = null;
    while (cells.next()) |p| {
        if (last) |l| if (l.node != p.node or l.y != p.y) {
            // A space at the end of a row that wraps is part of the text.
            if (!l.rowAndCell().row.wrap) {
                trimEndSpaces(&out);
                out.append(gpa, '\n') catch return null;
            }
        };
        last = p;
        const cell = p.rowAndCell().cell;
        if (cell.semantic_content != content) continue;
        if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
        if (!cell.hasText()) {
            out.append(gpa, ' ') catch return null;
            continue;
        }
        appendCodepoint(gpa, &out, cell.codepoint()) catch return null;
        if (cell.hasGrapheme()) if (p.grapheme(cell)) |cps| {
            for (cps) |cp| appendCodepoint(gpa, &out, cp) catch return null;
        };
    }
    const text = std.mem.trim(u8, out.items, " \n");
    if (text.len == 0) return null;
    return gpa.dupe(u8, text) catch null;
}

fn trimEndSpaces(out: *std.ArrayList(u8)) void {
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
}

fn appendCodepoint(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A watch on a small terminal, and a stream that parses into it.
const Fixture = struct {
    w: Watch,
    stream: ghostty_vt.TerminalStream,

    fn init(f: *Fixture) !void {
        f.w = .init(testing.allocator, try ghostty_vt.Terminal.init(testing.io, testing.allocator, .{ .cols = 40, .rows = 8 }));
        f.stream = f.w.term.vtStream();
        f.w.install(&f.stream.handler);
    }

    fn deinit(f: *Fixture) void {
        f.stream.deinit();
        f.w.deinit();
    }

    fn feed(f: *Fixture, data: []const u8, now: i64) void {
        f.w.feed(&f.stream, data, now);
    }

    /// The events that are ready, minus the heartbeat, as tags.
    fn tags(f: *Fixture) ![]std.meta.Tag(Event) {
        var out: std.ArrayList(std.meta.Tag(Event)) = .empty;
        for (f.w.ready.items) |e| if (e != .activity) try out.append(testing.allocator, e);
        return out.toOwnedSlice(testing.allocator);
    }

    fn only(f: *Fixture, comptime tag: std.meta.Tag(Event)) ![]@FieldType(Event, @tagName(tag)) {
        var out: std.ArrayList(@FieldType(Event, @tagName(tag))) = .empty;
        for (f.w.ready.items) |e| if (e == tag) try out.append(testing.allocator, @field(e, @tagName(tag)));
        return out.toOwnedSlice(testing.allocator);
    }
};

test "events: a title, a cwd and a bell go out at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]2;vim notes\x07\x1b]7;file://host/tmp/a%20b\x07\x07", 0);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(1, titles.len);
    try testing.expectEqualStrings("vim notes", titles[0]);
    const cwds = try f.only(.cwd);
    defer testing.allocator.free(cwds);
    try testing.expectEqualStrings("file://host/tmp/a%20b", cwds[0]);
    const tags = try f.tags();
    defer testing.allocator.free(tags);
    try testing.expectEqualSlices(std.meta.Tag(Event), &.{ .title, .cwd, .attention, .bell }, tags);
}

test "events: a title flood coalesces to the first and the newest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..1000) |i| f.feed(try std.fmt.bufPrint(&buf, "\x1b]0;title {d}\x07", .{i}), 3);
    try testing.expectEqual(3 + m.coalesce_ms, f.w.deadline().?);
    // Not yet: the window is still open.
    f.w.flush(3 + m.coalesce_ms - 1);
    var titles = try f.only(.title);
    try testing.expectEqual(1, titles.len);
    try testing.expectEqualStrings("title 0", titles[0]);
    testing.allocator.free(titles);

    f.w.flush(3 + m.coalesce_ms);
    titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqualStrings("title 999", titles[1]);
    try testing.expectEqual(null, f.w.deadline());
}

test "events: a title after a quiet window goes at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]2;a\x07", 0);
    f.feed("\x1b]2;b\x07", m.coalesce_ms);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqual(null, f.w.deadline());
}

test "events: the heartbeat goes once in its window and drops the rest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("a", 0);
    f.feed("b", 10);
    f.feed("c", m.activity_ms - 1);
    f.feed("d", m.activity_ms);
    var n: usize = 0;
    for (f.w.ready.items) |e| {
        if (e == .activity) n += 1;
    }
    try testing.expectEqual(2, n);
    try testing.expectEqual(null, f.w.deadline());
}

test "events: marks carry the command and the exit code, and the status follows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // A shell that sends no command line: the input cells give it.
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07make  test\r\n\x1b]133;C\x07", 0);
    f.feed("ok\r\n\x1b]133;D;2\x07", 1);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqual(4, marks.len);
    try testing.expectEqual(.prompt, marks[0].kind);
    try testing.expectEqual(.input, marks[1].kind);
    try testing.expectEqual(.output, marks[2].kind);
    try testing.expectEqualStrings("make  test", marks[2].command.?);
    try testing.expectEqual(.end, marks[3].kind);
    try testing.expectEqualStrings("make  test", marks[3].command.?);
    try testing.expectEqual(2, marks[3].exit_code.?);

    const statuses = try f.only(.status);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(2, statuses.len);
    try testing.expectEqual(.running, statuses[0].state);
    // A nonzero exit is not a failed run.
    try testing.expectEqual(m.Status{ .state = .done }, statuses[1]);
}

test "events: a failed command's end carries the end of its output" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07make\r\n\x1b]133;C\x07", 0);
    f.feed("one\r\nerror: two\r\n\x1b]133;D;2\x07", 1);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqual(.end, marks[3].kind);
    // No prompt text and no input: only what the command printed.
    try testing.expectEqualStrings("one\nerror: two", marks[3].output_tail.?);
}

test "events: a success, and output longer than the tail, keep only what they must" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07ok\r\n\x1b]133;C\x07done\r\n\x1b]133;D;0\x07", 0);
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07seq\r\n\x1b]133;C\x07", 1);
    var i: usize = 0;
    while (i < output_tail_rows + 5) : (i += 1) {
        var buf: [16]u8 = undefined;
        f.feed(try std.fmt.bufPrint(&buf, "{d}\r\n", .{i}), 1);
    }
    f.feed("\x1b]133;D;1\x07", 2);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqual(null, marks[3].output_tail);
    // The cursor's row and the 19 above it: the prompt scrolled out.
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    var n: usize = output_tail_rows + 5 - (output_tail_rows - 1);
    while (n < output_tail_rows + 5) : (n += 1) {
        if (want.items.len > 0) try want.append(testing.allocator, '\n');
        try want.print(testing.allocator, "{d}", .{n});
    }
    try testing.expectEqualStrings(want.items, marks[7].output_tail.?);
}

test "events: with no prompt marks, the tail starts at the output mark" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // bash 3.2 with no shell integration: a script sends 133;C and 133;D.
    f.feed("old output\r\n$ sh fail.sh\r\n\x1b]133;C;cmdline_url=sh%20fail.sh\x07rejected\r\n\x1b]133;D;1\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("rejected", marks[1].output_tail.?);
}

test "events: a command that moves the cursor above its start has no tail" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("older\r\n\x1b]133;A\x07$ \x1b]133;B\x07sh x\r\n\x1b]133;C\x07", 0);
    // The last row with text is output, so the erase is in place.
    f.feed("a\r\nb\r\n\x1b[H\x1b[2Jerror\r\n\x1b]133;D;1\x07", 1);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqual(null, marks[3].output_tail);
}

test "events: a prompt with no end mark drops the output start" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07make\r\n\x1b]133;C\x07out\r\n\x1b]133;A\x07$ ", 0);
    try testing.expectEqual(null, f.w.output_start);
}

test "events: the shell's own command line wins over the input cells" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C;cmdline_url=ls%20-la\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("ls -la", marks[2].command.?);
}

test "events: a command typed over two rows reads as two lines, without the continuation prompt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07echo a \\\r\n\x1b]133;P;k=c\x07> \x1b]133;B\x07b\r\n\x1b]133;C\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    // The continuation prompt is no `prompt` mark.
    try testing.expectEqual(.prompt, marks[0].kind);
    try testing.expectEqual(.input, marks[1].kind);
    try testing.expectEqual(.input, marks[2].kind);
    try testing.expectEqual(.output, marks[3].kind);
    try testing.expectEqualStrings("echo a \\\nb", marks[3].command.?);
}

test "events: an end with no command running changes no status" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;D;0\x07\x1b]133;A\x07$ ", 0);
    const statuses = try f.only(.status);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(0, statuses.len);
    try testing.expectEqual(.idle, f.w.status.state);
}

test "events: progress error ends the run as failed, and remove keeps it red" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]9;4;1;40\x07", 0);
    f.feed("\x1b]9;4;2\x07", 100);
    f.feed("\x1b]9;4;0\x07", 200);
    const statuses = try f.only(.status);
    defer testing.allocator.free(statuses);
    try testing.expectEqual(2, statuses.len);
    try testing.expectEqual(.running, statuses[0].state);
    try testing.expectEqual(m.Status{ .state = .done, .failed = true }, statuses[1]);
    const reports = try f.only(.progress);
    defer testing.allocator.free(reports);
    try testing.expectEqual(3, reports.len);
    try testing.expectEqual(m.Progress{ .state = .set, .percent = 40 }, reports[0]);
    try testing.expectEqual(.@"error", reports[1].state);
    try testing.expectEqual(.remove, reports[2].state);
    try testing.expectEqual(null, f.w.progress);
}

test "events: progress remove ends only a run that a report started" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07cargo build\r\n\x1b]133;C\x07", 0);
    f.feed("\x1b]9;4;3\x07", 100);
    f.feed("\x1b]9;4;0\x07", 200);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]133;D;0\x07", 300);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);

    // With no mark, set then remove is a whole run.
    f.feed("\x1b]9;4;1;5\x07", 400);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]9;4;0\x07", 500);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
}

test "events: a new client gets the current state" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    try f.w.current(&out);
    try testing.expectEqual(0, out.items.len);

    f.feed("\x1b]2;htop\x07\x1b]7;file:///srv\x07\x1b]9;4;1;70\x07", 0);
    try f.w.current(&out);
    try testing.expectEqual(4, out.items.len);
    try testing.expectEqualStrings("htop", out.items[0].title);
    try testing.expectEqualStrings("file:///srv", out.items[1].cwd);
    try testing.expectEqual(m.Progress{ .state = .set, .percent = 70 }, out.items[2].progress);
    try testing.expectEqual(.running, out.items[3].status.state);
}

test "events: a new client gets an input mark while the shell waits for input" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    // A shell that starts, or one with no marks.
    f.feed("Last login: today\r\n", 0);
    try f.w.current(&out);
    for (out.items) |e| try testing.expect(e != .mark);

    // The prompt is not drawn to its end yet.
    f.feed("\x1b]133;A\x07$ ", 10);
    out.clearRetainingCapacity();
    try f.w.current(&out);
    for (out.items) |e| try testing.expect(e != .mark);

    f.feed("\x1b]133;B\x07", 20);
    out.clearRetainingCapacity();
    try f.w.current(&out);
    var inputs: usize = 0;
    for (out.items) |e| if (e == .mark and e.mark.kind == .input) {
        inputs += 1;
    };
    try testing.expectEqual(1, inputs);

    // A command runs: the shell does not wait for input.
    f.feed("make\r\n\x1b]133;C\x07", 30);
    out.clearRetainingCapacity();
    try f.w.current(&out);
    for (out.items) |e| try testing.expect(e != .mark);
}

test "events: a full reset sends an empty title and cwd" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]2;x\x07\x1b]7;file:///a\x07", 0);
    f.feed("\x1bc", 100);
    const titles = try f.only(.title);
    defer testing.allocator.free(titles);
    try testing.expectEqual(2, titles.len);
    try testing.expectEqualStrings("", titles[1]);
    const cwds = try f.only(.cwd);
    defer testing.allocator.free(cwds);
    try testing.expectEqual(2, cwds.len);
    try testing.expectEqualStrings("", cwds[1]);
}

test "events: a new prompt ends a command that had no end mark" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07reset\r\n\x1b]133;C\x07\x1bc", 0);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]133;A\x07$ ", 100);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
}

test "events: an output mark with no input mark before it reads no command" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07cat log\r\n\x1b]133;C\x07", 0);
    // The file that `cat` prints holds marks of its own.
    f.feed("\x1b]133;C\x07old output\r\n", 1);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("cat log", marks[2].command.?);
    try testing.expectEqual(null, marks[3].command);
}

test "events: a command that wraps keeps the space at the end of the row" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // 40 columns: "$ " and 37 characters, then a space in the last column.
    f.feed("\x1b]133;A\x07$ \x1b]133;B\x07aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b\r\n\x1b]133;C\x07", 0);
    const marks = try f.only(.mark);
    defer testing.allocator.free(marks);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa b", marks[2].command.?);
}

test "events: an output mark after a progress report owns the run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]9;4;3\x07\x1b]133;A\x07$ \x1b]133;B\x07make\r\n\x1b]133;C\x07", 0);
    f.feed("\x1b]9;4;0\x07", 100);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("\x1b]133;D;0\x07", 200);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
}

/// The records of the last `program` event that is ready.
fn lastProgram(f: *Fixture) ?[]m.ProgramRecord {
    var last: ?[]m.ProgramRecord = null;
    for (f.w.ready.items) |e| if (e == .program) {
        last = e.program;
    };
    return last;
}

fn programEvents(f: *Fixture) usize {
    var n: usize = 0;
    for (f.w.ready.items) |e| n += @intFromBool(e == .program);
    return n;
}

test "events: each program status state becomes a record" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:app=cargo:progress=40:msg=QnVpbGRpbmc=\x1b\\", 0);
    var records = lastProgram(&f).?;
    try testing.expectEqual(1, records.len);
    try testing.expectEqualStrings("", records[0].id);
    try testing.expectEqual(.working, records[0].state);
    try testing.expectEqual(40, records[0].progress.?);
    try testing.expectEqualStrings("cargo", records[0].app.?);
    try testing.expectEqualStrings("Building", records[0].msg.?);

    // A report replaces its record: no `app` now means none.
    f.feed("\x1b]7501;state=blocked:kind=permission:msg=QWxsb3cgZWRpdD8=\x07", m.coalesce_ms);
    records = lastProgram(&f).?;
    try testing.expectEqual(1, records.len);
    try testing.expectEqual(.blocked, records[0].state);
    try testing.expectEqual(.permission, records[0].kind.?);
    try testing.expectEqual(null, records[0].progress);
    try testing.expectEqual(null, records[0].app);
    try testing.expectEqualStrings("Allow edit?", records[0].msg.?);

    const cases = .{ .{ "done", m.ProgramState.done }, .{ "error", m.ProgramState.@"error" }, .{ "idle", m.ProgramState.idle } };
    inline for (cases, 2..) |c, i| {
        f.feed("\x1b]7501;state=" ++ c[0] ++ ":progress=50:kind=auth\x07", @intCast(i * m.coalesce_ms));
        records = lastProgram(&f).?;
        try testing.expectEqual(1, records.len);
        // Progress goes with working and blocked only, kind with blocked.
        try testing.expectEqual(c[1], records[0].state);
        try testing.expectEqual(null, records[0].kind);
        try testing.expectEqual(null, records[0].progress);
    }

    // A state that this build does not know changes nothing.
    const n = programEvents(&f);
    f.feed("\x1b]7501;state=sleeping\x07", 10 * m.coalesce_ms);
    try testing.expectEqual(n, programEvents(&f));
    try testing.expectEqual(.idle, f.w.records.items[0].rec.state);
}

test "events: program status records keep their ids, inherit app, and clear with their children" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:app=deploy\x07" ++
        "\x1b]7501;state=working:id=deploy:title=dXMtZWFzdA==\x07" ++
        "\x1b]7501;state=blocked:id=deploy/eu:app=eu\x07" ++
        "\x1b]7501;state=done:id=deployer\x07", 0);
    f.w.flush(m.coalesce_ms);
    var records = lastProgram(&f).?;
    try testing.expectEqual(4, records.len);
    try testing.expectEqualStrings("deploy", records[1].id);
    try testing.expectEqualStrings("us-east", records[1].title.?);
    // A record with no `app` takes its nearest ancestor's, the root's here.
    try testing.expectEqualStrings("deploy", records[1].app.?);
    try testing.expectEqualStrings("eu", records[2].app.?);
    try testing.expectEqualStrings("deploy", records[3].app.?);
    // The stored record keeps its own value.
    try testing.expectEqual(null, f.w.records.items[1].rec.app);

    // A clear takes the record and the records under it, not `deployer`.
    f.feed("\x1b]7501;state=clear:id=deploy\x07", 2 * m.coalesce_ms);
    records = lastProgram(&f).?;
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings("", records[0].id);
    try testing.expectEqualStrings("deployer", records[1].id);

    // A clear of a record that is not there sends nothing.
    const n = programEvents(&f);
    f.feed("\x1b]7501;state=clear:id=nothing\x07", 4 * m.coalesce_ms);
    try testing.expectEqual(n, programEvents(&f));

    // A clear with no id takes every record.
    f.feed("\x1b]7501;state=clear\x07", 6 * m.coalesce_ms);
    try testing.expectEqual(0, lastProgram(&f).?.len);
    try testing.expectEqual(0, f.w.records.items.len);
}

test "events: a full reset clears every program status record" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working\x07\x1b]7501;state=done:id=a\x07", 0);
    f.feed("\x1bc", 100);
    try testing.expectEqual(0, lastProgram(&f).?.len);
    try testing.expectEqual(0, f.w.records.items.len);
}

test "events: a new shell prompt removes the records of the program that ran" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:id=a\x07\x1b]7501;state=blocked:id=b\x07" ++
        "\x1b]7501;state=idle:id=c\x07\x1b]7501;state=done:id=d\x07\x1b]7501;state=error:id=e\x07", 0);
    // A continuation prompt is the same prompt.
    f.feed("\x1b]133;P;k=c\x07", 100);
    try testing.expectEqual(5, f.w.records.items.len);
    f.feed("\x1b]133;A\x07$ ", 200);
    const records = lastProgram(&f).?;
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings("d", records[0].id);
    try testing.expectEqualStrings("e", records[1].id);
}

test "events: the shell's exit removes the records of the program that ran, at once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=blocked:id=a\x07\x1b]7501;state=done:id=b\x07", 0);
    // In the window of the last event: the exit does not wait for it.
    f.w.shellExited(1);
    const records = lastProgram(&f).?;
    try testing.expectEqual(1, records.len);
    try testing.expectEqualStrings("b", records[0].id);
    try testing.expectEqual(null, f.w.deadline());

    // Nothing to remove sends nothing.
    const n = programEvents(&f);
    f.w.shellExited(2);
    try testing.expectEqual(n, programEvents(&f));
}

test "events: program status reports coalesce to the first and the newest" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..100) |i| f.feed(try std.fmt.bufPrint(&buf, "\x1b]7501;state=working:progress={d}\x07", .{i}), 5);
    try testing.expectEqual(1, programEvents(&f));
    try testing.expectEqual(0, lastProgram(&f).?[0].progress.?);
    f.w.flush(5 + m.coalesce_ms);
    try testing.expectEqual(2, programEvents(&f));
    try testing.expectEqual(99, lastProgram(&f).?[0].progress.?);
}

test "events: past the most records, the one that changed least recently goes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..m.max_program_records) |i| f.feed(try std.fmt.bufPrint(&buf, "\x1b]7501;state=idle:id=r{d}\x07", .{i}), 0);
    // r0 changes, so r1 is now the oldest.
    f.feed("\x1b]7501;state=working:id=r0\x07", 0);
    f.feed("\x1b]7501;state=idle:id=new\x07", 0);
    try testing.expectEqual(m.max_program_records, f.w.records.items.len);
    try testing.expectEqualStrings("r0", f.w.records.items[0].rec.id);
    try testing.expectEqualStrings("r2", f.w.records.items[1].rec.id);
    try testing.expectEqualStrings("new", f.w.records.items[m.max_program_records - 1].rec.id);
}

test "events: while a client leads, the session answers the program status query and no other query" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.w.answers_all = false;
    f.feed("\x1b[c\x1b[6n\x1b]7501;?\x1b\\", 0);
    try testing.expectEqualStrings("\x1b]7501;" ++ program_status.query_reply ++ "\x1b\\", f.w.reply.items);
    f.w.reply.clearRetainingCapacity();
    f.feed("\x1b]7501;?\x07", 1);
    try testing.expectEqualStrings("\x1b]7501;" ++ program_status.query_reply ++ "\x07", f.w.reply.items);
}

/// The session's reply to `query` while no client leads.
fn expectReply(query: []const u8, reply: []const u8) !void {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("ab\r\nc", 0);
    f.feed(query, 1);
    try testing.expectEqualStrings(reply, f.w.reply.items);
}

test "events: with no leader, the session answers each query as Ghostty does" {
    // Device attributes: DA1, DA2 and their explicit forms.
    try expectReply("\x1b[c", "\x1b[?62;22c");
    try expectReply("\x1b[0c", "\x1b[?62;22c");
    try expectReply("\x1b[>c", "\x1b[>1;10;0c");
    try expectReply("\x1b[>0c", "\x1b[>1;10;0c");
    // DA3.
    try expectReply("\x1b[=c", "\x1bP!|00000000\x1b\\");
    // Device status: operating status, cursor position, extended position.
    try expectReply("\x1b[5n", "\x1b[0n");
    try expectReply("\x1b[6n", "\x1b[2;2R");
    try expectReply("\x1b[?6n", "\x1b[?2;2;1R");
    // A mode report (DECRQM): bracketed paste is reset.
    try expectReply("\x1b[?2004$p", "\x1b[?2004;2$y");
    // The kitty keyboard flags.
    try expectReply("\x1b[?u", "\x1b[?0u");
    // XTVERSION.
    try expectReply("\x1b[>q", "\x1bP>|libghostty\x1b\\");
    try expectReply("\x1b]7501;?\x07", "\x1b]7501;" ++ program_status.query_reply ++ "\x07");
    // A DA1 reply that a program echoes is not a query.
    try expectReply("\x1b[?62;22c", "");
    // The session does not know the app's colors: no OSC 4, 10 or 11 report.
    try expectReply("\x1b]4;1;?\x07", "");
    try expectReply("\x1b]10;?\x07", "");
    try expectReply("\x1b]11;?\x1b\\", "");
    // The kitty graphics query: the images are not the session's.
    try expectReply("\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\", "");
}

test "events: the session answers a query that comes in two reads" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("out\x1b[", 0);
    try testing.expectEqualStrings("", f.w.reply.items);
    f.feed(">c", 1);
    try testing.expectEqualStrings("\x1b[>1;10;0c", f.w.reply.items);
}

test "events: a new client gets the program status records" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]7501;state=working:app=make\x07\x1b]7501;state=blocked:id=x:kind=question\x07", 0);
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    try f.w.current(&out);
    defer for (out.items) |e| if (e == .program) freeProgram(testing.allocator, e.program);
    const records = out.items[out.items.len - 1].program;
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings("make", records[1].app.?);
    try testing.expectEqual(.question, records[1].kind.?);
}

test "events: an ended run sets unseen, a failed run sets failed, a new run clears both" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;C\x07", 0);
    try testing.expectEqual(m.Attention{}, f.w.attention);
    f.feed("\x1b]133;D;0\x07", 10);
    try testing.expectEqual(m.Attention{ .unseen = true }, f.w.attention);
    f.feed("\x1b]133;C\x07", 20);
    try testing.expectEqual(m.Attention{}, f.w.attention);
    // A failed run: a progress error ends it (v1's red dot).
    f.feed("\x1b]133;D;0\x07", 30);
    f.feed("\x1b]9;4;1;40\x07", 40);
    f.feed("\x1b]9;4;2\x07", 50);
    try testing.expectEqual(m.Attention{ .unseen = true, .failed = true }, f.w.attention);
    const flags = try f.only(.attention);
    defer testing.allocator.free(flags);
    try testing.expectEqual(5, flags.len);
}

test "events: the bell sets bell, a new run keeps it, and seen clears everything" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x07\x07", 0);
    try testing.expectEqual(m.Attention{ .bell = true }, f.w.attention);
    f.feed("\x1b]133;C\x07\x1b]133;D;0\x07", 10);
    try testing.expectEqual(m.Attention{ .unseen = true, .bell = true }, f.w.attention);
    f.feed("\x1b]133;C\x07", 20);
    try testing.expectEqual(m.Attention{ .bell = true }, f.w.attention);
    f.w.seen();
    try testing.expectEqual(m.Attention{}, f.w.attention);
    // The clear is pushed also when nothing was set, so that the client that
    // asked gets its answer.
    f.w.clearReady();
    f.w.seen();
    const flags = try f.only(.attention);
    defer testing.allocator.free(flags);
    try testing.expectEqual(1, flags.len);
}

test "events: a new client gets the flags only when one is set" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var out: std.ArrayList(Event) = .empty;
    defer out.deinit(testing.allocator);
    try f.w.current(&out);
    for (out.items) |e| try testing.expect(e != .attention);
    f.feed("\x1b]133;C\x07\x1b]133;D;1\x07", 0);
    out.clearRetainingCapacity();
    try f.w.current(&out);
    var found = false;
    for (out.items) |e| if (e == .attention) {
        found = true;
        try testing.expectEqual(m.Attention{ .unseen = true }, e.attention);
    };
    try testing.expect(found);
}

test "events: isSubmission finds a Return in input" {
    try testing.expect(isSubmission("ls\r"));
    try testing.expect(isSubmission("\x1b[13u"));
    try testing.expect(isSubmission("\x1b[13;1:1u"));
    try testing.expect(!isSubmission("ls"));
    try testing.expect(isSubmission("\n"));
    // Shift+Enter, a key release and a paste add a line.
    try testing.expect(!isSubmission("\x1b[13;2u"));
    try testing.expect(!isSubmission("\x1b[13;1:3u"));
    try testing.expect(!isSubmission("\x1b[200~a\rb\x1b[201~"));
    // A cursor position report is a reply, not a key.
    try testing.expect(!isSubmission("\x1b[13;5R"));
    try testing.expect(!isSubmission("\x1b[133u"));
}

const raw_program: Foreground = .{ .idle = false, .raw = true };

test "events: a submission to a raw program with output after it is a run, and quiet output ends it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.w.foreground(raw_program, 0);
    f.w.submitted(1000);
    f.feed("a", 1000);
    try testing.expectEqual(.idle, f.w.status.state);
    f.feed("b", 1500);
    try testing.expectEqual(.running, f.w.status.state);
    f.feed("c", 4000);
    try testing.expectEqual(4000 + quiet_ms, f.w.deadline().?);
    f.w.flush(4000 + quiet_ms - 1);
    try testing.expectEqual(.running, f.w.status.state);
    f.w.flush(4000 + quiet_ms);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
    try testing.expectEqual(m.Attention{ .unseen = true }, f.w.attention);
    // The next submission is the next reply.
    f.w.submitted(9000);
    f.feed("d", 9000);
    f.feed("e", 9500);
    try testing.expectEqual(.running, f.w.status.state);
    try testing.expectEqual(m.Attention{}, f.w.attention);
    f.w.flush(9500 + quiet_ms);
    // A slow reply: its first output comes late, but before `quiet_ms`.
    f.w.submitted(20_000);
    f.feed("f", 20_000 + quiet_ms - 1);
    try testing.expectEqual(.running, f.w.status.state);
}

test "events: the echo of a submission, or output after quiet_ms, starts no run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.w.foreground(raw_program, 0);
    f.w.submitted(1000);
    f.feed("a", 1000);
    f.feed("b", 1000 + echo_ms - 1);
    f.w.flush(5000);
    try testing.expectEqual(.idle, f.w.status.state);
    f.feed("c", 1000 + quiet_ms);
    try testing.expectEqual(.idle, f.w.status.state);
    // The rule ends with the output that came too late.
    f.feed("d", 1000 + quiet_ms + echo_ms);
    try testing.expectEqual(.idle, f.w.status.state);
    // A program in canonical mode gets no agent rule.
    f.w.foreground(.{ .idle = false, .raw = false }, 6000);
    f.w.submitted(6000);
    f.feed("c", 6000);
    f.feed("d", 6500);
    try testing.expectEqual(.idle, f.w.status.state);
}

test "events: with no marks, a program that takes the foreground after a submission runs until the shell is back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.w.submitted(0);
    try testing.expect(f.w.watchesForeground(100));
    f.w.foreground(.{ .idle = false }, 300);
    try testing.expectEqual(.running, f.w.status.state);
    try testing.expect(!f.w.watchesForeground(400));
    // A program in canonical mode does not end for quiet output.
    f.w.flush(300 + quiet_ms * 10);
    try testing.expectEqual(.running, f.w.status.state);
    f.w.foreground(.{}, 60_000);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
    try testing.expectEqual(m.Attention{ .unseen = true }, f.w.attention);
    // A program in front with no submission (a prompt hook) is no run.
    f.w.foreground(.{ .idle = false }, 61_000);
    try testing.expectEqual(.done, f.w.status.state);
    f.w.foreground(.{}, 61_100);
    // A submission arms the rule for `submit_window_ms` only.
    f.w.submitted(70_000);
    try testing.expect(!f.w.watchesForeground(70_000 + submit_window_ms));
    f.w.foreground(.{ .idle = false }, 70_000 + submit_window_ms);
    try testing.expectEqual(.done, f.w.status.state);
}

test "events: with marks, a submission at the shell arms no foreground run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ ", 0);
    f.w.submitted(100);
    try testing.expect(!f.w.watchesForeground(100));
    f.w.foreground(.{ .idle = false }, 200);
    try testing.expectEqual(.idle, f.w.status.state);
}

test "events: with marks, a program that a nested shell starts runs until that shell is back" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // zsh (group 10, marks) starts sh (group 20), whose prompt reads keys.
    f.feed("\x1b]133;A\x07$ \x1b]133;C\x07", 0);
    const sh: Foreground = .{ .idle = false, .raw = true, .pgrp = 20 };
    f.w.foreground(sh, 10);
    f.w.flush(10 + quiet_ms);
    try testing.expectEqual(.done, f.w.status.state);
    // At sh's prompt, `sleep 3`: a new group with no output.
    f.w.submitted(10_000);
    try testing.expect(f.w.watchesForeground(10_000));
    f.w.foreground(.{ .idle = false, .pgrp = 30 }, 10_050);
    try testing.expectEqual(.running, f.w.status.state);
    f.w.flush(10_050 + quiet_ms * 10);
    try testing.expectEqual(.running, f.w.status.state);
    // sh is back: the run ends, and sh's prompt is not the reply of an
    // agent.
    f.w.foreground(sh, 13_050);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
    try testing.expectEqual(m.Attention{ .unseen = true }, f.w.attention);
    f.feed("sh$ ", 13_100);
    try testing.expectEqual(.done, f.w.status.state);
    // A group that comes with no submission starts nothing.
    f.w.foreground(.{ .idle = false, .pgrp = 40 }, 20_000);
    try testing.expectEqual(.done, f.w.status.state);
}

test "events: a submission to a program that ends arms nothing for the prompt hooks after it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ ", 0);
    // `:q` and Return in vim (group 20), then nu (group 10) is back, and
    // its prompt hook takes a group of its own.
    f.w.foreground(.{ .idle = false, .raw = true, .pgrp = 20 }, 100);
    f.w.submitted(1000);
    f.w.foreground(.{ .pgrp = 10 }, 1100);
    f.w.foreground(.{ .idle = false, .pgrp = 30 }, 1200);
    try testing.expectEqual(.idle, f.w.status.state);
}

test "events: a command that becomes a raw program ends for quiet output, and progress does not" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b]133;A\x07$ \x1b]133;C\x07", 0);
    try testing.expectEqual(.running, f.w.status.state);
    // The program switches to raw mode some time after its start.
    f.w.foreground(.{ .idle = false }, 10);
    f.w.foreground(raw_program, 5000);
    try testing.expectEqual(5000 + quiet_ms, f.w.deadline().?);
    f.w.flush(5000 + quiet_ms);
    try testing.expectEqual(m.Status{ .state = .done }, f.w.status);
    // Its end mark changes nothing more.
    f.w.foreground(.{}, 9000);
    f.feed("\x1b]133;D;0\x07", 9000);
    try testing.expectEqual(.done, f.w.status.state);

    f.feed("\x1b]9;4;3\x07", 10_000);
    try testing.expectEqual(.running, f.w.status.state);
    f.w.foreground(raw_program, 10_000);
    try testing.expectEqual(null, f.w.deadline());
    f.w.flush(10_000 + quiet_ms * 10);
    try testing.expectEqual(.running, f.w.status.state);
}
