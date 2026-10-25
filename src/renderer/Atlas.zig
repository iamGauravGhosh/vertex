//! Bounded premultiplied RGBA pages. Handles are borrowed until the next insertion.
const std = @import("std");
const Atlas = @This();
pub const size = 1024;
pub const tile_size = size - 2;
pub const page_count = 4;
pub const Key = struct { glyph: u64, width: u32 = 0, height: u32 = 0, x: u32 = 0, y: u32 = 0 };
pub const Region = struct { page: usize, x: usize, y: usize, width: usize, height: usize, color: bool = false };
pub const Page = struct {
    pixels: []u8 = &.{},
    entries: std.AutoHashMapUnmanaged(Key, Region) = .empty,
    x: usize = 1,
    y: usize = 1,
    shelf: usize = 0,
    used: u64 = 0,
    revision: u64 = 0,
};
allocator: std.mem.Allocator,
pages: [page_count]Page = @splat(.{}),
clock: u64 = 0,

pub fn init(allocator: std.mem.Allocator) Atlas {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Atlas) void {
    for (&self.pages) |*page| {
        if (page.pixels.len != 0) self.allocator.free(page.pixels);
        page.entries.deinit(self.allocator);
    }
}

pub fn clear(self: *Atlas) void {
    for (&self.pages) |*page| reset(page);
}

fn reset(page: *Page) void {
    page.entries.clearRetainingCapacity();
    page.x = 1;
    page.y = 1;
    page.shelf = 0;
    page.revision +%= 1;
    @memset(page.pixels, 0);
}

pub fn get(self: *Atlas, key: Key) ?Region {
    self.clock +%= 1;
    for (&self.pages) |*page| if (page.entries.get(key)) |region| {
        page.used = self.clock;
        return region;
    };
    return null;
}

/// Caller must flush texture-dependent draws before inserting/recycling pages.
pub fn insert(self: *Atlas, key: Key, width: usize, height: usize, source: []const u8, stride: usize) !Region {
    return self.insertPixels(key, width, height, source, stride, false);
}

pub fn insertColor(self: *Atlas, key: Key, width: usize, height: usize, source: []const u8, stride: usize) !Region {
    return self.insertPixels(key, width, height, source, stride, true);
}
fn insertPixels(self: *Atlas, key: Key, width: usize, height: usize, source: []const u8, stride: usize, color: bool) !Region {
    std.debug.assert(width > 0 and width <= tile_size and height > 0 and height <= tile_size);
    var selected: usize = 0;
    var found = false;
    for (&self.pages, 0..) |*page, i| {
        if (page.x + width + 1 > size and page.y + page.shelf + height + 3 <= size) {
            page.y += page.shelf + 2;
            page.x = 1;
            page.shelf = 0;
        }
        if (page.x + width + 1 <= size and page.y + height + 1 <= size) {
            selected = i;
            found = true;
            break;
        }
        if (page.used < self.pages[selected].used) selected = i;
    }
    const page = &self.pages[selected];
    if (!found) reset(page);
    if (page.pixels.len == 0) {
        page.pixels = try self.allocator.alloc(u8, size * size * 4);
        @memset(page.pixels, 0);
    }
    const region: Region = .{ .page = selected, .x = page.x, .y = page.y, .width = width, .height = height, .color = color };
    try page.entries.put(self.allocator, key, region);
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = ((page.y + y) * size + page.x + x) * 4;
            if (color) @memcpy(page.pixels[offset..][0..4], source[y * stride + x * 4 ..][0..4]) else @memset(page.pixels[offset..][0..4], source[y * stride + x]);
        }
    }
    page.x += width + 2;
    page.shelf = @max(page.shelf, height);
    self.clock +%= 1;
    page.used = self.clock;
    page.revision +%= 1;
    return region;
}

test "atlas packs, reuses, evicts LRU pages, and keeps padding clear" {
    var atlas = init(std.testing.allocator);
    defer atlas.deinit();
    const data = try std.testing.allocator.alloc(u8, tile_size * tile_size);
    defer std.testing.allocator.free(data);
    @memset(data, 123);
    for (0..page_count) |i| {
        const region = try atlas.insert(.{ .glyph = i }, tile_size, tile_size, data, tile_size);
        try std.testing.expectEqual(i, region.page);
        try std.testing.expectEqual(@as(u8, 0), atlas.pages[i].pixels[0]);
        try std.testing.expectEqual(@as(u8, 123), atlas.pages[i].pixels[(size + 1) * 4 + 3]);
    }
    _ = atlas.get(.{ .glyph = 0 });
    const next = try atlas.insert(.{ .glyph = 4 }, tile_size, tile_size, data, tile_size);
    try std.testing.expectEqual(@as(usize, 1), next.page);
    try std.testing.expect(atlas.get(.{ .glyph = 1 }) == null);
    try std.testing.expect(atlas.get(.{ .glyph = 0 }) != null);
    atlas.clear();
    for (atlas.pages) |page| try std.testing.expectEqual(@as(u32, 0), page.entries.count());
}
