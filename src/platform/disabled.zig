const std = @import("std");

pub fn run(_: std.mem.Allocator, _: []const []const u8) !u8 {
    std.debug.print("vertex: GUI support is disabled; build on Linux with -Dgui=true\n", .{});
    return error.GuiDisabled;
}
