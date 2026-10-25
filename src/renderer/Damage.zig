//! Presentation damage remains pending until commit, independently of buffer age.
const std = @import("std");
const vt = @import("../terminal/root.zig");
const Damage = @This();
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
allocator: std.mem.Allocator,
rows: []bool = &.{},
rects: std.ArrayList(Rect) = .empty,
cursor: ?vt.Cursor = null,
width: usize = 0,
height: usize = 0,
invalid: bool = true,
origin_y: usize = 0,
full: bool = true,

pub fn init(allocator: std.mem.Allocator) Damage {
    return .{ .allocator = allocator };
}
pub fn deinit(self: *Damage) void {
    self.allocator.free(self.rows);
    self.rects.deinit(self.allocator);
}
pub fn invalidate(self: *Damage) void {
    self.invalid = true;
}
pub fn prepare(self: *Damage, screen: *const vt.Screen, width: usize, height: usize, cell_height: usize) !bool {
    if (self.rows.len != screen.rows) {
        const replacement = try self.allocator.alloc(bool, screen.rows);
        self.allocator.free(self.rows);
        self.rows = replacement;
        self.invalid = true;
    }
    self.full = self.invalid or width != self.width or height != self.height;
    self.width = width;
    self.height = height;
    @memcpy(self.rows, screen.getDamageRows());
    if (self.full) @memset(self.rows, true);
    const cursor = screen.getCursor();
    if (self.cursor) |old| {
        if (!std.meta.eql(old, cursor)) {
            if (old.visible and old.row < self.rows.len) self.rows[old.row] = true;
            if (cursor.visible) self.rows[cursor.row] = true;
        }
    } else if (cursor.visible) self.rows[cursor.row] = true;
    self.rects.clearRetainingCapacity();
    if (self.full) {
        try self.rects.append(self.allocator, .{ .x = 0, .y = 0, .width = @intCast(width), .height = @intCast(height) });
    } else {
        var row: usize = 0;
        while (row < self.rows.len) {
            if (!self.rows[row]) {
                row += 1;
                continue;
            }
            const first = row;
            while (row < self.rows.len and self.rows[row]) : (row += 1) {}
            const y = @min(height, self.origin_y + first * cell_height);
            const bottom = @min(height, self.origin_y + row * cell_height);
            if (bottom > y) try self.rects.append(self.allocator, .{ .x = 0, .y = @intCast(y), .width = @intCast(width), .height = @intCast(bottom - y) });
        }
    }
    return self.rects.items.len != 0;
}
pub fn commit(self: *Damage, screen: *vt.Screen) void {
    self.cursor = screen.getCursor();
    self.invalid = false;
    screen.clearDamage();
}

test "damage merges rows, retains deferred updates, and tracks cursor independently" {
    const t = std.testing;
    var screen = try vt.Screen.init(t.allocator, 4, 5);
    defer screen.deinit();
    var damage = init(t.allocator);
    defer damage.deinit();
    try t.expect(try damage.prepare(&screen, 50, 45, 10));
    try t.expect(damage.full);
    damage.commit(&screen);
    try t.expect(!try damage.prepare(&screen, 50, 45, 10));
    var parser = vt.Parser.init();
    parser.feed("\x1b[31m\x1b]0;ignored\x07", &screen);
    try t.expect(!try damage.prepare(&screen, 50, 45, 10));
    parser.feed("\x1b[3;1HX", &screen);
    try t.expect(try damage.prepare(&screen, 50, 45, 10));
    try t.expect(damage.rows[0] and damage.rows[2]);
    parser.feed("\x1b[4;1HY", &screen);
    try t.expect(try damage.prepare(&screen, 50, 45, 10));
    try t.expect(damage.rows[0] and damage.rows[2] and damage.rows[3]);
    try t.expectEqual(@as(usize, 2), damage.rects.items.len);
    damage.commit(&screen);
    parser.feed("\x1b[?25l", &screen);
    try t.expect(try damage.prepare(&screen, 50, 45, 10));
    try t.expect(damage.rows[3]);
    damage.commit(&screen);
    parser.feed("\x1b[1;1H", &screen);
    try t.expect(!try damage.prepare(&screen, 50, 45, 10));
    damage.invalidate();
    try t.expect(try damage.prepare(&screen, 50, 45, 10));
    try t.expect(damage.full);
}
