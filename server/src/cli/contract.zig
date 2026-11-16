//! The v1 CLI contract (design 011 §5), as `golden/` holds it. The Swift test
//! `MactermTests/CLI/CLIContractTests.swift` writes the files from the Swift
//! CLI and checks the Swift CLI against them. The Zig CLI reads the same files.
//!
//! - `golden/contract.json`: each command, its options and its positional
//!   arguments, and the usage line of its help.
//! - `golden/cases.input.json`: the argument lines, the canned responses of the
//!   stand-in app, and the v2 `method` of each line (null until its 011 issue
//!   sets it).
//! - `golden/cases.json`: the requests and the output of each line.
//!
//! The parse is strict: a field that one side adds and the other does not
//! know fails here, so the two readers change together.

const std = @import("std");
const messages = @import("../protocol/messages.zig");

pub const contract_json = @embedFile("golden/contract.json");
pub const cases_input_json = @embedFile("golden/cases.input.json");

pub const Contract = struct {
    commands: []const Command,

    pub const Command = struct {
        /// The words after `macterm`. The root is empty.
        path: []const []const u8,
        abstract: []const u8,
        discussion: ?[]const u8 = null,
        /// The usage line of the help, with its whitespace collapsed. Null for
        /// a command that has no help.
        usage: ?[]const u8 = null,
        /// Not in the help of its parent.
        hidden: bool,
        /// In Debug builds only.
        debug: bool,
        subcommands: []const []const u8,
        /// The subcommand that runs when the command is given alone.
        default: ?[]const u8 = null,
        options: []const Option,
        arguments: []const Argument,
    };

    /// A flag (no `value`) or an option.
    pub const Option = struct {
        /// With the dashes: `-h`, `--help`.
        names: []const []const u8,
        value: ?[]const u8 = null,
        repeating: bool,
        optional: bool,
        hidden: bool,
        debug: bool,
        default: ?[]const u8 = null,
        abstract: []const u8,
    };

    /// A positional argument.
    pub const Argument = struct {
        name: []const u8,
        repeating: bool,
        optional: bool,
        hidden: bool,
        /// `all`: every word that is left, flags too. `unrecognized`: every
        /// word that is not an option of the command. Null: one word each.
        takes: ?[]const u8 = null,
        default: ?[]const u8 = null,
        abstract: []const u8,
    };

    /// The command at `path`, or null.
    pub fn find(self: Contract, path: []const []const u8) ?*const Command {
        for (self.commands) |*command| {
            if (eqlPath(command.path, path)) return command;
        }
        return null;
    }

    /// The command that an argument line names: its longest prefix of
    /// command words.
    pub fn resolve(self: Contract, arguments: []const []const u8) *const Command {
        var command = self.find(&.{}).?;
        for (arguments, 1..) |_, n| {
            command = self.find(arguments[0..n]) orelse break;
        }
        return command;
    }
};

pub const Case = struct {
    arguments: []const []const u8,
    /// The v2 server method that the line maps to.
    method: ?[]const u8,
    /// The canned response of the stand-in app, for each v1 wire command.
    responses: ?std.json.Value = null,
    /// The protocol version of the stand-in app. Null: the current one.
    app_version: ?u32 = null,
};

pub fn parseContract(arena: std.mem.Allocator) !Contract {
    return std.json.parseFromSliceLeaky(Contract, arena, contract_json, .{});
}

pub fn parseCases(arena: std.mem.Allocator) ![]const Case {
    return std.json.parseFromSliceLeaky([]const Case, arena, cases_input_json, .{});
}

fn eqlPath(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn isMethod(name: []const u8) bool {
    inline for (messages.methods) |M| {
        if (std.mem.eql(u8, M.name, name)) return true;
    }
    return false;
}

const testing = std.testing;

test "the contract is a tree" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const contract = try parseContract(arena.allocator());

    try testing.expect(contract.find(&.{}) != null);
    for (contract.commands, 0..) |command, i| {
        for (contract.commands[i + 1 ..]) |other| try testing.expect(!eqlPath(command.path, other.path));
        for (command.subcommands) |name| {
            const child = try std.mem.concat(arena.allocator(), []const u8, &.{ command.path, &.{name} });
            try testing.expect(contract.find(child) != null);
        }
        if (command.default) |name| {
            var listed = false;
            for (command.subcommands) |sub| listed = listed or std.mem.eql(u8, sub, name);
            try testing.expect(listed);
        }
        for (command.options) |option| {
            try testing.expect(option.names.len > 0);
            for (option.names) |name| try testing.expect(std.mem.startsWith(u8, name, "-"));
        }
    }
    try testing.expect(contract.find(&.{ "pane", "run" }) != null);
}

test "every case names a server method or none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const contract = try parseContract(arena.allocator());
    const cases = try parseCases(arena.allocator());

    try testing.expect(cases.len > 0);
    for (cases) |case| {
        try testing.expect(case.arguments.len > 0);
        if (case.method) |method| {
            if (!isMethod(method)) {
                std.debug.print("case {s}: no server method {s}\n", .{ case.arguments[0], method });
                return error.UnknownMethod;
            }
        }
        if (case.responses) |responses| try testing.expect(responses == .object);
    }

    const run = contract.resolve(&.{ "pane", "run", "--no-submit", "--", "ls" });
    try testing.expectEqualSlices(u8, "run", run.path[run.path.len - 1]);
}

test "a method name is checked against the protocol" {
    try testing.expect(isMethod("session.list"));
    try testing.expect(!isMethod("pane.nope"));
}
