//! Asynchronous Wayland clipboard and primary-selection receiving.
const std = @import("std");
const c = @import("c");
const common = @import("common.zig");
const Input = @import("../terminal/Input.zig");
const Clipboard = @This();
const Offer = struct {
    clipboard: *Clipboard,
    object: ?*c.wl_data_offer = null,
    primary: ?*c.zwp_primary_selection_offer_v1 = null,
    mime: ?[:0]const u8 = null,
};
allocator: std.mem.Allocator,
manager: ?*c.wl_data_device_manager = null,
primary_manager: ?*c.zwp_primary_selection_device_manager_v1 = null,
device: ?*c.wl_data_device = null,
primary_device: ?*c.zwp_primary_selection_device_v1 = null,
offers: std.ArrayList(*Offer) = .empty,
selection: ?*Offer = null,
primary_selection: ?*Offer = null,
fd: c_int = -1,
bytes: std.ArrayList(u8) = .empty,
failure: ?anyerror = null,

pub fn setup(self: *Clipboard, seat: ?*c.wl_seat) void {
    if (seat == null) return;
    if (self.manager != null and self.device == null) {
        self.device = c.wl_data_device_manager_get_data_device(self.manager, seat);
        if (self.device) |device| _ = c.wl_data_device_add_listener(device, &device_listener, self);
    }
    if (self.primary_manager != null and self.primary_device == null) {
        self.primary_device = c.zwp_primary_selection_device_manager_v1_get_device(self.primary_manager, seat);
        if (self.primary_device) |device| _ = c.zwp_primary_selection_device_v1_add_listener(device, &primary_listener, self);
    }
}
pub fn cancel(self: *Clipboard) void {
    if (self.fd >= 0) _ = c.close(self.fd);
    self.fd = -1;
    self.bytes.clearRetainingCapacity();
}
pub fn request(self: *Clipboard, primary: bool) !void {
    const offer = (if (primary) self.primary_selection else self.selection) orelse return;
    const mime = offer.mime orelse return;
    self.cancel();
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) < 0) return error.ClipboardPipeFailed;
    defer _ = c.close(fds[1]);
    errdefer _ = c.close(fds[0]);
    if (c.fcntl(fds[0], c.F_SETFL, c.O_NONBLOCK) < 0) return error.ClipboardPipeFailed;
    if (offer.object) |object| c.wl_data_offer_receive(object, mime, fds[1]) else c.zwp_primary_selection_offer_v1_receive(offer.primary, mime, fds[1]);
    self.fd = fds[0];
}
/// Returns an owned complete payload only at EOF. Errors discard all bytes.
pub fn read(self: *Clipboard) !?[]u8 {
    if (self.fd < 0) return null;
    errdefer self.cancel();
    var buffer: [16384]u8 = undefined;
    var budget: usize = 256 * 1024;
    while (budget > 0) {
        const count = c.read(self.fd, &buffer, @min(buffer.len, budget));
        if (count < 0) {
            if (common.errno() == c.EINTR) continue;
            if (common.errno() == c.EAGAIN) return null;
            return error.ClipboardReadFailed;
        }
        if (count == 0) {
            const result = try self.bytes.toOwnedSlice(self.allocator);
            self.cancel();
            return result;
        }
        const n: usize = @intCast(count);
        if (self.bytes.items.len + n > Input.max_paste_bytes) return error.PasteTooLarge;
        try self.bytes.appendSlice(self.allocator, buffer[0..n]);
        budget -= n;
    }
    return null;
}
fn destroyOffer(self: *Clipboard, offer: *Offer) void {
    if (offer.object) |object| c.wl_data_offer_destroy(object);
    if (offer.primary) |object| c.zwp_primary_selection_offer_v1_destroy(object);
    self.allocator.destroy(offer);
}
pub fn deinit(self: *Clipboard) void {
    self.cancel();
    for (self.offers.items) |offer| self.destroyOffer(offer);
    self.offers.deinit(self.allocator);
    self.bytes.deinit(self.allocator);
    if (self.device) |device| {
        if (c.wl_data_device_get_version(device) >= 2) c.wl_data_device_release(device) else c.wl_data_device_destroy(device);
    }
    if (self.primary_device) |device| c.zwp_primary_selection_device_v1_destroy(device);
    if (self.manager) |manager| c.wl_data_device_manager_destroy(manager);
    if (self.primary_manager) |manager| c.zwp_primary_selection_device_manager_v1_destroy(manager);
}
fn from(data: ?*anyopaque) *Clipboard {
    return @ptrCast(@alignCast(data.?));
}
fn chooseMime(data: ?*anyopaque, _: anytype, name: [*c]const u8) void {
    const offer: *Offer = @ptrCast(@alignCast(data.?));
    const text = std.mem.span(name);
    if (std.mem.eql(u8, text, "text/plain;charset=utf-8")) offer.mime = "text/plain;charset=utf-8" else if (offer.mime == null and std.mem.eql(u8, text, "UTF8_STRING")) offer.mime = "UTF8_STRING" else if (offer.mime == null and std.mem.eql(u8, text, "text/plain")) offer.mime = "text/plain";
}
fn offerMime(data: ?*anyopaque, object: ?*c.wl_data_offer, name: [*c]const u8) callconv(.c) void {
    chooseMime(data, object, name);
}
fn primaryMime(data: ?*anyopaque, object: ?*c.zwp_primary_selection_offer_v1, name: [*c]const u8) callconv(.c) void {
    chooseMime(data, object, name);
}
fn makeOffer(self: *Clipboard) ?*Offer {
    const offer = self.allocator.create(Offer) catch {
        self.failure = error.OutOfMemory;
        return null;
    };
    offer.* = .{ .clipboard = self };
    self.offers.append(self.allocator, offer) catch {
        self.allocator.destroy(offer);
        self.failure = error.OutOfMemory;
        return null;
    };
    return offer;
}
fn dataOffer(data: ?*anyopaque, _: ?*c.wl_data_device, object: ?*c.wl_data_offer) callconv(.c) void {
    const self = from(data);
    const offer = self.makeOffer() orelse {
        c.wl_data_offer_destroy(object);
        return;
    };
    offer.object = object;
    _ = c.wl_data_offer_add_listener(object, &offer_listener, offer);
}
fn primaryOffer(data: ?*anyopaque, _: ?*c.zwp_primary_selection_device_v1, object: ?*c.zwp_primary_selection_offer_v1) callconv(.c) void {
    const self = from(data);
    const offer = self.makeOffer() orelse {
        c.zwp_primary_selection_offer_v1_destroy(object);
        return;
    };
    offer.primary = object;
    _ = c.zwp_primary_selection_offer_v1_add_listener(object, &primary_offer_listener, offer);
}
fn discard(self: *Clipboard, offer: *Offer) void {
    for (self.offers.items, 0..) |item, i| {
        if (item == offer) {
            _ = self.offers.swapRemove(i);
            self.destroyOffer(offer);
            return;
        }
    }
}
fn dataSelection(data: ?*anyopaque, _: ?*c.wl_data_device, object: ?*c.wl_data_offer) callconv(.c) void {
    const self = from(data);
    const old = self.selection;
    self.selection = null;
    for (self.offers.items) |offer| if (offer.object != null and offer.object == object) {
        self.selection = offer;
        break;
    };
    if (old) |offer| if (offer != self.selection) self.discard(offer);
}
fn primarySelection(data: ?*anyopaque, _: ?*c.zwp_primary_selection_device_v1, object: ?*c.zwp_primary_selection_offer_v1) callconv(.c) void {
    const self = from(data);
    const old = self.primary_selection;
    self.primary_selection = null;
    for (self.offers.items) |offer| if (offer.primary != null and offer.primary == object) {
        self.primary_selection = offer;
        break;
    };
    if (old) |offer| if (offer != self.primary_selection) self.discard(offer);
}
fn enter(data: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: ?*c.wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t, object: ?*c.wl_data_offer) callconv(.c) void {
    const self = from(data);
    for (self.offers.items) |offer| if (offer.object == object and offer != self.selection) {
        self.discard(offer);
        break;
    };
}
fn leave(_: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {}
fn motion(_: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
fn drop(_: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {}
const device_listener: c.wl_data_device_listener = .{ .data_offer = dataOffer, .enter = enter, .leave = leave, .motion = motion, .drop = drop, .selection = dataSelection };
const offer_listener: c.wl_data_offer_listener = blk: {
    var value = std.mem.zeroes(c.wl_data_offer_listener);
    value.offer = offerMime;
    value.source_actions = sourceActions;
    value.action = sourceActions;
    break :blk value;
};
const primary_listener: c.zwp_primary_selection_device_v1_listener = .{ .data_offer = primaryOffer, .selection = primarySelection };
const primary_offer_listener: c.zwp_primary_selection_offer_v1_listener = .{ .offer = primaryMime };

test "clipboard reads asynchronously and returns only complete transfers" {
    var clipboard: Clipboard = .{ .allocator = std.testing.allocator };
    defer clipboard.deinit();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK));
    clipboard.fd = fds[0];
    try std.testing.expect((try clipboard.read()) == null);
    try std.testing.expectEqual(@as(isize, 3), c.write(fds[1], "abc", 3));
    try std.testing.expect((try clipboard.read()) == null);
    _ = c.close(fds[1]);
    const bytes = (try clipboard.read()).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("abc", bytes);
    try std.testing.expectEqual(@as(c_int, -1), clipboard.fd);
    // Partial data is discarded on read failure.
    clipboard.fd = c.dup(2);
    _ = c.close(clipboard.fd);
    try std.testing.expectError(error.ClipboardReadFailed, clipboard.read());
    try std.testing.expectEqual(@as(usize, 0), clipboard.bytes.items.len);
}

test "oversized clipboard transfer is discarded before it reaches the PTY" {
    var clipboard: Clipboard = .{ .allocator = std.testing.allocator };
    defer clipboard.deinit();
    try clipboard.bytes.resize(std.testing.allocator, Input.max_paste_bytes);
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK));
    clipboard.fd = fds[0];
    defer _ = c.close(fds[1]);
    try std.testing.expectEqual(@as(isize, 1), c.write(fds[1], "x", 1));
    try std.testing.expectError(error.PasteTooLarge, clipboard.read());
    try std.testing.expectEqual(@as(usize, 0), clipboard.bytes.items.len);
    try std.testing.expectEqual(@as(c_int, -1), clipboard.fd);
}

fn sourceActions(_: ?*anyopaque, _: ?*c.wl_data_offer, _: u32) callconv(.c) void {}
