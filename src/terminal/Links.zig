//! Owned OSC 8 targets and bounded URL recognition. No desktop I/O.
const std = @import("std");
const Screen = @import("Screen.zig");
pub const Target = struct {
    allocator: std.mem.Allocator,
    refs: usize = 1,
    uri: []u8,
    id: []u8,
    pub fn create(allocator: std.mem.Allocator, uri: []const u8, id: []const u8) !*Target {
        const target = try allocator.create(Target);
        errdefer allocator.destroy(target);
        const copy = try allocator.dupe(u8, uri);
        errdefer allocator.free(copy);
        target.* = .{ .allocator = allocator, .uri = copy, .id = try allocator.dupe(u8, id) };
        return target;
    }
    pub fn retain(self: *Target) *Target {
        self.refs += 1;
        return self;
    }
    pub fn release(self: *Target) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        allocator.free(self.uri);
        allocator.free(self.id);
        allocator.destroy(self);
    }
};

pub const Range = struct { first: usize, end: usize };
pub const Match = struct {
    /// Owned by the caller, even for an explicit link.
    uri: []u8,
    range: Range,
};

pub fn allowed(uri: []const u8) bool {
    if (uri.len == 0 or uri.len > 4096 or !std.unicode.utf8ValidateSlice(uri)) return false;
    for (uri) |b| if (b < 0x20 or b == 0x7f) return false;
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    const scheme = uri[0..colon];
    const rest = uri[colon + 1 ..];
    if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) {
        if (!std.mem.startsWith(u8, rest, "//")) return false;
        const host = std.mem.sliceTo(rest[2..], '/');
        return host.len != 0 and host[0] != '?' and host[0] != '#';
    }
    if (std.ascii.eqlIgnoreCase(scheme, "mailto")) return rest.len != 0;
    if (!std.ascii.eqlIgnoreCase(scheme, "file")) return false;
    if (std.mem.startsWith(u8, rest, "///")) return true;
    if (std.mem.startsWith(u8, rest, "//")) {
        const slash = std.mem.indexOfScalar(u8, rest[2..], '/') orelse return false;
        return std.ascii.eqlIgnoreCase(rest[2 .. 2 + slash], "localhost");
    }
    return std.mem.startsWith(u8, rest, "/");
}

/// Coordinates are logical cells. Only soft wraps join physical rows.
pub fn find(allocator: std.mem.Allocator, screen: *const Screen, row: usize, column: usize) !?Match {
    if (row >= screen.rows or column >= screen.columns) return null;
    const at = row * screen.columns + column;
    if (screen.cells[at].style.hidden) return null;
    if (screen.cells[at].link) |target| {
        if (!allowed(target.uri)) return null;
        var first = at;
        var end = at + 1;
        while (first > 0 and screen.cells[first - 1].link == target) : (first -= 1) {}
        while (end < screen.cells.len and screen.cells[end].link == target) : (end += 1) {}
        return .{ .uri = try allocator.dupe(u8, target.uri), .range = .{ .first = first, .end = end } };
    }
    var top = row;
    while (top > 0 and screen.soft_wrapped[top - 1]) : (top -= 1) {}
    var bottom = row;
    while (bottom + 1 < screen.rows and screen.soft_wrapped[bottom]) : (bottom += 1) {}
    // URL bytes map to source cells, so multibyte text cannot skew hit testing.
    var bytes: [8192]u8 = undefined;
    var positions: [8192]usize = undefined;
    var used: usize = 0;
    var truncated = false;
    for (top * screen.columns..(bottom + 1) * screen.columns) |index| {
        const cell = screen.cells[index];
        if (cell.width == 0) continue;
        const boundary = cell.style.hidden or cell.link != null or cell.codepoint <= 0x20 or cell.codepoint == 0x7f;
        const cluster = if (boundary) &[_]u21{' '} else screen.getGrapheme(index / screen.columns, index % screen.columns).?;
        var complete = true;
        for (cluster) |cp| {
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
            if (used + n > bytes.len) {
                complete = false;
                break;
            }
            @memcpy(bytes[used..][0..n], utf8[0..n]);
            @memset(positions[used..][0..n], index);
            used += n;
        }
        if (!complete) {
            truncated = true;
            break;
        }
    }
    var start: usize = 0;
    while (start < used) : (start += 1) {
        if (!std.ascii.startsWithIgnoreCase(bytes[start..used], "http://") and !std.ascii.startsWithIgnoreCase(bytes[start..used], "https://")) continue;
        if (start > 0 and (std.ascii.isAlphanumeric(bytes[start - 1]) or bytes[start - 1] == '_')) continue;
        var end = start;
        while (end < used and bytes[end] > 0x20 and std.mem.indexOfScalar(u8, "<>\"'`", bytes[end]) == null) : (end += 1) {}
        if (end == used and truncated) continue;
        while (end > start) {
            const last = bytes[end - 1];
            if (std.mem.indexOfScalar(u8, ".,;:!?", last) != null) {
                end -= 1;
                continue;
            }
            const open: u8 = switch (last) {
                ')' => '(',
                ']' => '[',
                '}' => '{',
                else => break,
            };
            if (std.mem.count(u8, bytes[start..end], &.{last}) > std.mem.count(u8, bytes[start..end], &.{open})) {
                end -= 1;
                continue;
            }
            break;
        }
        if (end > start and at >= positions[start] and at <= positions[end - 1] and allowed(bytes[start..end])) return .{
            .uri = try allocator.dupe(u8, bytes[start..end]),
            .range = .{ .first = positions[start], .end = positions[end - 1] + @as(usize, @max(1, screen.cells[positions[end - 1]].width)) },
        };
        start = @max(start, end -| 1);
    }
    return null;
}
