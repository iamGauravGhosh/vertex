//! OS-independent terminal input events and wire encodings.
const std = @import("std");
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    control: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn value(self: Modifiers) u16 {
        return 1 + @as(u16, @as(u8, @bitCast(self)));
    }
};
pub const Action = enum(u8) { press = 1, repeat = 2, release = 3 };
pub const Key = struct {
    /// Unicode unshifted key or Kitty functional key number.
    code: u21,
    shifted: u21 = 0,
    base: u21 = 0,
    text: []const u8 = "",
    modifiers: Modifiers = .{},
    action: Action = .press,
};
pub const Modes = struct {
    kitty: u5 = 0,
    modify_other_keys: u2 = 0,
    application_cursor: bool = false,
    application_keypad: bool = false,
    bracketed_paste: bool = false,
    mouse_tracking: u16 = 0,
    mouse_sgr: bool = false,
    mouse_pixels: bool = false,
    focus: bool = false,
};

pub fn encodeKey(buffer: []u8, event: Key, modes: Modes) ![]const u8 {
    var key = event;
    key.code = switch (key.code) {
        27 => 57344,
        13 => 57345,
        9 => 57346,
        127 => 57347,
        else => key.code,
    };
    const mods = key.modifiers;
    const flags = modes.kitty;
    const all = flags & 8 != 0;
    const special = key.code >= 57344 and key.code <= 57454;
    if (key.code >= 57441 and key.code <= 57454 and flags & 8 == 0) return buffer[0..0];
    const ordinary_control = key.code == 57345 or key.code == 57346 or key.code == 57347;
    const enhanced = all or (flags & 1 != 0 and ((!ordinary_control and special) or mods.control or mods.alt or (ordinary_control and mods.shift))) or (flags & 2 != 0 and special and !ordinary_control) or
        (special and ((key.code >= 57376 and key.code <= 57398) or (key.code >= 57428 and key.code <= 57440)) and key.text.len == 0);
    if (key.action == .release and (flags & 2 == 0 or !enhanced)) return buffer[0..0];
    if (enhanced) {
        var stream = std.Io.Writer.fixed(buffer);
        const functional = if (key.code == 57366) null else legacyFunctional(key.code);
        const tilde = if (key.code == 57366) @as(?u8, 13) else legacyNumber(key.code);
        const canonical = functional == null and tilde == null;
        const wire_code: u21 = switch (key.code) {
            57344 => 27,
            57345 => 13,
            57346 => 9,
            57347 => 127,
            else => key.code,
        };
        try stream.print("\x1b[{d}", .{if (canonical) wire_code else if (tilde) |n| n else @as(u21, 1)});
        const alternate_shift = mods.shift and key.shifted != 0 and key.shifted != key.code;
        if (canonical and flags & 4 != 0 and (alternate_shift or key.base != 0)) {
            try stream.writeByte(':');
            if (alternate_shift) try stream.print("{d}", .{key.shifted});
            if (key.base != 0) try stream.print(":{d}", .{key.base});
        }
        try stream.print(";{d}", .{mods.value()});
        if (flags & 2 != 0) try stream.print(":{d}", .{@backingInt(key.action)});
        if (all and flags & 16 != 0 and key.action != .release and key.text.len != 0) {
            try stream.writeByte(';');
            var iter = (try std.unicode.Utf8View.init(key.text)).iterator();
            var first = true;
            while (iter.nextCodepoint()) |cp| {
                if (cp < 32 or (cp >= 127 and cp <= 159)) continue;
                if (!first) try stream.writeByte(':');
                try stream.print("{d}", .{cp});
                first = false;
            }
        }
        try stream.writeByte(if (canonical) 'u' else if (tilde != null) '~' else functional.?);
        return stream.buffered();
    }
    if (key.action == .release) return buffer[0..0];
    const modifier = 1 + (@as(u8, @bitCast(mods)) & 0x3f);
    if (modes.modify_other_keys != 0 and (!special or ordinary_control) and
        ((modes.modify_other_keys == 2 and (mods.shift or mods.alt or mods.control or mods.super or mods.meta)) or
            (modes.modify_other_keys == 1 and (mods.alt or mods.super or mods.meta))))
    {
        const cp: u21 = switch (key.code) {
            57345 => 13,
            57346 => 9,
            57347 => 127,
            else => if (mods.shift and key.shifted != 0) key.shifted else key.code,
        };
        return std.fmt.bufPrint(buffer, "\x1b[27;{d};{d}~", .{ modifier, cp });
    }
    const legacy_code: u21 = switch (key.code) {
        57417 => 57350,
        57418 => 57351,
        57419 => 57352,
        57420 => 57353,
        57421 => 57354,
        57422 => 57355,
        57423 => 57356,
        57424 => 57357,
        57425 => 57348,
        57426 => 57349,
        else => key.code,
    };
    if (legacyFunctional(legacy_code)) |final| return if (modifier != 1)
        std.fmt.bufPrint(buffer, "\x1b[1;{d}{c}", .{ modifier, final })
    else
        std.fmt.bufPrint(buffer, "\x1b{c}{c}", .{ @as(u8, if ((legacy_code >= 57364 and legacy_code <= 57367) or modes.application_cursor) 'O' else '['), final });
    if (legacyNumber(legacy_code)) |n| return if (modifier == 1)
        std.fmt.bufPrint(buffer, "\x1b[{d}~", .{n})
    else
        std.fmt.bufPrint(buffer, "\x1b[{d};{d}~", .{ n, modifier });
    if (key.code >= 57399 and key.code <= 57416 and modes.application_keypad) {
        const finals = "pqrstuvwxyonjmkMXl";
        return std.fmt.bufPrint(buffer, "\x1bO{c}", .{finals[key.code - 57399]});
    }
    var byte: [1]u8 = undefined;
    const text: []const u8 = switch (key.code) {
        57344 => "\x1b",
        57345, 57414 => "\r",
        57346 => if (mods.shift) return std.fmt.bufPrint(buffer, "\x1b[Z", .{}) else "\t",
        57347 => if (mods.control) "\x08" else "\x7f",
        else => blk: {
            if (mods.control) {
                const cp = if (key.code >= 'a' and key.code <= 'z') key.code - 32 else key.code;
                byte[0] = switch (cp) {
                    '@'...'_' => @intCast(cp & 31),
                    ' ', '2' => 0,
                    '3' => 27,
                    '4' => 28,
                    '5' => 29,
                    '6', '~' => 30,
                    '7', '/' => 31,
                    '8', '?' => 127,
                    else => break :blk key.text,
                };
                break :blk &byte;
            }
            break :blk key.text;
        },
    };
    if (text.len == 0) return buffer[0..0];
    const prefix: usize = @intFromBool(mods.alt);
    if (text.len + prefix > buffer.len) return error.NoSpaceLeft;
    if (mods.alt) buffer[0] = 27;
    @memcpy(buffer[prefix..][0..text.len], text);
    return buffer[0 .. text.len + prefix];
}

fn legacyFunctional(code: u21) ?u8 {
    return switch (code) {
        57350 => 'D',
        57351 => 'C',
        57352 => 'A',
        57353 => 'B',
        57356 => 'H',
        57357 => 'F',
        57427 => 'E',
        57364...57367 => @intCast('P' + code - 57364),
        else => null,
    };
}
fn legacyNumber(code: u21) ?u8 {
    return switch (code) {
        57348 => 2,
        57349 => 3,
        57354 => 5,
        57355 => 6,
        57368 => 15,
        57369 => 17,
        57370 => 18,
        57371 => 19,
        57372 => 20,
        57373 => 21,
        57374 => 23,
        57375 => 24,
        else => null,
    };
}

pub const Pointer = struct {
    kind: enum { press, release, motion, wheel },
    /// Xterm button: left=0, middle=1, right=2, wheel=64..67.
    button: u8 = 3,
    column: usize,
    row: usize,
    x: usize = 0,
    y: usize = 0,
    modifiers: Modifiers = .{},
};
pub fn encodePointer(buffer: []u8, event: Pointer, modes: Modes) ![]const u8 {
    const tracking = modes.mouse_tracking;
    if (tracking == 0 or event.modifiers.shift) return buffer[0..0];
    if (tracking == 9 and event.kind != .press) return buffer[0..0];
    if (event.kind == .motion and (tracking == 9 or tracking == 1000 or (tracking == 1002 and event.button == 3))) return buffer[0..0];
    var button: u16 = event.button;
    if (event.kind == .motion) button |= 32;
    if (tracking != 9) button |= @as(u16, @intFromBool(event.modifiers.shift)) * 4 + @as(u16, @intFromBool(event.modifiers.alt)) * 8 + @as(u16, @intFromBool(event.modifiers.control)) * 16;
    if (event.button > 67) return error.InvalidButton;
    const x = std.math.add(usize, if (modes.mouse_pixels) event.x else event.column, 1) catch return error.InvalidCoordinates;
    const y = std.math.add(usize, if (modes.mouse_pixels) event.y else event.row, 1) catch return error.InvalidCoordinates;
    if (modes.mouse_sgr or modes.mouse_pixels) return std.fmt.bufPrint(buffer, "\x1b[<{d};{d};{d}{c}", .{ button, x, y, @as(u8, if (event.kind == .release) 'm' else 'M') });
    if (x > 223 or y > 223) return buffer[0..0];
    if (buffer.len < 6) return error.NoSpaceLeft;
    @memcpy(buffer[0..3], "\x1b[M");
    buffer[3] = @intCast((if (event.kind == .release) (button & 28) | 3 else button) + 32);
    buffer[4] = @intCast(x + 32);
    buffer[5] = @intCast(y + 32);
    return buffer[0..6];
}

pub const max_paste_bytes = 8 * 1024 * 1024;
/// Build one transaction before exposing any bytes to the PTY.
pub fn paste(allocator: std.mem.Allocator, text: []const u8, bracketed: bool) ![]u8 {
    if (text.len > max_paste_bytes) return error.PasteTooLarge;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, text.len + 12);
    if (bracketed) output.appendSliceAssumeCapacity("\x1b[200~");
    var cr = false;
    for (text) |byte| {
        if (byte == 0 or byte == 27) continue;
        if (byte == 10) {
            if (!cr) output.appendAssumeCapacity(13);
        } else output.appendAssumeCapacity(byte);
        cr = byte == 13;
    }
    if (bracketed) output.appendSliceAssumeCapacity("\x1b[201~");
    return output.toOwnedSlice(allocator);
}
