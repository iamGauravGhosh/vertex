//! Nonblocking desktop URI opening; only reap children created by this adapter.
const std = @import("std");
const c = @import("c");
const Links = @import("../terminal/Links.zig");
const Desktop = @This();
children: [16]c.pid_t = @splat(0),
pub fn poll(self: *Desktop) void {
    for (&self.children) |*pid| if (pid.* != 0) {
        var status: c_int = 0;
        if (c.waitpid(pid.*, &status, c.WNOHANG) == pid.*) {
            if (status != 0) std.debug.print("vertex: desktop opener failed\n", .{});
            pid.* = 0;
        }
    };
}
pub fn open(self: *Desktop, allocator: std.mem.Allocator, uri: []const u8) !void {
    if (!Links.allowed(uri)) return error.InvalidUri;
    self.poll();
    var available: ?*c.pid_t = null;
    for (&self.children) |*pid| if (pid.* == 0) {
        available = pid;
        break;
    };
    const slot = available orelse return error.TooManyOpeners;
    const target = try allocator.dupeSentinel(u8, uri, 0);
    defer allocator.free(target);
    const pid = c.fork();
    if (pid < 0) return error.OpenerFailed;
    if (pid == 0) {
        _ = c.setsid();
        _ = c.signal(c.SIGPIPE, c.SIG_DFL);
        const argv = [_]?[*:0]const u8{ "xdg-open", target, null };
        _ = c.execvp("xdg-open", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    slot.* = pid;
}
