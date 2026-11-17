const std = @import("std");
const lib_posix = @import("posix.zig");

/// Connects to the socket at `socket_path`.
pub fn connectSession(socket_path: []const u8) error{ ConnectionRefused, Unexpected }!i32 {
    return connect(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => return error.ConnectionRefused,
        else => return error.Unexpected,
    };
}

fn connect(path: []const u8) !i32 {
    var unix_addr = try lib_posix.initUnix(path);
    const socket_fd = try lib_posix.socket(lib_posix.AF.UNIX, lib_posix.SOCK.STREAM | lib_posix.SOCK.CLOEXEC, 0);
    errdefer lib_posix.close(socket_fd);
    try lib_posix.connect(socket_fd, &unix_addr.any, unix_addr.getOsSockLen());
    return socket_fd;
}

pub fn createSocket(sesh: []const u8) !lib_posix.socket_t {
    // AF.UNIX: Unix domain socket for local IPC with client processes
    // SOCK.STREAM: Reliable, bidirectional communication
    // SOCK.NONBLOCK: Set socket to non-blocking
    const fd = try lib_posix.socket(
        lib_posix.AF.UNIX,
        lib_posix.SOCK.STREAM | lib_posix.SOCK.NONBLOCK | lib_posix.SOCK.CLOEXEC,
        0,
    );
    errdefer lib_posix.close(fd);

    var unix_addr = try lib_posix.initUnix(sesh);
    try lib_posix.bind(fd, &unix_addr.any, unix_addr.getOsSockLen());
    try lib_posix.listen(fd, 128);
    return fd;
}

/// Maximum number of usable bytes in a Unix domain socket path.
/// Derived from the platform's sockaddr_un.path field, minus 1 for the
/// required null terminator.
pub const max_socket_path_len: usize = @typeInfo(
    @TypeOf(@as(lib_posix.sockaddr.un, undefined).path),
).array.len - 1;

pub fn getSocketPath(
    alloc: std.mem.Allocator,
    socket_dir: []const u8,
    session_name: []const u8,
) error{ NameTooLong, OutOfMemory }![]const u8 {
    const dir = socket_dir;
    const path_len = dir.len + 1 + session_name.len;
    if (path_len > max_socket_path_len) return error.NameTooLong;
    const fname = try alloc.alloc(u8, path_len);
    @memcpy(fname[0..dir.len], dir);
    @memcpy(fname[dir.len .. dir.len + 1], "/");
    @memcpy(fname[dir.len + 1 ..], session_name);
    return fname;
}

test "max_socket_path_len matches platform sockaddr_un" {
    const path_field_len = @typeInfo(
        @TypeOf(@as(lib_posix.sockaddr.un, undefined).path),
    ).array.len;
    try std.testing.expectEqual(path_field_len - 1, max_socket_path_len);
    try std.testing.expect(max_socket_path_len > 0);
}

test "getSocketPath succeeds for paths within limit" {
    const alloc = std.testing.allocator;
    const result = try getSocketPath(alloc, "/tmp/zmx", "mysession");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("/tmp/zmx/mysession", result);
}

test "getSocketPath returns NameTooLong when path exceeds limit" {
    const alloc = std.testing.allocator;
    const dir: [max_socket_path_len - 2]u8 = @splat('d');
    const dir_slice: []const u8 = &dir;

    const ok = try getSocketPath(alloc, dir_slice, "x");
    defer alloc.free(ok);
    try std.testing.expectEqual(max_socket_path_len, ok.len);

    const err = getSocketPath(alloc, dir_slice, "xx");
    try std.testing.expectError(error.NameTooLong, err);
}

test "getSocketPath returns NameTooLong for empty dir with oversized name" {
    const alloc = std.testing.allocator;
    const name: [max_socket_path_len]u8 = @splat('n');
    const name_slice: []const u8 = &name;
    const err = getSocketPath(alloc, "", name_slice);
    try std.testing.expectError(error.NameTooLong, err);
}
