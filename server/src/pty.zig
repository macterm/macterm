//! The size of a terminal, and how to read it.

const cross = @import("cross");
const lib_posix = @import("posix.zig");

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
