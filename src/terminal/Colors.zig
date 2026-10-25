//! Shared defaults for rendering and terminal color queries.
const std = @import("std");

/// X11 color forms used by OSC 4/10/11/12 (without a system color database).
pub fn parse(text: []const u8) ?u32 {
    var components: [3][]const u8 = undefined;
    if (std.mem.startsWith(u8, text, "rgb:")) {
        var parts = std.mem.splitScalar(u8, text[4..], '/');
        for (&components) |*part| part.* = parts.next() orelse return null;
        if (parts.next() != null) return null;
    } else if (text.len > 1 and text[0] == '#' and (text.len - 1) % 3 == 0) {
        const n = (text.len - 1) / 3;
        if (n == 0 or n > 4) return null;
        for (&components, 0..) |*part, i| part.* = text[1 + i * n ..][0..n];
    } else return null;
    var color: u32 = 0;
    for (components) |part| {
        if (part.len == 0 or part.len > 4) return null;
        const value = std.fmt.parseInt(u32, part, 16) catch return null;
        const maximum = (@as(u32, 1) << @as(u5, @intCast(4 * part.len))) - 1;
        color = (color << 8) | (value * 255 / maximum);
    }
    return color;
}
pub const foreground: u32 = 0xd8dee9;
pub const background: u32 = 0x15171a;
pub const palette = [_]u32{
    0x2e3440, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
    0x4c566a, 0xd08770, 0xb5d99c, 0xffdf9e, 0x81a1c1, 0xc6a0c9, 0x9dd9e5, 0xffffff,
};

/// A session's theme. Kept independent of files, the environment and painters.
pub const Theme = struct {
    foreground: u32 = foreground_default,
    background: u32 = background_default,
    normal: [8]u32 = palette[0..8].*,
    bright: [8]u32 = palette[8..16].*,
    indexed: [256]?u32 = @splat(null),
    cursor: ?u32 = null,
    cursor_text: ?u32 = null,
    dim_factor: f64 = 0.5,
    bold_is_bright: bool = false,

    pub fn at(self: *const Theme, index: u8) u32 {
        return self.indexed[index] orelse if (index < 8) self.normal[index] else if (index < 16) self.bright[index - 8] else Colors.indexed(index);
    }
};
const Colors = @This();
const foreground_default = foreground;
const background_default = background;

pub fn indexed(index: u8) u32 {
    if (index < 16) return palette[index];
    if (index >= 232) {
        const level: u32 = 8 + @as(u32, index - 232) * 10;
        return level * 0x010101;
    }
    const n: u32 = index - 16;
    return (cube(n / 36) << 16) | (cube(n / 6 % 6) << 8) | cube(n % 6);
}
fn cube(value: u32) u32 {
    return if (value == 0) 0 else 55 + value * 40;
}
