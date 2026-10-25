//! Font-independent terminal graphics. Coordinates are cell-local physical pixels.
const std = @import("std");
const data = @import("box_data.zig");

pub fn supports(cp: u21) bool {
    return (cp >= 0x2500 and cp <= 0x259f) or (cp >= 0x2800 and cp <= 0x28ff) or (cp >= 0xe0b0 and cp <= 0xe0b3);
}

pub fn alpha(cp: u21, x: usize, y: usize, width: usize, height: usize) u8 {
    if (cp >= 0x2580 and cp <= 0x259f) return block(cp, x, y, width, height);
    if (cp >= 0x2800 and cp <= 0x28ff) return braille(cp, x, y, width, height);
    if (cp >= 0x2500 and cp <= 0x257f and !(cp >= 0x256d and cp <= 0x2573)) return box(cp, x, y, width, height);
    // Supersample only curved and diagonal edges; ordinary strokes stay pixel aligned.
    var covered: u32 = 0;
    for (0..4) |sy| for (0..4) |sx| {
        if (smooth(cp, @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4, @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4, @floatFromInt(width), @floatFromInt(height))) covered += 1;
    };
    return @intCast((covered * 255 + 8) / 16);
}

fn block(cp: u21, x: usize, y: usize, w: usize, h: usize) u8 {
    const on = switch (cp) {
        0x2580 => y < h / 2,
        0x2581...0x2587 => y >= h * (0x2588 - @as(usize, cp)) / 8,
        0x2588 => true,
        0x2589...0x258f => x < (w * (0x2590 - @as(usize, cp)) + 7) / 8,
        0x2590 => x >= (w + 1) / 2,
        0x2591 => return 64,
        0x2592 => return 128,
        0x2593 => return 192,
        0x2594 => y < @max(1, h / 8),
        0x2595 => x >= w - @max(1, w / 8),
        else => blk: {
            const masks = [_]u4{ 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
            const quadrant: u2 = @as(u2, @intFromBool(x >= (w + 1) / 2)) + 2 * @as(u2, @intFromBool(y >= h / 2));
            break :blk masks[cp - 0x2596] & (@as(u4, 1) << quadrant) != 0;
        },
    };
    return if (on) 255 else 0;
}

fn braille(cp: u21, x: usize, y: usize, w: usize, h: usize) u8 {
    const col: usize = @min(1, x * 2 / w);
    const row: usize = @min(3, y * 4 / h);
    const bits = [2][4]u3{ .{ 0, 1, 2, 6 }, .{ 3, 4, 5, 7 } };
    if ((cp - 0x2800) & (@as(u21, 1) << bits[col][row]) == 0) return 0;
    const cx = (2 * col + 1) * w / 4;
    const cy = (2 * row + 1) * h / 8;
    const dx = @as(i64, @intCast(x)) - @as(i64, @intCast(cx));
    const dy = @as(i64, @intCast(y)) - @as(i64, @intCast(cy));
    const rx: i64 = @intCast(@max(1, w / 6));
    const ry: i64 = @intCast(@max(1, h / 12));
    return if (dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry) 255 else 0;
}

fn stripe(pos: i64, center: i64, weight: u2, light: i64) bool {
    if (weight == 0) return false;
    if (weight == 3) return stripe(pos, center - light, 1, light) or stripe(pos, center + light, 1, light);
    const thickness = if (weight == 2) light * 2 else light;
    return pos >= center - @divTrunc(thickness, 2) and pos < center + @divTrunc(thickness + 1, 2);
}

fn box(cp: u21, x: usize, y: usize, w: usize, h: usize) u8 {
    const spec = data.boxes[cp - 0x2500];
    const px: i64 = @intCast(x);
    const py: i64 = @intCast(y);
    const cx: i64 = @intCast(w / 2);
    const cy: i64 = @intCast(h / 2);
    const light: i64 = @intCast(@max(1, (w + 4) / 8));
    const a = spec.arms;
    // Extend arms through the intersection far enough to join perpendicular strokes.
    var on = false;
    for (0..4) |arm| {
        if (a[arm] == 0) continue;
        const horizontal = arm < 2;
        const position = if (horizontal) px else py;
        const cross = if (horizontal) py else px;
        const center = if (horizontal) cx else cy;
        const cross_center = if (horizontal) cy else cx;
        const negative = arm == 0 or arm == 2;
        const before = a[if (horizontal) 2 else 0];
        const after = a[if (horizontal) 3 else 1];
        const extent = if (before == 3 or after == 3) light else if (before == 2 or after == 2) @divTrunc(light + 1, 2) else 0;
        for (0..(if (a[arm] == 3) @as(usize, 2) else 1)) |line| {
            const offset = if (a[arm] == 3) (if (line == 0) -light else light) else 0;
            var end = center + (if (negative) extent else -extent);
            // Double corners turn each rail independently, leaving the center open.
            if (a[arm] == 3 and ((before == 3 and after == 0) or (before == 0 and after == 3))) {
                const direction: i64 = if (after != 0) 1 else -1;
                end = center + (if (negative) -direction * offset else direction * offset);
            }
            if ((if (negative) position <= end else position >= end) and stripe(cross, cross_center + offset, if (a[arm] == 3) 1 else a[arm], light)) on = true;
        }
    }
    if (spec.dash != 0) {
        const horizontal = a[0] != 0 or a[1] != 0;
        const position = if (horizontal) x else y;
        const length = if (horizontal) w else h;
        // Half-pixel phases produce equal dash lengths in neighboring cells.
        on = on and ((position * 2 + 1) * spec.dash % (length * 2) < length * 3 / 2);
    }
    return if (on) 255 else 0;
}

fn smooth(cp: u21, x: f64, y: f64, w: f64, h: f64) bool {
    const light = @max(1, @floor((w + 4) / 8));
    const cx = @floor(w / 2) + (if (@as(usize, @intFromFloat(light)) % 2 == 1) @as(f64, 0.5) else 0);
    const cy = @floor(h / 2) + (if (@as(usize, @intFromFloat(light)) % 2 == 1) @as(f64, 0.5) else 0);
    if (cp >= 0xe0b0 and cp <= 0xe0b3) {
        const px = if (cp >= 0xe0b2) w - x else x;
        const edge = w * (1 - @abs(2 * y / h - 1));
        return if (cp & 1 == 0) px <= edge else @abs(px - edge) <= light * @sqrt(1 + 4 * w * w / (h * h)) / 2;
    }
    if (cp >= 0x2571 and cp <= 0x2573) {
        const thickness = light * @sqrt(w * w + h * h) / 2;
        return (cp != 0x2572 and @abs(x * h + y * w - w * h) <= thickness) or
            (cp != 0x2571 and @abs(x * h - y * w) <= thickness);
    }
    const right = cp == 0x256d or cp == 0x2570;
    const down = cp == 0x256d or cp == 0x256e;
    const px = if (right) x - cx else cx - x;
    const py = if (down) y - cy else cy - y;
    const radius = @min(w / 2, h / 2) * 0.8;
    if (px >= radius) return @abs(py) <= light / 2;
    if (py >= radius) return @abs(px) <= light / 2;
    return px >= -light / 2 and py >= -light / 2 and @abs(@sqrt((px - radius) * (px - radius) + (py - radius) * (py - radius)) - radius) <= light / 2;
}

test "full blocks halves quadrants and straight borders connect on odd and even grids" {
    const t = std.testing;
    for ([_]usize{ 9, 10, 20 }) |w| for ([_]usize{ 19, 22, 44 }) |h| {
        for (0..h) |y| for (0..w) |x| {
            try t.expectEqual(@as(u8, 255), alpha(0x2588, x, y, w, h));
            try t.expectEqual(@as(u16, 255), @as(u16, alpha(0x2580, x, y, w, h)) + alpha(0x2584, x, y, w, h));
            try t.expectEqual(@as(u16, 255), @as(u16, alpha(0x258c, x, y, w, h)) + alpha(0x2590, x, y, w, h));
        };
        for (0..h) |y| try t.expectEqual(alpha(0x2500, 0, y, w, h), alpha(0x2500, w - 1, y, w, h));
        for (0..w) |x| try t.expectEqual(alpha(0x2502, x, 0, w, h), alpha(0x2502, x, h - 1, w, h));
    };
}

test "box stroke metadata connects all ordinary junctions and double corners leave their centers open" {
    const t = std.testing;
    const w = 10;
    const h = 23;
    for (data.boxes, 0..) |spec, i| {
        const cp: u21 = @intCast(0x2500 + i);
        if ((cp >= 0x256d and cp <= 0x2573) or spec.dash != 0) continue;
        for (0..4) |arm| {
            var edge = false;
            for (0..(if (arm < 2) h else w)) |pos| {
                edge = edge or alpha(cp, if (arm < 2) (if (arm == 0) 0 else w - 1) else pos, if (arm >= 2) (if (arm == 2) 0 else h - 1) else pos, w, h) != 0;
            }
            try t.expectEqual(spec.arms[arm] != 0, edge);
        }
    }
    for ([_]u21{ 0x2554, 0x2557, 0x255a, 0x255d, 0x256c }) |cp| try t.expectEqual(@as(u8, 0), alpha(cp, w / 2, h / 2, w, h));
    for ([_]u21{ 0x256d, 0x256e, 0x256f, 0x2570 }) |cp| {
        try t.expectEqual(@as(u8, 0), alpha(cp, w / 2, h / 2, w, h));
    }
}
