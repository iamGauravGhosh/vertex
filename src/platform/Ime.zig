//! Wayland text-input-v3 batched preedit and committed text.
const std = @import("std");
const c = @import("c");
const Ime = @This();
allocator: std.mem.Allocator,
manager: ?*c.zwp_text_input_manager_v3 = null,
object: ?*c.zwp_text_input_v3 = null,
surface: ?*c.wl_surface = null,
enabled: bool = false,
serial: u32 = 0,
preedit: []u8 = &.{},
pending_preedit: []u8 = &.{},
pending_commit: []u8 = &.{},
committed: std.ArrayList(u8) = .empty,
cursor_begin: i32 = 0,
cursor_end: i32 = 0,
pending_begin: i32 = 0,
pending_end: i32 = 0,
changed: bool = false,
failure: ?anyerror = null,
rectangle: [4]i32 = @splat(-1),

pub fn setup(self: *Ime, seat: ?*c.wl_seat) void {
    if (self.manager == null or seat == null or self.object != null) return;
    self.object = c.zwp_text_input_manager_v3_get_text_input(self.manager, seat);
    if (self.object) |object| _ = c.zwp_text_input_v3_add_listener(object, &listener, self);
}
fn commit(self: *Ime) void {
    c.zwp_text_input_v3_commit(self.object);
    self.serial +%= 1;
}
pub fn cursor(self: *Ime, x: i32, y: i32, width: i32, height: i32) void {
    if (!self.enabled) return;
    const rect = [4]i32{ x, y, width, height };
    if (std.mem.eql(i32, &rect, &self.rectangle)) return;
    self.rectangle = rect;
    c.zwp_text_input_v3_set_cursor_rectangle(self.object, x, y, width, height);
    self.commit();
}
pub fn clear(self: *Ime) void {
    self.allocator.free(self.preedit);
    self.allocator.free(self.pending_preedit);
    self.allocator.free(self.pending_commit);
    self.preedit = &.{};
    self.pending_preedit = &.{};
    self.pending_commit = &.{};
    self.changed = true;
}
pub fn deinit(self: *Ime) void {
    self.clear();
    self.committed.deinit(self.allocator);
    if (self.object) |object| c.zwp_text_input_v3_destroy(object);
    if (self.manager) |manager| c.zwp_text_input_manager_v3_destroy(manager);
}
fn from(data: ?*anyopaque) *Ime {
    return @ptrCast(@alignCast(data.?));
}
fn enter(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, surface: ?*c.wl_surface) callconv(.c) void {
    const self = from(data);
    if (surface != self.surface) return;
    self.clear();
    self.enabled = true;
    self.rectangle = @splat(-1);
    c.zwp_text_input_v3_enable(self.object);
    c.zwp_text_input_v3_set_content_type(self.object, 0, c.ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_TERMINAL);
    self.commit();
}
fn leave(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, _: ?*c.wl_surface) callconv(.c) void {
    const self = from(data);
    self.clear();
    self.enabled = false;
}
fn replace(self: *Ime, target: *[]u8, text: [*c]const u8) void {
    const bytes = if (text != null) std.mem.span(text) else "";
    const replacement = self.allocator.dupe(u8, bytes) catch {
        self.failure = error.OutOfMemory;
        return;
    };
    self.allocator.free(target.*);
    target.* = replacement;
}
fn preeditEvent(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, text: [*c]const u8, begin: i32, end: i32) callconv(.c) void {
    const self = from(data);
    self.replace(&self.pending_preedit, text);
    self.pending_begin = begin;
    self.pending_end = end;
}
fn textCommit(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, text: [*c]const u8) callconv(.c) void {
    const self = from(data);
    self.replace(&self.pending_commit, text);
}
// No surrounding text was advertised: the PTY application's buffer is opaque.
fn delete(_: ?*anyopaque, _: ?*c.zwp_text_input_v3, _: u32, _: u32) callconv(.c) void {}
fn done(data: ?*anyopaque, _: ?*c.zwp_text_input_v3, serial: u32) callconv(.c) void {
    const self = from(data);
    if (!self.enabled) {
        self.clear();
        return;
    }
    const inserted = self.pending_commit.len != 0;
    self.committed.appendSlice(self.allocator, self.pending_commit) catch {
        self.failure = error.OutOfMemory;
        return;
    };
    self.allocator.free(self.pending_commit);
    self.pending_commit = &.{};
    self.allocator.free(self.preedit);
    self.preedit = self.pending_preedit;
    self.pending_preedit = &.{};
    self.cursor_begin = self.pending_begin;
    self.cursor_end = self.pending_end;
    self.pending_begin = 0;
    self.pending_end = 0;
    self.changed = true;
    // A stale batch still inserts text, but must not overwrite newer client state.
    if (serial == self.serial and inserted) {
        c.zwp_text_input_v3_set_text_change_cause(self.object, c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD);
        self.commit();
    }
}
const listener: c.zwp_text_input_v3_listener = blk: {
    var value = std.mem.zeroes(c.zwp_text_input_v3_listener);
    value.enter = enter;
    value.leave = leave;
    value.preedit_string = preeditEvent;
    value.commit_string = textCommit;
    value.delete_surrounding_text = delete;
    value.done = done;
    break :blk value;
};

test "text input batches preedit commits exactly once and clears on focus loss" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &fds));
    defer _ = c.close(fds[1]);
    const display = c.wl_display_connect_to_fd(fds[0]) orelse return error.WaylandConnectFailed;
    defer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display);
    defer c.wl_registry_destroy(registry);
    const seat: *c.wl_seat = @ptrCast(c.wl_registry_bind(registry, 1, &c.wl_seat_interface, 1));
    defer c.wl_seat_destroy(seat);
    const compositor: *c.wl_compositor = @ptrCast(c.wl_registry_bind(registry, 2, &c.wl_compositor_interface, 4));
    defer c.wl_compositor_destroy(compositor);
    const surface = c.wl_compositor_create_surface(compositor);
    defer c.wl_surface_destroy(surface);
    var ime: Ime = .{ .allocator = std.testing.allocator, .surface = surface };
    defer ime.deinit();
    ime.manager = @ptrCast(c.wl_registry_bind(registry, 3, &c.zwp_text_input_manager_v3_interface, 1));
    ime.setup(seat);
    enter(&ime, ime.object, surface);
    const serial = ime.serial;
    preeditEvent(&ime, ime.object, "日本", 3, 6);
    textCommit(&ime, ime.object, "é");
    try std.testing.expectEqual(@as(usize, 0), ime.committed.items.len);
    done(&ime, ime.object, serial);
    try std.testing.expectEqualStrings("é", ime.committed.items);
    try std.testing.expectEqualStrings("日本", ime.preedit);
    try std.testing.expectEqual(@as(i32, 3), ime.cursor_begin);
    // Stale serials still deliver text but do not commit newer client state.
    textCommit(&ime, ime.object, "界");
    const current = ime.serial;
    done(&ime, ime.object, serial);
    try std.testing.expectEqual(current, ime.serial);
    try std.testing.expectEqualStrings("é界", ime.committed.items);
    done(&ime, ime.object, serial);
    try std.testing.expectEqualStrings("é界", ime.committed.items);
    leave(&ime, ime.object, surface);
    try std.testing.expect(!ime.enabled and ime.preedit.len == 0);
}
