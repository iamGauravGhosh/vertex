//! Bounded OSC routing and incremental OSC 52 decoding. No OS access.
const std = @import("std");
const Strings = @This();
pub const max_clipboard_bytes = 8 * 1024 * 1024;
small: [4096]u8 = undefined,
used: usize = 0,
invalid: bool = false,
is_clipboard: bool = false,
padded: bool = false,
quartet: [4]u8 = undefined,
quartet_len: usize = 0,
decoded: std.ArrayList(u8) = .empty,
clipboard: ?[]u8 = null,

pub fn deinit(self: *Strings, allocator: std.mem.Allocator) void {
    self.decoded.deinit(allocator);
    if (self.clipboard) |bytes| allocator.free(bytes);
}
pub fn begin(self: *Strings) void {
    self.used = 0;
    self.invalid = false;
    self.is_clipboard = false;
    self.padded = false;
    self.quartet_len = 0;
    self.decoded.clearRetainingCapacity();
}
pub fn byte(self: *Strings, allocator: std.mem.Allocator, value: u8) !void {
    if (self.invalid) return;
    if (!self.is_clipboard) {
        if (self.used == self.small.len) {
            self.invalid = true;
            return;
        }
        self.small[self.used] = value;
        self.used += 1;
        if (value == ';' and self.used >= 4 and std.mem.startsWith(u8, self.small[0..self.used], "52;")) {
            const selector = self.small[3 .. self.used - 1];
            // Default/clipboard selection only. Never expose desktop clipboard reads.
            if (selector.len != 0 and !std.mem.eql(u8, selector, "c")) self.invalid = true;
            self.is_clipboard = true;
        }
        return;
    }
    if (self.padded) {
        self.invalid = true;
        return;
    }
    self.quartet[self.quartet_len] = value;
    self.quartet_len += 1;
    if (self.quartet_len != 4) return;
    self.quartet_len = 0;
    const decoder = std.base64.standard.Decoder;
    const count = decoder.calcSizeForSlice(&self.quartet) catch {
        self.invalid = true;
        return;
    };
    var bytes: [3]u8 = undefined;
    decoder.decode(bytes[0..count], &self.quartet) catch {
        self.invalid = true;
        return;
    };
    if (self.decoded.items.len + count > max_clipboard_bytes) {
        self.invalid = true;
        self.decoded.clearRetainingCapacity();
        return;
    }
    try self.decoded.appendSlice(allocator, bytes[0..count]);
    self.padded = self.quartet[3] == '=';
}
pub fn end(self: *Strings, allocator: std.mem.Allocator, success: bool) !void {
    if (success and self.is_clipboard and !self.invalid and self.quartet_len == 0) {
        const bytes = try self.decoded.toOwnedSlice(allocator);
        if (self.clipboard) |old| allocator.free(old);
        self.clipboard = bytes;
    } else self.decoded.clearRetainingCapacity();
}
pub fn takeClipboard(self: *Strings) ?[]u8 {
    const bytes = self.clipboard;
    self.clipboard = null;
    return bytes;
}
