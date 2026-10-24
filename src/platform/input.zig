//! Legacy terminal keyboard encoding, separate from Wayland/XKB state.
const std = @import("std");
const c = @import("c");
pub const Modifiers = struct { shift: bool = false, alt: bool = false, control: bool = false };

pub fn encode(buffer: []u8, symbol: u32, text: []const u8, mods: Modifiers) ![]const u8 {
    const modifier: u8 = 1 + @as(u8, @intFromBool(mods.shift)) + 2 * @as(u8, @intFromBool(mods.alt)) + 4 * @as(u8, @intFromBool(mods.control));
    const final: ?u8 = switch (symbol) {
        c.XKB_KEY_Up => 'A',
        c.XKB_KEY_Down => 'B',
        c.XKB_KEY_Right => 'C',
        c.XKB_KEY_Left => 'D',
        c.XKB_KEY_Home => 'H',
        c.XKB_KEY_End => 'F',
        else => null,
    };
    if (final) |value| return if (modifier == 1)
        std.fmt.bufPrint(buffer, "\x1b[{c}", .{value})
    else
        std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ modifier, value });
    const number: ?u8 = switch (symbol) {
        c.XKB_KEY_Insert => 2,
        c.XKB_KEY_Delete => 3,
        c.XKB_KEY_Page_Up => 5,
        c.XKB_KEY_Page_Down => 6,
        c.XKB_KEY_F5 => 15,
        c.XKB_KEY_F6 => 17,
        c.XKB_KEY_F7 => 18,
        c.XKB_KEY_F8 => 19,
        c.XKB_KEY_F9 => 20,
        c.XKB_KEY_F10 => 21,
        c.XKB_KEY_F11 => 23,
        c.XKB_KEY_F12 => 24,
        else => null,
    };
    if (number) |value| return if (modifier == 1)
        std.fmt.bufPrint(buffer, "\x1b[{d}~", .{value})
    else
        std.fmt.bufPrint(buffer, "\x1b[{d};{d}~", .{ value, modifier });
    if (symbol >= c.XKB_KEY_F1 and symbol <= c.XKB_KEY_F4) {
        const value: u8 = @intCast('P' + symbol - c.XKB_KEY_F1);
        return if (modifier == 1) std.fmt.bufPrint(buffer, "\x1bO{c}", .{value}) else std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ modifier, value });
    }
    if (symbol == c.XKB_KEY_ISO_Left_Tab or (symbol == c.XKB_KEY_Tab and mods.shift)) return std.fmt.bufPrint(buffer, "\x1b[Z", .{});
    var byte: [1]u8 = undefined;
    const value: []const u8 = switch (symbol) {
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => "\r",
        c.XKB_KEY_BackSpace => if (mods.control) "\x08" else "\x7f",
        c.XKB_KEY_Tab => "\t",
        c.XKB_KEY_Escape => "\x1b",
        else => control: {
            if (mods.control) {
                const ascii = if (symbol >= 'a' and symbol <= 'z') symbol - 32 else symbol;
                byte[0] = switch (ascii) {
                    '@'...'_' => @intCast(ascii & 0x1f),
                    ' ', '2' => 0,
                    '3' => 0x1b,
                    '4' => 0x1c,
                    '5' => 0x1d,
                    '6' => 0x1e,
                    '7', '/' => 0x1f,
                    '8', '?' => 0x7f,
                    else => break :control text,
                };
                break :control &byte;
            }
            break :control text;
        },
    };
    if (value.len == 0) return buffer[0..0];
    const prefix: usize = @intFromBool(mods.alt);
    if (value.len + prefix > buffer.len) return error.NoSpaceLeft;
    if (mods.alt) buffer[0] = 0x1b;
    @memcpy(buffer[prefix..][0..value.len], value);
    return buffer[0 .. prefix + value.len];
}
