//! Screen-local raster resources and placements. Pixel buffers are immutable RGBA.
const std = @import("std");
const Graphics = @This();
pub const max_transfer = 32 * 1024 * 1024;
pub const max_bitmap = 64 * 1024 * 1024;
pub const max_storage = 128 * 1024 * 1024;
pub const max_dimension = 8192;
pub const max_placements = 1024;
pub const Budget = struct { refs: usize = 1, used: usize = 0 };
var next_identity = std.atomic.Value(u64).init(1);
pub const Bitmap = struct {
    allocator: std.mem.Allocator,
    budget: *Budget,
    refs: usize = 1,
    identity: u64,
    width: usize,
    height: usize,
    /// Premultiplied RGBA, top row first.
    pixels: []u8,
    pub fn retain(self: *Bitmap) *Bitmap {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Bitmap) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.budget.used -= self.pixels.len;
        self.budget.refs -= 1;
        if (self.budget.refs == 0) self.allocator.destroy(self.budget);
        self.allocator.free(self.pixels);
        self.allocator.destroy(self);
    }
};
pub const Decoded = struct { width: usize, height: usize, pixels: []u8 };
/// Return straight-alpha RGBA owned by allocator. Called only on complete transfers.
pub const Decoder = *const fn (allocator: std.mem.Allocator, bytes: []const u8) anyerror!Decoded;
pub const Asset = struct { id: u32, number: u32 = 0, bitmap: *Bitmap };
pub const Placement = struct {
    bitmap: *Bitmap,
    image_id: u32 = 0,
    id: u32 = 0,
    protocol: enum { kitty, sixel, iterm },
    row: i32,
    column: i32,
    x: i32 = 0,
    y: i32 = 0,
    width: usize,
    height: usize,
    source_x: usize = 0,
    source_y: usize = 0,
    source_width: usize,
    source_height: usize,
    cell_width: usize,
    cell_height: usize,
    clip_top: i32 = 0,
    clip_bottom: i32,
    clip_left: i32 = 0,
    clip_right: i32,
    z: i32 = 0,
};
allocator: std.mem.Allocator,
budget: ?*Budget = null,
assets: std.ArrayList(Asset) = .empty,
placements: std.ArrayList(Placement) = .empty,
next_id: u32 = 1,

pub fn init(allocator: std.mem.Allocator) !Graphics {
    return .{ .allocator = allocator };
}
pub fn shareBudget(self: *Graphics, other: *Graphics) !void {
    std.debug.assert(self.assets.items.len == 0 and self.placements.items.len == 0);
    if (other.budget == null) {
        const budget = try self.allocator.create(Budget);
        budget.* = .{};
        other.budget = budget;
    }
    if (self.budget) |budget| {
        budget.refs -= 1;
        if (budget.refs == 0) self.allocator.destroy(budget);
    }
    self.budget = other.budget;
    self.budget.?.refs += 1;
}
pub fn deinit(self: *Graphics) void {
    self.clear();
    self.assets.deinit(self.allocator);
    self.placements.deinit(self.allocator);
    if (self.budget) |budget| {
        budget.refs -= 1;
        if (budget.refs == 0) self.allocator.destroy(budget);
    }
}
pub fn clear(self: *Graphics) void {
    for (self.placements.items) |p| p.bitmap.release();
    for (self.assets.items) |asset| asset.bitmap.release();
    self.placements.clearRetainingCapacity();
    self.assets.clearRetainingCapacity();
}
pub fn clone(self: *const Graphics) !Graphics {
    if (self.budget) |budget| budget.refs += 1;
    var result: Graphics = .{ .allocator = self.allocator, .budget = self.budget, .next_id = self.next_id };
    errdefer result.deinit();
    try result.assets.appendSlice(self.allocator, self.assets.items);
    for (result.assets.items) |asset| _ = asset.bitmap.retain();
    try result.placements.appendSlice(self.allocator, self.placements.items);
    for (result.placements.items) |p| _ = p.bitmap.retain();
    return result;
}
pub fn byteSize(width: usize, height: usize) !usize {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return error.ImageTooLarge;
    const n = width * height * 4;
    if (n > max_bitmap) return error.ImageTooLarge;
    return n;
}
/// Consumes decoded.pixels on success only.
pub fn bitmap(self: *Graphics, decoded: Decoded) !*Bitmap {
    const n = try byteSize(decoded.width, decoded.height);
    if (n != decoded.pixels.len) return error.InvalidImage;
    if (self.budget == null) {
        const budget = try self.allocator.create(Budget);
        budget.* = .{};
        self.budget = budget;
    }
    const budget = self.budget.?;
    if (budget.used + n > max_storage) return error.ImageTooLarge;
    const result = try self.allocator.create(Bitmap);
    budget.refs += 1;
    budget.used += n;
    result.* = .{ .allocator = self.allocator, .budget = budget, .identity = next_identity.fetchAdd(1, .monotonic), .width = decoded.width, .height = decoded.height, .pixels = decoded.pixels };
    var i: usize = 0;
    while (i < n) : (i += 4) for (0..3) |channel| {
        result.pixels[i + channel] = @intCast((@as(u32, result.pixels[i + channel]) * result.pixels[i + 3] + 127) / 255);
    };
    return result;
}
pub fn get(self: *const Graphics, id: u32, number: u32) ?Asset {
    var i = self.assets.items.len;
    while (i != 0) {
        i -= 1;
        const asset = self.assets.items[i];
        if ((id != 0 and asset.id == id) or (id == 0 and number != 0 and asset.number == number)) return asset;
    }
    return null;
}
pub fn put(self: *Graphics, requested: u32, number: u32, value: *Bitmap) !u32 {
    var id = requested;
    if (id == 0) {
        while (self.get(self.next_id, 0) != null or self.next_id == 0) self.next_id +%= 1;
        id = self.next_id;
        self.next_id +%= 1;
    }
    for (self.assets.items) |*asset| if (asset.id == id) {
        asset.bitmap.release();
        asset.* = .{ .id = id, .number = number, .bitmap = value.retain() };
        return id;
    };
    if (self.assets.items.len >= max_placements) return error.ImageTooLarge;
    try self.assets.ensureUnusedCapacity(self.allocator, 1);
    self.assets.appendAssumeCapacity(.{ .id = id, .number = number, .bitmap = value.retain() });
    return id;
}
pub fn preparePlacement(self: *Graphics, p: Placement) !void {
    var replacing = false;
    for (self.placements.items) |old| if (p.id != 0 and old.image_id == p.image_id and old.id == p.id) {
        replacing = true;
        break;
    };
    if (self.placements.items.len >= max_placements and !replacing) return error.ImageTooLarge;
    try self.placements.ensureUnusedCapacity(self.allocator, if (replacing) 0 else 1);
}
pub fn place(self: *Graphics, p: Placement) !void {
    try self.preparePlacement(p);
    // Placement IDs replace a previous placement of the same image.
    if (p.id != 0) self.delete(p.image_id, p.id, false);
    self.placements.appendAssumeCapacity(p);
    _ = p.bitmap.retain();
    // Kitty orders equal-z images by image ID.
    var i = self.placements.items.len - 1;
    while (i > 0 and (self.placements.items[i - 1].z > self.placements.items[i].z or (self.placements.items[i - 1].z == self.placements.items[i].z and self.placements.items[i - 1].image_id > self.placements.items[i].image_id))) : (i -= 1) std.mem.swap(Placement, &self.placements.items[i - 1], &self.placements.items[i]);
}

pub fn clip(self: *Graphics, rows: usize, columns: usize) void {
    var i: usize = 0;
    while (i < self.placements.items.len) {
        const p = &self.placements.items[i];
        const origin_x = @as(i64, p.column) * @as(i64, @intCast(p.cell_width)) + p.x;
        const origin_y = @as(i64, p.row) * @as(i64, @intCast(p.cell_height)) + p.y;
        p.clip_left = @intCast(@max(p.clip_left, -origin_x));
        p.clip_top = @intCast(@max(p.clip_top, -origin_y));
        p.clip_right = @intCast(@min(p.clip_right, @as(i64, @intCast(columns * p.cell_width)) - origin_x));
        p.clip_bottom = @intCast(@min(p.clip_bottom, @as(i64, @intCast(rows * p.cell_height)) - origin_y));
        if (p.clip_right <= p.clip_left or p.clip_bottom <= p.clip_top) {
            p.bitmap.release();
            _ = self.placements.orderedRemove(i);
        } else i += 1;
    }
}
pub fn delete(self: *Graphics, id: u32, placement: u32, data: bool) void {
    var i: usize = 0;
    while (i < self.placements.items.len) {
        const p = self.placements.items[i];
        if ((id == 0 or p.image_id == id) and (placement == 0 or p.id == placement)) {
            p.bitmap.release();
            _ = self.placements.orderedRemove(i);
        } else i += 1;
    }
    if (data) {
        i = 0;
        while (i < self.assets.items.len) {
            const asset = self.assets.items[i];
            if (id == 0 or asset.id == id) {
                asset.bitmap.release();
                _ = self.assets.orderedRemove(i);
            } else i += 1;
        }
    }
}
pub fn scroll(self: *Graphics, top: usize, bottom: usize, left: usize, right: usize, amount: i32) void {
    var i: usize = 0;
    while (i < self.placements.items.len) {
        const p = &self.placements.items[i];
        const x = p.column * @as(i32, @intCast(p.cell_width)) + p.x;
        const y = p.row * @as(i32, @intCast(p.cell_height)) + p.y;
        const t: i32 = @intCast(top * p.cell_height);
        const b: i32 = @intCast(bottom * p.cell_height);
        if (y + p.clip_top >= t and y + p.clip_bottom <= b and x + p.clip_left >= @as(i32, @intCast(left * p.cell_width)) and x + p.clip_right <= @as(i32, @intCast(right * p.cell_width))) {
            p.row += amount;
            const origin = p.row * @as(i32, @intCast(p.cell_height)) + p.y;
            p.clip_top = @max(p.clip_top, t - origin);
            p.clip_bottom = @min(p.clip_bottom, b - origin);
            if (p.clip_bottom <= p.clip_top) {
                p.bitmap.release();
                _ = self.placements.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

/// Erase inline image coverage. Kitty placements are explicitly managed by apps.
pub fn erase(self: *Graphics, row: usize, first: usize, end: usize) !void {
    var i: usize = 0;
    const count = self.placements.items.len;
    var visited: usize = 0;
    while (visited < count and i < self.placements.items.len) : (visited += 1) {
        const p = self.placements.items[i];
        if (p.protocol == .kitty) {
            i += 1;
            continue;
        }
        const x = p.column * @as(i32, @intCast(p.cell_width)) + p.x;
        const y = p.row * @as(i32, @intCast(p.cell_height)) + p.y;
        const l = @max(p.clip_left, @as(i32, @intCast(first * p.cell_width)) - x);
        const r = @min(p.clip_right, @as(i32, @intCast(end * p.cell_width)) - x);
        const t = @max(p.clip_top, @as(i32, @intCast(row * p.cell_height)) - y);
        const b = @min(p.clip_bottom, @as(i32, @intCast((row + 1) * p.cell_height)) - y);
        if (l >= r or t >= b) {
            i += 1;
            continue;
        }
        const fragments = [_][4]i32{ .{ p.clip_left, p.clip_top, p.clip_right, t }, .{ p.clip_left, b, p.clip_right, p.clip_bottom }, .{ p.clip_left, t, l, b }, .{ r, t, p.clip_right, b } };
        var n: usize = 0;
        for (fragments) |f| if (f[0] < f[2] and f[1] < f[3]) {
            n += 1;
        };
        if (self.placements.items.len - 1 + n > max_placements) {
            p.bitmap.release();
            _ = self.placements.orderedRemove(i);
            continue;
        }
        try self.placements.ensureUnusedCapacity(self.allocator, n);
        _ = self.placements.orderedRemove(i);
        for (fragments) |f| if (f[0] < f[2] and f[1] < f[3]) {
            var fragment = p;
            fragment.clip_left = f[0];
            fragment.clip_top = f[1];
            fragment.clip_right = f[2];
            fragment.clip_bottom = f[3];
            _ = fragment.bitmap.retain();
            self.placements.appendAssumeCapacity(fragment);
        };
        p.bitmap.release();
    }
}

/// Shift inline coverage with ICH/DCH, retaining unaffected portions of an image.
pub fn shift(self: *Graphics, row: usize, first: usize, end: usize, amount: i32) !void {
    const count = self.placements.items.len;
    var visited: usize = 0;
    var i: usize = 0;
    while (visited < count and i < self.placements.items.len) : (visited += 1) {
        const p = self.placements.items[i];
        if (p.protocol == .kitty) {
            i += 1;
            continue;
        }
        const x = p.column * @as(i32, @intCast(p.cell_width)) + p.x;
        const y = p.row * @as(i32, @intCast(p.cell_height)) + p.y;
        const l = @max(p.clip_left, @as(i32, @intCast(first * p.cell_width)) - x);
        const r = @min(p.clip_right, @as(i32, @intCast(end * p.cell_width)) - x);
        const t = @max(p.clip_top, @as(i32, @intCast(row * p.cell_height)) - y);
        const b = @min(p.clip_bottom, @as(i32, @intCast((row + 1) * p.cell_height)) - y);
        if (l >= r or t >= b) {
            i += 1;
            continue;
        }
        const fragments = [_][4]i32{ .{ p.clip_left, p.clip_top, p.clip_right, t }, .{ p.clip_left, b, p.clip_right, p.clip_bottom }, .{ p.clip_left, t, l, b }, .{ r, t, p.clip_right, b }, .{ l, t, r, b } };
        var n: usize = 0;
        for (fragments) |f| if (f[0] < f[2] and f[1] < f[3]) {
            n += 1;
        };
        if (self.placements.items.len - 1 + n > max_placements) return error.ImageTooLarge;
        try self.placements.ensureUnusedCapacity(self.allocator, n);
        _ = self.placements.orderedRemove(i);
        for (fragments, 0..) |f, part| if (f[0] < f[2] and f[1] < f[3]) {
            var fragment = p;
            fragment.clip_left = f[0];
            fragment.clip_top = f[1];
            fragment.clip_right = f[2];
            fragment.clip_bottom = f[3];
            if (part == 4) fragment.column += amount;
            _ = fragment.bitmap.retain();
            self.placements.appendAssumeCapacity(fragment);
        };
        p.bitmap.release();
    }
}
