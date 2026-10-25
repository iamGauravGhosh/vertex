//! Bounded DEC Sixel raster decoder, including RGB/HLS color registers.
const std = @import("std");
const G = @import("Graphics.zig");
const Colors = @import("Colors.zig");
pub const Palette = [256]u32;
pub fn palette() Palette {
    @setEvalBranchQuota(10000);
    var colors: Palette = undefined;
    for (&colors, 0..) |*color, i| color.* = Colors.indexed(@intCast(i));
    return colors;
}
const Canvas = struct {
    allocator: std.mem.Allocator,
    pixels: []u8 = &.{},
    width: usize = 0,
    height: usize = 0,
    background: u32,
    transparent: bool,
    fn grow(self: *Canvas, width: usize, height: usize) !void {
        _ = try G.byteSize(width, height);
        if (width <= self.width and height <= self.height) return;
        const w = @max(width, self.width);
        const h = @max(height, self.height);
        const n = try G.byteSize(w, h);
        const pixels = try self.allocator.alloc(u8, n);
        var i: usize = 0;
        while (i < n) : (i += 4) pixels[i..][0..4].* = .{ @intCast(self.background >> 16), @intCast((self.background >> 8) & 255), @intCast(self.background & 255), if (self.transparent) 0 else 255 };
        for (0..self.height) |row| @memcpy(pixels[row * w * 4 ..][0 .. self.width * 4], self.pixels[row * self.width * 4 ..][0 .. self.width * 4]);
        self.allocator.free(self.pixels);
        self.pixels = pixels;
        self.width = w;
        self.height = h;
    }
};
fn number(bytes: []const u8, index: *usize) !usize {
    const begin = index.*;
    var n: usize = 0;
    while (index.* < bytes.len and std.ascii.isDigit(bytes[index.*])) : (index.* += 1) {
        n = std.math.mul(usize, n, 10) catch return error.InvalidImage;
        n = std.math.add(usize, n, bytes[index.*] - '0') catch return error.InvalidImage;
    }
    if (index.* == begin) return 0;
    return n;
}
fn parameters(bytes: []const u8, index: *usize, values: []usize) !usize {
    var n: usize = 0;
    while (true) {
        if (n >= values.len) return error.InvalidImage;
        values[n] = try number(bytes, index);
        n += 1;
        if (index.* == bytes.len or bytes[index.*] != ';') return n;
        index.* += 1;
    }
}
fn hls(h: usize, l: usize, s: usize) u32 {
    const hue = @as(f64, @floatFromInt((h + 240) % 360)) / 60;
    const light = @as(f64, @floatFromInt(l)) / 100;
    const saturation = @as(f64, @floatFromInt(s)) / 100;
    const chroma = (1 - @abs(2 * light - 1)) * saturation;
    const x = chroma * (1 - @abs(@mod(hue, 2) - 1));
    const rgb: [3]f64 = switch (@as(u8, @intFromFloat(hue))) {
        0 => .{ chroma, x, 0 },
        1 => .{ x, chroma, 0 },
        2 => .{ 0, chroma, x },
        3 => .{ 0, x, chroma },
        4 => .{ x, 0, chroma },
        else => .{ chroma, 0, x },
    };
    var result: u32 = 0;
    for (rgb) |value| result = (result << 8) | @as(u32, @intFromFloat(@round((value + light - chroma / 2) * 255)));
    return result;
}
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, params: [3]u16, colors: *Palette) !G.Decoded {
    var canvas: Canvas = .{ .allocator = allocator, .background = Colors.background, .transparent = params[1] == 1 };
    defer allocator.free(canvas.pixels);
    var x: usize = 0;
    var y: usize = 0;
    var width: usize = 0;
    var height: usize = 0;
    var selected: usize = 0;
    var aspect_x: usize = 1;
    var aspect_y: usize = switch (params[0]) {
        2 => 5,
        3, 4 => 3,
        7, 8, 9 => 1,
        else => 2,
    };
    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];
        i += 1;
        var repeat: usize = 1;
        var sixel = byte;
        switch (byte) {
            '!' => {
                repeat = @max(1, try number(bytes, &i));
                if (i == bytes.len) return error.InvalidImage;
                sixel = bytes[i];
                i += 1;
            },
            '#' => {
                var p: [5]usize = @splat(0);
                const n = try parameters(bytes, &i, &p);
                if (p[0] >= colors.len) return error.InvalidImage;
                selected = p[0];
                if (n == 1) continue;
                if (n != 5) return error.InvalidImage;
                if (p[1] == 2 and p[2] <= 100 and p[3] <= 100 and p[4] <= 100) colors[selected] = @as(u32, @intCast((p[2] * 255 + 50) / 100)) << 16 | @as(u32, @intCast((p[3] * 255 + 50) / 100)) << 8 | @as(u32, @intCast((p[4] * 255 + 50) / 100)) else if (p[1] == 1 and p[2] <= 360 and p[3] <= 100 and p[4] <= 100) colors[selected] = hls(p[2], p[3], p[4]) else return error.InvalidImage;
                continue;
            },
            '"' => {
                var p: [4]usize = @splat(0);
                const n = try parameters(bytes, &i, &p);
                if (n < 2 or p[0] == 0 or p[1] == 0 or p[0] > G.max_dimension or p[1] > G.max_dimension) return error.InvalidImage;
                const divisor = std.math.gcd(p[0], p[1]);
                aspect_y = p[0] / divisor;
                aspect_x = p[1] / divisor;
                if (n >= 3) width = @max(width, p[2]);
                if (n == 4) height = @max(height, p[3]);
                if (width > G.max_dimension or height > G.max_dimension) return error.ImageTooLarge;
                continue;
            },
            '$' => {
                x = 0;
                continue;
            },
            '-' => {
                y += 6;
                x = 0;
                if (y >= G.max_dimension) return error.ImageTooLarge;
                continue;
            },
            0...0x20, 0x7f => continue,
            else => {},
        }
        if (sixel < '?' or sixel > '~') return error.InvalidImage;
        if (repeat > G.max_dimension or x + repeat > G.max_dimension or y + 6 > G.max_dimension) return error.ImageTooLarge;
        // Geometric width growth avoids quadratic reallocations for each sixel.
        const requested = @max(x + repeat, @min(G.max_dimension, @max(64, canvas.width * 2)));
        if (x + repeat > canvas.width or y + 6 > canvas.height) {
            const grow_width = if (x + repeat > canvas.width) requested else canvas.width;
            const grow_height = @max(y + 6, @min(G.max_dimension, @max(6, canvas.height * 2)));
            if (grow_width * grow_height * 4 <= G.max_bitmap) try canvas.grow(grow_width, grow_height) else try canvas.grow(@max(canvas.width, x + repeat), @max(canvas.height, y + 6));
        }
        const bits = sixel - '?';
        for (x..x + repeat) |column| for (0..6) |bit| {
            if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            const offset = ((y + bit) * canvas.width + column) * 4;
            const rgb = colors[selected];
            canvas.pixels[offset..][0..4].* = .{ @intCast(rgb >> 16), @intCast((rgb >> 8) & 255), @intCast(rgb & 255), 255 };
        };
        x += repeat;
        width = @max(width, x);
        height = @max(height, y + 6);
    }
    if (width == 0 or height == 0) return error.InvalidImage;
    const w = std.math.mul(usize, width, aspect_x) catch return error.ImageTooLarge;
    const h = std.math.mul(usize, height, aspect_y) catch return error.ImageTooLarge;
    const pixels = try allocator.alloc(u8, try G.byteSize(w, h));
    for (0..h) |row| for (0..w) |col| {
        const sy = row / aspect_y;
        const sx = col / aspect_x;
        const dest = pixels[(row * w + col) * 4 ..][0..4];
        if (sy < canvas.height and sx < canvas.width) @memcpy(dest, canvas.pixels[(sy * canvas.width + sx) * 4 ..][0..4]) else dest.* = .{ @intCast(Colors.background >> 16), @intCast((Colors.background >> 8) & 255), @intCast(Colors.background & 255), if (canvas.transparent) 0 else 255 };
    };
    return .{ .width = w, .height = h, .pixels = pixels };
}
