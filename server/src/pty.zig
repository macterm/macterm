//! The session's pty: its size, and the shell that runs in it.

const std = @import("std");
const cross = @import("cross");
const lib_posix = @import("posix.zig");
const foreground = @import("foreground.zig");

pub const Resize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,

    pub fn winsize(self: Resize) cross.struct_winsize {
        return .{
            .ws_row = self.rows,
            .ws_col = self.cols,
            .ws_xpixel = self.xpixel,
            .ws_ypixel = self.ypixel,
        };
    }
};

/// The size of the terminal on `fd`, else on stdout, stdin, stderr or
/// /dev/tty, else 120 by 24.
pub fn getTerminalSize(fd: i32) Resize {
    var ws: cross.struct_winsize = undefined;
    if (cross.ioctl(fd, cross.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
    }
    inline for (.{ lib_posix.STDOUT_FILENO, lib_posix.STDIN_FILENO, lib_posix.STDERR_FILENO }) |fallback_fd| {
        if (fallback_fd != fd) {
            if (cross.ioctl(fallback_fd, cross.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
                return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
            }
        }
    }
    if (lib_posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0)) |tty_fd| {
        defer lib_posix.close(tty_fd);
        if (cross.ioctl(tty_fd, cross.TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
            return .{ .rows = ws.ws_row, .cols = ws.ws_col, .xpixel = ws.ws_xpixel, .ypixel = ws.ws_ypixel };
        }
    } else |_| {}
    return .{ .rows = 24, .cols = 120 };
}

pub const Cmd = struct {
    file: [*:0]const u8,
    argv_ptr: [*:null]const ?[*:0]const u8,
};

pub fn createCmdZ(def_shell: []const u8, command: ?[]const []const u8) !Cmd {
    const gpa = std.heap.c_allocator;

    if (command) |cmd_args| {
        if (cmd_args.len > 0) {
            const argv = try gpa.allocSentinel(?[*:0]const u8, cmd_args.len, null);
            for (cmd_args, 0..) |arg, i| {
                const s = try gpa.dupeSentinel(u8, arg, 0);
                argv[i] = s.ptr;
            }
            return .{
                .file = argv[0].?,
                .argv_ptr = argv.ptr,
            };
        }
    }

    const shell: [:0]const u8 = try gpa.dupeSentinel(u8, def_shell, 0);

    // Use "-shellname" as argv[0] to signal login shell (traditional method)
    const login_shell = try std.fmt.allocPrintSentinel(
        gpa,
        "-{s}",
        .{std.fs.path.basename(shell)},
        0,
    );
    const argv = try gpa.allocSentinel(?[*:0]const u8, 1, null);
    argv[0] = login_shell.ptr;

    return .{
        .file = shell,
        .argv_ptr = argv.ptr,
    };
}

/// Runs in the forked child. Either execs or returns an error (caller
/// must exit on error -- returning would fall through to parent code).
fn exec(sesh_name: []const u8, cmd: Cmd, session_var: []const u8) !noreturn {
    const gpa = std.heap.c_allocator;

    // main() set SIGPIPE to SIG_IGN, which (unlike handlers) survives
    // exec. Restore the default so the shell and its children behave
    // normally (e.g. `yes | head` should exit 141 via SIGPIPE).
    const dfl: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.DFL },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &dfl, null);

    _ = cross.unsetenv(foreground.env_var);

    const session_env = try std.fmt.allocPrintSentinel(
        gpa,
        "{s}={s}",
        .{ session_var, sesh_name },
        0,
    );
    _ = cross.putenv(session_env.ptr);

    if (cross.getenv("TERM")) |term_env| {
        if (std.mem.eql(u8, std.mem.span(term_env), "dumb")) {
            _ = cross.putenv(@constCast("TERM=xterm-256color"));
        }
    } else {
        _ = cross.putenv(@constCast("TERM=xterm-256color"));
    }

    const err = lib_posix.execvpeZ(cmd.file, cmd.argv_ptr, std.c.environ);
    std.log.err("execvpe failed: cmd={s} err={s}", .{ cmd.file, @errorName(err) });
    lib_posix.exit(1);
}

pub const PtyInfo = struct {
    master_fd: c_int = undefined,
    pid: c_int = undefined,
    /// The path of the slave side, as forkpty names it.
    name_buf: [128]u8 = @splat(0),

    pub fn name(self: *const PtyInfo) []const u8 {
        return std.mem.sliceTo(&self.name_buf, 0);
    }
};

/// spawnPty runs forkpty() and executes the shell or shell command the user
/// provides. `session_var` names the session in the shell's environment.
pub fn spawnPty(sesh_name: []const u8, cmd: Cmd, size: Resize, session_var: []const u8) !PtyInfo {
    var ws: cross.struct_winsize = .{
        .ws_row = size.rows,
        .ws_col = size.cols,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    var info: PtyInfo = .{};
    var master_fd: c_int = undefined;
    // forkpty writes the name with no length: the buffer is larger than any
    // pty path (Linux /dev/pts/N, macOS /dev/ttysNNN).
    const pid = cross.forkpty(&master_fd, &info.name_buf, null, &ws);
    if (pid < 0) {
        return error.ForkPtyFailed;
    }

    if (pid == 0) { // child pid code path
        // In the forked child, ANY error must exit rather than propagate:
        // a returned error falls through to the parent code path below,
        // running a second daemon on the same socket (or worse, hitting
        // errdefers that delete the parent's socket file).
        exec(sesh_name, cmd, session_var) catch |err| {
            std.log.err("child setup failed: {s}", .{@errorName(err)});
            lib_posix.exit(1);
        };
        unreachable; // exec() either execs or exits, never returns ok
    }
    // master pid code path
    std.log.info("pty spawned session={s} pid={d}", .{ sesh_name, pid });

    // make pty non-blocking
    const flags = try lib_posix.fcntl(master_fd, lib_posix.F.GETFL, 0);
    _ = try lib_posix.fcntl(master_fd, lib_posix.F.SETFL, flags | lib_posix.O_NONBLOCK);

    info.master_fd = master_fd;
    info.pid = pid;
    return info;
}
