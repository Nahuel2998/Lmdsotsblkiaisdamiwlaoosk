const std   = @import("std");
const linux = std.os.linux;

const c = @import("xcb");
// const c = @import("xcb_gen.zig");
const Lmdsotsblkiaisdamiwlaoosk = @import("root.zig");

var sig_pipe: [2]std.posix.fd_t = undefined;
fn handleSig(sig: linux.SIG) callconv(.c) void {
    _ = linux.write(sig_pipe[1], &.{ @intCast( @intFromEnum(sig) ) }, 1);
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    _ = call( linux.pipe(&sig_pipe) ) orelse {
        std.log.err("Failed to create signal pipe", .{});
        return error.NoPipe;
    };
    defer {
        _ = linux.close(sig_pipe[0]);
        _ = linux.close(sig_pipe[1]);
    }
    const sigact = linux.Sigaction{
        .handler = .{ .handler = handleSig },
        .mask    = linux.sigemptyset(),
        .flags   = 0,
    };
    _ = call( linux.sigaction(.TERM, &sigact, null) ) orelse {
        std.log.warn("Failed to setup signal handler for SIGTERM", .{});
    };
    _ = call( linux.sigaction(.INT,  &sigact, null) ) orelse {
        std.log.warn("Failed to setup signal handler for SIGINT", .{});
    };
    _ = call( linux.sigaction(.USR1, &sigact, null) ) orelse {
        std.log.err("Failed to setup signal handler for SIGUSR1", .{});
        return error.NoSIGUSR1;
    };

    var   pref_screen: c_int = undefined;
    const conn = xcbConnect(&pref_screen) orelse return error.NoDisplay;
    defer c.xcb_disconnect(conn);

    var ctx: Lmdsotsblkiaisdamiwlaoosk = try .init(conn, pref_screen);
    defer ctx.deinit();

    const x_fd = c.xcb_get_file_descriptor(conn);
    var   fds  = [_]std.posix.pollfd{
        .{ .fd = sig_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd =        x_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    std.log.info("Waiting on pid: {}", .{ std.os.linux.getpid() });
    while (true) {
        _ = try std.posix.poll(&fds, -1);
        
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [4]u8 = undefined;
            _ = call( linux.read(sig_pipe[0], &buf, 1) ) orelse unreachable;

            const sig: linux.SIG = @enumFromInt(buf[0]);
            switch (sig) {
                .TERM, .INT => break,
                .USR1 => {
                    ctx.toggleSolid();
                    _ = c.xcb_flush(conn);
                    std.log.info("Solid: {}", .{ctx.solid});
                },
                else  => unreachable,
            }
        }
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            ctx.drainXEvents();
        }
    }
}

fn xcbConnect(pref_screen: ?*c_int) ?*c.xcb_connection_t {
    const conn = c.xcb_connect(null, pref_screen) orelse return null;
    errdefer c.xcb_disconnect(conn);
    if (c.xcb_connection_has_error(conn) != 0) {
        return null;
    }
    return conn;
}

pub fn call(res: usize) ?usize {
    if (linux.errno(res) != .SUCCESS) return null;
    return res;
}
