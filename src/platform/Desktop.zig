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
    return self.launch(allocator, &.{ "xdg-open", uri });
}
/// Explicit argv only: bindings never run through an implicit shell.
pub fn launch(self: *Desktop, allocator: std.mem.Allocator, arguments: []const []const u8) !void {
    if (arguments.len == 0 or arguments[0].len == 0) return error.InvalidCommand;
    self.poll();
    var available: ?*c.pid_t = null;
    for (&self.children) |*pid| if (pid.* == 0) {
        available = pid;
        break;
    };
    const slot = available orelse return error.TooManyOpeners;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const argv = try arena.allocator().alloc(?[*:0]const u8, arguments.len + 1);
    for (arguments, 0..) |argument, i| argv[i] = (try arena.allocator().dupeSentinel(u8, argument, 0)).ptr;
    argv[arguments.len] = null;
    const pid = c.fork();
    if (pid < 0) return error.OpenerFailed;
    if (pid == 0) {
        _ = c.setsid();
        _ = c.signal(c.SIGPIPE, c.SIG_DFL);
        _ = c.execvp(argv[0].?, @ptrCast(argv.ptr));
        c._exit(127);
    }
    slot.* = pid;
}
