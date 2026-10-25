const std = @import("std");

pub fn run(_: std.mem.Allocator, _: []const []const u8) !u8 {
    std.debug.print("vertex: GUI support is disabled; build on Linux with -Dgui=true\n", .{});
    return error.GuiDisabled;
}
pub fn runWithOptions(allocator: std.mem.Allocator, options: @import("../cli.zig").Launch) !u8 {
    return run(allocator, options.command);
}
pub fn checkConfig(_: std.mem.Allocator, _: ?[]const u8) !void {
    std.debug.print("vertex: config check requires a GUI-enabled Linux executable (no display is needed)\n", .{});
    return error.GuiDisabled;
}
