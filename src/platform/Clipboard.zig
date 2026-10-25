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
const Source = struct {
    clipboard: *Clipboard,
    object: *c.wl_data_source,
    bytes: []u8,
};
const PrimarySource = struct { clipboard: *Clipboard, object: *c.zwp_primary_selection_source_v1, bytes: []u8 };
const Transfer = struct { fd: c_int, bytes: []u8, offset: usize = 0 };
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
source: ?*Source = null,
primary_source: ?*PrimarySource = null,
primary_outgoing: ?[]u8 = null,
outgoing: ?[]u8 = null,
serial: ?u32 = null,
focused: bool = false,
transfers: [4]?Transfer = @splat(null),

/// Takes ownership, keeping only the newest complete application clipboard write.
pub fn set(self: *Clipboard, bytes: []u8) void {
    if (self.outgoing) |old| self.allocator.free(old);
    self.outgoing = bytes;
}
pub fn setPrimary(self: *Clipboard, bytes: []u8) void {
    if (self.primary_outgoing) |old| self.allocator.free(old);
    self.primary_outgoing = bytes;
}
fn destroyPrimary(self: *Clipboard, source: *PrimarySource) void {
    c.zwp_primary_selection_source_v1_destroy(source.object);
    self.allocator.free(source.bytes);
    self.allocator.destroy(source);
}
/// A fresh input serial is required after focus is acquired. Never invent one.
pub fn publish(self: *Clipboard) !void {
    if (self.focused and self.serial != null and self.primary_outgoing != null and self.primary_manager != null and self.primary_device != null) {
        const object = c.zwp_primary_selection_device_manager_v1_create_source(self.primary_manager) orelse return error.WaylandObjectFailed;
        errdefer c.zwp_primary_selection_source_v1_destroy(object);
        const source = try self.allocator.create(PrimarySource);
        errdefer self.allocator.destroy(source);
        source.* = .{ .clipboard = self, .object = object, .bytes = self.primary_outgoing.? };
        if (c.zwp_primary_selection_source_v1_add_listener(object, &primary_source_listener, source) != 0) return error.WaylandListenerFailed;
        c.zwp_primary_selection_source_v1_offer(object, "text/plain;charset=utf-8");
        c.zwp_primary_selection_source_v1_offer(object, "text/plain");
        c.zwp_primary_selection_device_v1_set_selection(self.primary_device, object, self.serial.?);
        if (self.primary_source) |old| self.destroyPrimary(old);
        self.primary_source = source;
        self.primary_outgoing = null;
    }
    if (!self.focused or self.serial == null or self.outgoing == null or self.manager == null or self.device == null) return;
    const object = c.wl_data_device_manager_create_data_source(self.manager) orelse return error.WaylandObjectFailed;
    errdefer c.wl_data_source_destroy(object);
    const source = try self.allocator.create(Source);
    errdefer self.allocator.destroy(source);
    source.* = .{ .clipboard = self, .object = object, .bytes = self.outgoing.? };
    if (c.wl_data_source_add_listener(object, &data_source_listener, source) != 0) return error.WaylandListenerFailed;
    c.wl_data_source_offer(object, "text/plain;charset=utf-8");
    c.wl_data_source_offer(object, "UTF8_STRING");
    c.wl_data_source_offer(object, "text/plain");
    c.wl_data_device_set_selection(self.device, object, self.serial.?);
    if (self.source) |old| self.destroySource(old);
    self.source = source;
    self.outgoing = null;
}
fn destroySource(self: *Clipboard, source: *Source) void {
    c.wl_data_source_destroy(source.object);
    self.allocator.free(source.bytes);
    self.allocator.destroy(source);
}
fn finishTransfer(self: *Clipboard, slot: *?Transfer) void {
    if (slot.*) |transfer| {
        _ = c.close(transfer.fd);
        self.allocator.free(transfer.bytes);
        slot.* = null;
    }
}
/// Bounded writes; the event loop polls these descriptors for POLLOUT.
pub fn pump(self: *Clipboard) void {
    var budget: usize = 64 * 1024;
    for (&self.transfers) |*slot| {
        if (slot.*) |*transfer| {
            while (transfer.offset < transfer.bytes.len and budget > 0) {
                // Wayland recipients can close pipes at any time. Linux returns
                // EPIPE; SIGPIPE is ignored by the parent (reset in the PTY child).
                const n = c.write(transfer.fd, transfer.bytes[transfer.offset..].ptr, @min(budget, transfer.bytes.len - transfer.offset));
                if (n < 0) {
                    if (common.errno() == c.EINTR) continue;
                    if (common.errno() != c.EAGAIN) self.finishTransfer(slot);
                    break;
                }
                if (n == 0) break;
                const count: usize = @intCast(n);
                transfer.offset += count;
                budget -= count;
            }
        }
        if (slot.*) |transfer| if (transfer.offset == transfer.bytes.len) self.finishTransfer(slot);
    }
}

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
    for (&self.transfers) |*slot| self.finishTransfer(slot);
    if (self.source) |source| self.destroySource(source);
    if (self.primary_source) |source| self.destroyPrimary(source);
    if (self.primary_outgoing) |bytes| self.allocator.free(bytes);
    if (self.outgoing) |bytes| self.allocator.free(bytes);
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

fn sourceTarget(_: ?*anyopaque, _: ?*c.wl_data_source, _: [*c]const u8) callconv(.c) void {}
fn sourceSend(data: ?*anyopaque, _: ?*c.wl_data_source, mime: [*c]const u8, fd: i32) callconv(.c) void {
    const source: *Source = @ptrCast(@alignCast(data.?));
    sendSource(source.clipboard, source.bytes, mime, fd);
}
fn sendSource(self: *Clipboard, text: []const u8, mime: [*c]const u8, fd: i32) void {
    const name = std.mem.span(mime);
    if (std.mem.eql(u8, name, "text/plain;charset=utf-8") or std.mem.eql(u8, name, "UTF8_STRING") or std.mem.eql(u8, name, "text/plain")) {
        for (&self.transfers) |*slot| if (slot.* == null) {
            const flags = c.fcntl(fd, c.F_GETFL);
            if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) break;
            const bytes = self.allocator.dupe(u8, text) catch break;
            slot.* = .{ .fd = fd, .bytes = bytes };
            return;
        };
    }
    _ = c.close(fd);
}
fn sourceCancelled(data: ?*anyopaque, _: ?*c.wl_data_source) callconv(.c) void {
    const source: *Source = @ptrCast(@alignCast(data.?));
    const self = source.clipboard;
    if (self.source == source) self.source = null;
    self.destroySource(source);
}
fn sourceDrop(_: ?*anyopaque, _: ?*c.wl_data_source) callconv(.c) void {}
fn sourceAction(_: ?*anyopaque, _: ?*c.wl_data_source, _: u32) callconv(.c) void {}
const data_source_listener: c.wl_data_source_listener = .{ .target = sourceTarget, .send = sourceSend, .cancelled = sourceCancelled, .dnd_drop_performed = sourceDrop, .dnd_finished = sourceDrop, .action = sourceAction };
fn primarySend(data: ?*anyopaque, _: ?*c.zwp_primary_selection_source_v1, mime: [*c]const u8, fd: i32) callconv(.c) void {
    const source: *PrimarySource = @ptrCast(@alignCast(data.?));
    sendSource(source.clipboard, source.bytes, mime, fd);
}
fn primaryCancelled(data: ?*anyopaque, _: ?*c.zwp_primary_selection_source_v1) callconv(.c) void {
    const source: *PrimarySource = @ptrCast(@alignCast(data.?));
    const self = source.clipboard;
    if (self.primary_source == source) self.primary_source = null;
    self.destroyPrimary(source);
}
const primary_source_listener: c.zwp_primary_selection_source_v1_listener = .{ .send = primarySend, .cancelled = primaryCancelled };

test "clipboard source sends are bounded nonblocking and survive source replacement" {
    const t = std.testing;
    var clipboard: Clipboard = .{ .allocator = t.allocator };
    defer clipboard.deinit();
    var source: Source = .{ .clipboard = &clipboard, .object = undefined, .bytes = try t.allocator.alloc(u8, 256 * 1024) };
    @memset(source.bytes, 'x');
    var fds: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(fds[0]);
    sourceSend(&source, null, "text/plain;charset=utf-8", fds[1]);
    t.allocator.free(source.bytes); // replacing/cancelling the source cannot invalidate a send
    clipboard.pump();
    try t.expect(clipboard.transfers[0] != null);
    try t.expect(clipboard.transfers[0].?.offset <= 64 * 1024);
    var count: usize = 0;
    var buffer: [16384]u8 = undefined;
    for (0..1024) |_| {
        const n = c.read(fds[0], &buffer, buffer.len);
        if (n > 0) {
            count += @intCast(n);
            for (buffer[0..@intCast(n)]) |byte| try t.expectEqual(@as(u8, 'x'), byte);
        } else if (n == 0) break;
        clipboard.pump();
    }
    try t.expectEqual(@as(usize, 256 * 1024), count);
    try t.expect(clipboard.transfers[0] == null);
}

test "clipboard writes wait for focus and a valid serial and discard closed recipients" {
    const t = std.testing;
    var clipboard: Clipboard = .{ .allocator = t.allocator };
    defer clipboard.deinit();
    clipboard.set(try t.allocator.dupe(u8, "old"));
    clipboard.set(try t.allocator.dupe(u8, "new"));
    try clipboard.publish();
    try t.expectEqualStrings("new", clipboard.outgoing.?);
    var fds: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.pipe2(&fds, c.O_CLOEXEC | c.O_NONBLOCK));
    _ = c.close(fds[0]);
    clipboard.transfers[0] = .{ .fd = fds[1], .bytes = try t.allocator.dupe(u8, "cancelled") };
    const previous = c.signal(c.SIGPIPE, c.SIG_IGN);
    defer _ = c.signal(c.SIGPIPE, previous);
    clipboard.pump();
    try t.expect(clipboard.transfers[0] == null);
}
