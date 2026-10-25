//! XKB translation into the platform-independent input protocol.
const std = @import("std");
const c = @import("c");
const Input = @import("../terminal/Input.zig");
pub const Modifiers = Input.Modifiers;
pub const encodeKey = Input.encodeKey;

pub fn code(symbol: u32) u21 {
    if (symbol >= c.XKB_KEY_F1 and symbol <= c.XKB_KEY_F35) return @intCast(57364 + symbol - c.XKB_KEY_F1);
    if (symbol >= c.XKB_KEY_KP_0 and symbol <= c.XKB_KEY_KP_9) return @intCast(57399 + symbol - c.XKB_KEY_KP_0);
    return switch (symbol) {
        c.XKB_KEY_Escape => 57344,
        c.XKB_KEY_Return => 57345,
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => 57346,
        c.XKB_KEY_BackSpace => 57347,
        c.XKB_KEY_KP_Insert => 57425,
        c.XKB_KEY_Insert => 57348,
        c.XKB_KEY_KP_Delete => 57426,
        c.XKB_KEY_Delete => 57349,
        c.XKB_KEY_KP_Left => 57417,
        c.XKB_KEY_Left => 57350,
        c.XKB_KEY_KP_Right => 57418,
        c.XKB_KEY_Right => 57351,
        c.XKB_KEY_KP_Up => 57419,
        c.XKB_KEY_Up => 57352,
        c.XKB_KEY_KP_Down => 57420,
        c.XKB_KEY_Down => 57353,
        c.XKB_KEY_KP_Page_Up => 57421,
        c.XKB_KEY_Page_Up => 57354,
        c.XKB_KEY_KP_Page_Down => 57422,
        c.XKB_KEY_Page_Down => 57355,
        c.XKB_KEY_KP_Home => 57423,
        c.XKB_KEY_Home => 57356,
        c.XKB_KEY_KP_End => 57424,
        c.XKB_KEY_End => 57357,
        c.XKB_KEY_Caps_Lock => 57358,
        c.XKB_KEY_Scroll_Lock => 57359,
        c.XKB_KEY_Num_Lock => 57360,
        c.XKB_KEY_Print => 57361,
        c.XKB_KEY_Pause => 57362,
        c.XKB_KEY_Menu => 57363,
        c.XKB_KEY_KP_Decimal => 57409,
        c.XKB_KEY_KP_Divide => 57410,
        c.XKB_KEY_KP_Multiply => 57411,
        c.XKB_KEY_KP_Subtract => 57412,
        c.XKB_KEY_KP_Add => 57413,
        c.XKB_KEY_KP_Enter => 57414,
        c.XKB_KEY_KP_Equal => 57415,
        c.XKB_KEY_KP_Separator => 57416,
        c.XKB_KEY_KP_Begin => 57427,
        c.XKB_KEY_XF86AudioPlay => 57428,
        c.XKB_KEY_XF86AudioPause => 57429,
        c.XKB_KEY_XF86AudioStop => 57432,
        c.XKB_KEY_XF86AudioForward => 57433,
        c.XKB_KEY_XF86AudioRewind => 57434,
        c.XKB_KEY_XF86AudioNext => 57435,
        c.XKB_KEY_XF86AudioPrev => 57436,
        c.XKB_KEY_XF86AudioRecord => 57437,
        c.XKB_KEY_XF86AudioLowerVolume => 57438,
        c.XKB_KEY_XF86AudioRaiseVolume => 57439,
        c.XKB_KEY_XF86AudioMute => 57440,
        c.XKB_KEY_ISO_Level3_Shift => 57453,
        c.XKB_KEY_ISO_Level5_Shift => 57454,
        c.XKB_KEY_Shift_L => 57441,
        c.XKB_KEY_Control_L => 57442,
        c.XKB_KEY_Alt_L => 57443,
        c.XKB_KEY_Super_L => 57444,
        c.XKB_KEY_Hyper_L => 57445,
        c.XKB_KEY_Meta_L => 57446,
        c.XKB_KEY_Shift_R => 57447,
        c.XKB_KEY_Control_R => 57448,
        c.XKB_KEY_Alt_R => 57449,
        c.XKB_KEY_Super_R => 57450,
        c.XKB_KEY_Hyper_R => 57451,
        c.XKB_KEY_Meta_R => 57452,
        else => @intCast(c.xkb_keysym_to_utf32(symbol)),
    };
}
pub fn encode(buffer: []u8, symbol: u32, text: []const u8, mods: Modifiers) ![]const u8 {
    return Input.encodeKey(buffer, .{ .code = code(symbol), .text = text, .modifiers = mods }, .{});
}
/// Standard PC key names are independent of the active national layout.
pub fn baseKey(keymap: *c.xkb_keymap, keycode: u32) u21 {
    const ptr = c.xkb_keymap_key_get_name(keymap, keycode);
    if (ptr == null) return 0;
    const name = std.mem.span(ptr);
    const names = [_][]const u8{ "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07", "AE08", "AE09", "AE10", "AE11", "AE12", "AD01", "AD02", "AD03", "AD04", "AD05", "AD06", "AD07", "AD08", "AD09", "AD10", "AD11", "AD12", "AC01", "AC02", "AC03", "AC04", "AC05", "AC06", "AC07", "AC08", "AC09", "AC10", "AC11", "AB01", "AB02", "AB03", "AB04", "AB05", "AB06", "AB07", "AB08", "AB09", "AB10", "TLDE", "BKSL", "SPCE" };
    const values = "1234567890-=qwertyuiop[]asdfghjkl;'zxcvbnm,./`\\ ";
    for (names, 0..) |candidate, i| if (std.mem.eql(u8, name, candidate)) return values[i];
    return 0;
}
