//! Terminal protocol state and active main/alternate screen, without OS I/O.
const std = @import("std");
const Parser = @import("Parser.zig");
const Screen = @import("Screen.zig");
const Input = @import("Input.zig");
const Session = @This();
const Keyboard = struct {
    flags: u5 = 0,
    stack: [32]u5 = @splat(0),
    depth: usize = 0,
};
allocator: std.mem.Allocator,
screen: Screen,
other: Screen,
alternate: bool = false,
modes: Input.Modes = .{},
keyboards: [2]Keyboard = .{ .{}, .{} },
replies: std.ArrayList(u8) = .empty,
failure: ?anyerror = null,

pub fn init(allocator: std.mem.Allocator, rows: usize, columns: usize) !Session {
    var screen = try Screen.init(allocator, rows, columns);
    errdefer screen.deinit();
    return .{ .allocator = allocator, .screen = screen, .other = try Screen.init(allocator, rows, columns) };
}
pub fn deinit(self: *Session) void {
    self.screen.deinit();
    self.other.deinit();
    self.replies.deinit(self.allocator);
    self.* = undefined;
}
pub fn activeScreen(self: *Session) *Screen {
    return &self.screen;
}
pub fn getModes(self: *const Session) Input.Modes {
    var modes = self.modes;
    modes.kitty = self.keyboards[@intFromBool(self.alternate)].flags;
    return modes;
}
pub fn takeError(self: *Session) ?anyerror {
    const failure = self.failure;
    self.failure = null;
    return failure;
}
pub fn drainReplies(self: *Session, writer: anytype) !void {
    try writer.writeAll(self.replies.items);
    self.replies.clearRetainingCapacity();
}
pub fn resize(self: *Session, rows: usize, columns: usize) !void {
    if (rows == self.screen.rows and columns == self.screen.columns) return;
    // Prepare both replacements before committing either grid.
    var first = try self.screen.resized(rows, columns);
    errdefer first.deinit();
    const second = try self.other.resized(rows, columns);
    self.screen.deinit();
    self.other.deinit();
    self.screen = first;
    self.other = second;
}
pub fn handle(self: *Session, event: Parser.Event) void {
    if (self.failure != null) return;
    self.apply(event) catch |err| {
        self.failure = err;
    };
}
pub fn apply(self: *Session, event: Parser.Event) !void {
    switch (event) {
        .esc => |cmd| if (cmd.intermediates.len == 0) {
            switch (cmd.final) {
                '=' => self.modes.application_keypad = true,
                '>' => self.modes.application_keypad = false,
                'c' => {
                    if (self.alternate) self.switchScreen(false);
                    self.other.reset();
                    self.modes = .{};
                    self.keyboards = .{ .{}, .{} };
                },
                else => {},
            }
        },
        .csi => |cmd| if (cmd.intermediates.len == 0) {
            const prefix = cmd.private_prefix orelse 0;
            const p = cmd.parameters;
            if (prefix != 0) for (p) |item| {
                if (item.separator == .colon) return;
            };
            const a = param(p, 0, 0);
            const b = param(p, 1, 0);
            if (cmd.final == 'u' and prefix != 0) {
                const keyboard = &self.keyboards[@intFromBool(self.alternate)];
                const flags: u5 = @truncate(a);
                switch (prefix) {
                    '?' => {
                        var buf: [32]u8 = undefined;
                        try self.reply(try std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{keyboard.flags}));
                    },
                    '=' => switch (param(p, 1, 1)) {
                        1 => keyboard.flags = flags,
                        2 => keyboard.flags |= flags,
                        3 => keyboard.flags &= ~flags,
                        else => {},
                    },
                    '>' => {
                        if (keyboard.depth == keyboard.stack.len) {
                            std.mem.copyForwards(u5, keyboard.stack[0..31], keyboard.stack[1..32]);
                            keyboard.depth -= 1;
                        }
                        keyboard.stack[keyboard.depth] = keyboard.flags;
                        keyboard.depth += 1;
                        keyboard.flags = flags;
                    },
                    '<' => {
                        const count = @max(1, a);
                        if (count > keyboard.depth) {
                            keyboard.depth = 0;
                            keyboard.flags = 0;
                        } else {
                            keyboard.depth -= count;
                            keyboard.flags = keyboard.stack[keyboard.depth];
                        }
                    },
                    else => {},
                }
                return;
            }
            if (cmd.final == 'm' and prefix == '>') {
                if (p.len == 0 or (a == 4 and b <= 2)) self.modes.modify_other_keys = if (p.len == 0) 0 else @intCast(b);
                return;
            }
            if (cmd.final == 'n' and prefix == '>' and a == 4) {
                self.modes.modify_other_keys = 0;
                return;
            }
            if (cmd.final == 'm' and prefix == '?' and a == 4) {
                var buf: [32]u8 = undefined;
                try self.reply(try std.fmt.bufPrint(&buf, "\x1b[>4;{d}m", .{self.modes.modify_other_keys}));
                return;
            }
            if (prefix == '?' and (cmd.final == 'h' or cmd.final == 'l')) {
                for (p) |item| if (item.separator == .colon) return;
                const enabled = cmd.final == 'h';
                for (p) |item| switch (item.value orelse 0) {
                    1 => self.modes.application_cursor = enabled,
                    9, 1000, 1002, 1003 => self.modes.mouse_tracking = if (enabled) item.value.? else 0,
                    1004 => self.modes.focus = enabled,
                    1006 => self.modes.mouse_sgr = enabled,
                    1016 => self.modes.mouse_pixels = enabled,
                    2004 => self.modes.bracketed_paste = enabled,
                    47, 1047, 1049 => {
                        if (enabled and !self.alternate) {
                            if (item.value.? == 1049) try self.screen.apply(.{ .esc = .{ .intermediates = "", .final = '7' } });
                            self.switchScreen(true);
                            if (item.value.? != 47) self.screen.reset();
                        } else if (!enabled and self.alternate) {
                            if (item.value.? == 1047) self.screen.reset();
                            self.switchScreen(false);
                            if (item.value.? == 1049) try self.screen.apply(.{ .esc = .{ .intermediates = "", .final = '8' } });
                        }
                    },
                    1048 => try self.screen.apply(.{ .esc = .{ .intermediates = "", .final = if (enabled) '7' else '8' } }),
                    else => try self.screen.apply(.{ .csi = .{ .private_prefix = '?', .parameters = &.{item}, .intermediates = "", .final = cmd.final } }),
                };
                return;
            }
            if (cmd.final == 'c' and prefix == 0 and a == 0) {
                try self.reply("\x1b[?1;2c");
                return;
            }
            if (cmd.final == 'n' and prefix == 0) {
                if (a == 5) try self.reply("\x1b[0n");
                if (a == 6) {
                    const cursor = self.screen.cursor;
                    var buf: [64]u8 = undefined;
                    const row = cursor.row - (if (self.screen.origin_mode) self.screen.scroll_top else @as(usize, 0));
                    try self.reply(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row + 1, cursor.column + 1 }));
                }
                return;
            }
        },
        else => {},
    }
    try self.screen.apply(event);
}
fn switchScreen(self: *Session, alternate: bool) void {
    if (self.alternate == alternate) return;
    std.mem.swap(Screen, &self.screen, &self.other);
    self.alternate = alternate;
    self.screen.invalidateAll();
}
fn reply(self: *Session, bytes: []const u8) !void {
    if (self.replies.items.len + bytes.len > 65536) return error.ReplyQueueFull;
    try self.replies.appendSlice(self.allocator, bytes);
}
fn param(p: []const Parser.Parameter, i: usize, default: u16) u16 {
    return if (i < p.len) p[i].value orelse default else default;
}
