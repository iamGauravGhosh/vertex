//! Bounded owned text rows. Images stay in the live screen's graphics budget.
const std = @import("std");
const Screen = @import("Screen.zig");
const History = @This();
pub const Row = struct { cells: []Screen.Cell, wrapped: bool, id: u64, bytes: usize };
allocator: std.mem.Allocator,
rows: std.ArrayList(Row) = .empty,
start: usize = 0,
bytes: usize = 0,
max_rows: usize,
max_bytes: usize,
next_id: u64 = 0,
generation: u64 = 0,

pub fn count(self: *const History) usize {
    return self.rows.items.len - self.start;
}
pub fn get(self: *const History, index: usize) ?Row {
    return if (index < self.count()) self.rows.items[self.start + index] else null;
}
pub fn cloneCell(allocator: std.mem.Allocator, cell: Screen.Cell) !Screen.Cell {
    var copy = cell;
    copy.grapheme = try allocator.dupe(u21, cell.grapheme);
    if (cell.link) |link| copy.link = link.retain();
    return copy;
}
pub fn freeCells(allocator: std.mem.Allocator, cells: []Screen.Cell) void {
    for (cells) |cell| {
        allocator.free(cell.grapheme);
        if (cell.link) |link| link.release();
    }
    allocator.free(cells);
}
pub fn cloneCells(allocator: std.mem.Allocator, cells: []const Screen.Cell) ![]Screen.Cell {
    const copy = try allocator.alloc(Screen.Cell, cells.len);
    var initialized: usize = 0;
    errdefer {
        for (copy[0..initialized]) |cell| {
            allocator.free(cell.grapheme);
            if (cell.link) |link| link.release();
        }
        allocator.free(copy);
    }
    for (cells, copy) |cell, *dest| {
        dest.* = try cloneCell(allocator, cell);
        initialized += 1;
    }
    return copy;
}
pub fn push(self: *History, cells: []const Screen.Cell, wrapped: bool) !void {
    if (self.max_rows == 0 or self.max_bytes == 0) {
        self.next_id += 1;
        self.generation +%= 1;
        return;
    }
    const copy = try cloneCells(self.allocator, cells);
    errdefer freeCells(self.allocator, copy);
    try self.pushOwned(copy, wrapped);
}
/// Ownership transfers only on success. IDs include rows evicted by the limits.
pub fn pushOwned(self: *History, cells: []Screen.Cell, wrapped: bool) !void {
    var size = cells.len * @sizeOf(Screen.Cell) + @sizeOf(Row);
    for (cells) |cell| {
        size += cell.grapheme.len * @sizeOf(u21);
        if (cell.link) |link| size += link.uri.len + link.id.len;
    }
    try self.rows.append(self.allocator, .{ .cells = cells, .wrapped = wrapped, .id = self.next_id, .bytes = size });
    self.next_id += 1;
    self.generation +%= 1;
    self.bytes += size;
    self.trim();
}
pub fn trim(self: *History) void {
    while (self.count() > self.max_rows or self.bytes > self.max_bytes) {
        const row = self.rows.items[self.start];
        self.bytes -= row.bytes;
        freeCells(self.allocator, row.cells);
        self.start += 1;
    }
    if (self.start > 256 and self.start >= self.rows.items.len / 2) {
        const n = self.count();
        std.mem.copyForwards(Row, self.rows.items[0..n], self.rows.items[self.start..]);
        self.rows.items.len = n;
        self.start = 0;
    }
}
pub fn clear(self: *History) void {
    for (self.rows.items[self.start..]) |row| freeCells(self.allocator, row.cells);
    self.rows.clearRetainingCapacity();
    self.start = 0;
    self.bytes = 0;
    self.generation +%= 1;
}
pub fn deinit(self: *History) void {
    self.clear();
    self.rows.deinit(self.allocator);
}
