const std = @import("std");
const c = @import("c");
const Graphics = @import("../terminal/Graphics.zig");
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Graphics.Decoded {
    if (bytes.len > Graphics.max_transfer) return error.ImageTooLarge;
    var width: c_int = 0;
    var height: c_int = 0;
    const pixels = c.vertex_image_decode(bytes.ptr, @intCast(bytes.len), &width, &height) orelse return error.InvalidImage;
    defer c.vertex_image_free(pixels);
    const n = try Graphics.byteSize(@intCast(width), @intCast(height));
    return .{ .width = @intCast(width), .height = @intCast(height), .pixels = try allocator.dupe(u8, pixels[0..n]) };
}
