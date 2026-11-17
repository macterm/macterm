comptime {
    _ = @import("main.zig");
    _ = @import("util.zig");
    _ = @import("socket.zig");
    _ = @import("pty.zig");
    _ = @import("signal.zig");
    _ = @import("terminal.zig");
    _ = @import("foreground.zig");
    _ = @import("posix.zig");
    _ = @import("protocol/protocol.zig");
    _ = @import("runtime.zig");
    _ = @import("session.zig");
    _ = @import("server.zig");
    _ = @import("attach.zig");
    _ = @import("events.zig");
    _ = @import("relay.zig");
    _ = @import("ring.zig");
    _ = @import("proxy.zig");
    _ = @import("link/packet.zig");
    _ = @import("link/stream.zig");
    _ = @import("link/host.zig");
    _ = @import("model/tests.zig");
    _ = @import("cli/contract.zig");
}
