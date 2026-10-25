//! Terminal protocol state and active main/alternate screen, without OS I/O.
const std = @import("std");
const Parser = @import("Parser.zig");
const Screen = @import("Screen.zig");
const Input = @import("Input.zig");
const Strings = @import("ControlStrings.zig");
const Colors = @import("Colors.zig");
const GraphicsProtocol = @import("GraphicsProtocol.zig");
pub const Options = GraphicsProtocol.Options;
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
strings: Strings = .{},
graphics: GraphicsProtocol = .{},
/// Set by the host before feeding bytes; monotonic milliseconds, no OS clock here.
now_ms: i64 = 0,
sync_deadline_ms: ?i64 = null,
sync_expired: bool = false,
geometry: struct { width: usize = 0, height: usize = 0, cell_width: usize = 0, cell_height: usize = 0 } = .{},
dcs: [4096]u8 = undefined,
dcs_len: usize = 0,
dcs_kind: enum { ignored, capabilities, status, graphics } = .ignored,

pub fn init(allocator: std.mem.Allocator, rows: usize, columns: usize) !Session {
    return initWithOptions(allocator, rows, columns, .{});
}
pub fn initWithOptions(allocator: std.mem.Allocator, rows: usize, columns: usize, options: Options) !Session {
    var screen = try Screen.init(allocator, rows, columns);
    errdefer screen.deinit();
    var other = try Screen.init(allocator, rows, columns);
    errdefer other.deinit();
    if (options.images) try other.graphics.shareBudget(&screen.graphics);
    if (screen.graphics.budget) |budget| budget.refs += 1;
    return .{ .allocator = allocator, .screen = screen, .other = other, .graphics = .{ .options = options, .budget = screen.graphics.budget } };
}
pub fn deinit(self: *Session) void {
    self.graphics.deinit(self.allocator);
    self.screen.deinit();
    self.other.deinit();
    self.replies.deinit(self.allocator);
    self.strings.deinit(self.allocator);
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
    return failure orelse self.screen.takeError();
}
/// Host must wake at the deadline even when PTY output stops.
pub fn presentationHeld(self: *Session, now_ms: i64) bool {
    self.now_ms = now_ms;
    if (self.sync_deadline_ms) |deadline| {
        if (now_ms < deadline) return true;
        self.sync_deadline_ms = null;
        self.sync_expired = true;
    }
    return false;
}
/// Transfer ownership of the last complete OSC 52 write to the host.
pub fn takeClipboard(self: *Session) ?[]u8 {
    return self.strings.takeClipboard();
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
        .apc_begin => self.graphics.begin(.kitty),
        .apc_data => |byte| try self.graphics.byte(self.allocator, byte),
        .apc_end => |ending| try self.graphics.end(self, ending == .st),
        .osc_begin => {
            self.strings.begin();
            self.graphics.begin(.osc);
        },
        .osc_data => |byte| {
            try self.strings.byte(self.allocator, byte);
            try self.graphics.byte(self.allocator, byte);
        },
        .osc_end => |ending| {
            const success = ending == .st or ending == .bel;
            if (success and !self.strings.invalid and !self.strings.is_clipboard) try self.osc(self.strings.small[0..self.strings.used]);
            try self.strings.end(self.allocator, success);
            try self.graphics.end(self, success);
        },
        .osc => |message| {
            self.strings.begin();
            self.graphics.begin(.osc);
            for (message.data) |byte| {
                try self.strings.byte(self.allocator, byte);
                try self.graphics.byte(self.allocator, byte);
            }
            if (!self.strings.invalid and !self.strings.is_clipboard) try self.osc(self.strings.small[0..self.strings.used]);
            try self.strings.end(self.allocator, true);
            try self.graphics.end(self, true);
        },
        .dcs_begin => |cmd| {
            self.dcs_len = 0;
            if (self.graphics.options.images and cmd.private_prefix == null and cmd.intermediates.len == 0 and cmd.final == 'q' and cmd.parameters.len <= 3) {
                self.dcs_kind = .graphics;
                self.graphics.begin(.sixel);
                self.graphics.sixel_params = .{ param(cmd.parameters, 0, 0), param(cmd.parameters, 1, 0), param(cmd.parameters, 2, 0) };
                return;
            }
            self.dcs_kind = if (cmd.private_prefix == null and cmd.parameters.len == 0 and cmd.final == 'q') kind: {
                if (std.mem.eql(u8, cmd.intermediates, "+")) break :kind .capabilities;
                if (std.mem.eql(u8, cmd.intermediates, "$")) break :kind .status;
                break :kind .ignored;
            } else .ignored;
        },
        .dcs_data => |byte| if (self.dcs_kind != .ignored) {
            if (self.dcs_kind == .graphics) try self.graphics.byte(self.allocator, byte) else if (self.dcs_len == self.dcs.len) self.dcs_kind = .ignored else {
                self.dcs[self.dcs_len] = byte;
                self.dcs_len += 1;
            }
        },
        .dcs_end => |ending| {
            if (self.dcs_kind == .graphics) try self.graphics.end(self, ending == .st);
            if (ending == .st) switch (self.dcs_kind) {
                .capabilities => try self.capabilities(self.dcs[0..self.dcs_len]),
                .status => try self.status(self.dcs[0..self.dcs_len]),
                .ignored, .graphics => {},
            };
            self.dcs_kind = .ignored;
        },
        .esc => |cmd| if (cmd.intermediates.len == 0) {
            switch (cmd.final) {
                '=' => self.modes.application_keypad = true,
                '>' => self.modes.application_keypad = false,
                'c' => {
                    if (self.alternate) self.switchScreen(false);
                    self.other.reset();
                    self.modes = .{};
                    self.keyboards = .{ .{}, .{} };
                    self.sync_deadline_ms = null;
                    self.sync_expired = false;
                    self.strings.begin();
                    self.graphics.reset();
                },
                else => {},
            }
        },
        .csi => |cmd| {
            const prefix = cmd.private_prefix orelse 0;
            const p = cmd.parameters;
            if (prefix != 0 or cmd.final != 'm') for (p) |item| {
                if (item.separator == .colon) return;
            };
            const a = param(p, 0, 0);
            const b = param(p, 1, 0);
            if (std.mem.eql(u8, cmd.intermediates, "$") and cmd.final == 'p' and prefix == '?') {
                for (p) |item| {
                    const mode = item.value orelse 0;
                    var buf: [64]u8 = undefined;
                    try self.reply(try std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, self.modeStatus(mode) }));
                }
                return;
            }
            if (cmd.intermediates.len != 0) return self.screen.apply(event);
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
                    80 => if (self.graphics.options.images) {
                        self.graphics.sixel_display = enabled;
                    },
                    1070 => if (self.graphics.options.images) {
                        self.graphics.sixel_private = enabled;
                    },
                    8452 => if (self.graphics.options.images) {
                        self.graphics.sixel_right = enabled;
                    },
                    1 => self.modes.application_cursor = enabled,
                    9, 1000, 1002, 1003 => self.modes.mouse_tracking = if (enabled) item.value.? else 0,
                    1004 => self.modes.focus = enabled,
                    1006 => self.modes.mouse_sgr = enabled,
                    1016 => self.modes.mouse_pixels = enabled,
                    2004 => self.modes.bracketed_paste = enabled,
                    2026 => {
                        if (!enabled) {
                            self.sync_deadline_ms = null;
                            self.sync_expired = false;
                        } else if (!self.sync_expired and self.sync_deadline_ms == null) self.sync_deadline_ms = self.now_ms +| 150;
                    },
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
                try self.reply(if (self.graphics.options.images) "\x1b[?1;2;4c" else "\x1b[?1;2c");
                return;
            }
            if (cmd.final == 'S' and prefix == '?' and self.graphics.options.images) {
                var buf: [96]u8 = undefined;
                if ((a == 1 or a == 2) and (b == 1 or b == 4)) {
                    try self.reply(if (a == 1) try std.fmt.bufPrint(&buf, "\x1b[?1;0;256S", .{}) else try std.fmt.bufPrint(&buf, "\x1b[?2;0;8192;8192S", .{}));
                } else try self.reply(try std.fmt.bufPrint(&buf, "\x1b[?{d};1S", .{a}));
                return;
            }
            if (cmd.final == 'c' and prefix == '>' and a == 0) {
                // VT100 identity: do not claim unrelated VT420 features.
                try self.reply("\x1b[>0;0;0c");
                return;
            }
            if (cmd.final == 't' and prefix == 0) {
                var buf: [96]u8 = undefined;
                switch (a) {
                    14 => if (self.geometry.width != 0 and self.geometry.height != 0) try self.reply(try std.fmt.bufPrint(&buf, "\x1b[4;{d};{d}t", .{ self.geometry.height, self.geometry.width })),
                    16 => if (self.geometry.cell_width != 0 and self.geometry.cell_height != 0) try self.reply(try std.fmt.bufPrint(&buf, "\x1b[6;{d};{d}t", .{ self.geometry.cell_height, self.geometry.cell_width })),
                    18 => try self.reply(try std.fmt.bufPrint(&buf, "\x1b[8;{d};{d}t", .{ self.screen.rows, self.screen.columns })),
                    else => {},
                }
                return;
            }
            if (cmd.final == 'n' and prefix == 0) {
                if (a == 5) try self.reply("\x1b[0n");
                if (a == 6) {
                    const cursor = self.screen.cursor;
                    var buf: [64]u8 = undefined;
                    const row = cursor.row - (if (self.screen.origin_mode) self.screen.scroll_top else @as(usize, 0));
                    const column = cursor.column - (if (self.screen.origin_mode and self.screen.left_right_mode) self.screen.scroll_left else @as(usize, 0));
                    try self.reply(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row + 1, column + 1 }));
                }
                return;
            }
        },
        else => {},
    }
    try self.screen.apply(event);
    if (self.screen.takeError()) |err| return err;
}
fn switchScreen(self: *Session, alternate: bool) void {
    if (self.alternate == alternate) return;
    std.mem.swap(Screen, &self.screen, &self.other);
    self.alternate = alternate;
    self.screen.invalidateAll();
}
pub fn reply(self: *Session, bytes: []const u8) !void {
    if (self.replies.items.len + bytes.len > 65536) return error.ReplyQueueFull;
    try self.replies.appendSlice(self.allocator, bytes);
}
fn param(p: []const Parser.Parameter, i: usize, default: u16) u16 {
    return if (i < p.len) p[i].value orelse default else default;
}

fn modeStatus(self: *const Session, mode: u16) u8 {
    const enabled = switch (mode) {
        1 => self.modes.application_cursor,
        6 => self.screen.origin_mode,
        7 => self.screen.autowrap,
        9, 1000, 1002, 1003 => self.modes.mouse_tracking == mode,
        25 => self.screen.cursor.visible,
        47, 1047, 1049 => self.alternate,
        69 => self.screen.left_right_mode,
        80 => if (self.graphics.options.images) self.graphics.sixel_display else return 0,
        1070 => if (self.graphics.options.images) self.graphics.sixel_private else return 0,
        8452 => if (self.graphics.options.images) self.graphics.sixel_right else return 0,
        1004 => self.modes.focus,
        1006 => self.modes.mouse_sgr,
        1016 => self.modes.mouse_pixels,
        2004 => self.modes.bracketed_paste,
        2026 => self.sync_deadline_ms != null,
        else => return 0,
    };
    return if (enabled) 1 else 2;
}
fn osc(self: *Session, bytes: []const u8) !void {
    var parts = std.mem.splitScalar(u8, bytes, ';');
    const command = parts.next() orelse return;
    if (std.mem.eql(u8, command, "8")) {
        const params = parts.next() orelse return;
        const uri = parts.rest();
        var id: []const u8 = "";
        var parameters = std.mem.splitScalar(u8, params, ':');
        while (parameters.next()) |item| if (std.mem.startsWith(u8, item, "id=")) {
            id = item[3..];
        };
        try self.screen.setLink(uri, id);
    } else if (std.mem.eql(u8, command, "4")) {
        while (parts.next()) |index| {
            const query = parts.next() orelse return;
            const n = std.fmt.parseInt(u8, index, 10) catch continue;
            if (std.mem.eql(u8, query, "?")) {
                var buf: [96]u8 = undefined;
                const prefix = try std.fmt.bufPrint(&buf, "4;{d}", .{n});
                try self.colorReply(prefix, Colors.indexed(n));
            }
        }
    } else if ((std.mem.eql(u8, command, "10") or std.mem.eql(u8, command, "11")) and std.mem.eql(u8, parts.next() orelse "", "?")) {
        try self.colorReply(command, if (command[1] == '0') Colors.foreground else Colors.background);
    }
}
fn colorReply(self: *Session, command: []const u8, color: u32) !void {
    var buf: [128]u8 = undefined;
    try self.reply(try std.fmt.bufPrint(&buf, "\x1b]{s};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ command, ((color >> 16) & 255) * 257, ((color >> 8) & 255) * 257, (color & 255) * 257 }));
}
fn capabilities(self: *Session, bytes: []const u8) !void {
    var parts = std.mem.splitScalar(u8, bytes, ';');
    while (parts.next()) |encoded| {
        if (encoded.len == 0 or encoded.len > 128 or encoded.len % 2 != 0) continue;
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.hexToBytes(&name_buf, encoded) catch continue;
        const value: ?[]const u8 = if (std.mem.eql(u8, name, "TN")) "xterm-256color" else if (std.mem.eql(u8, name, "Co") or std.mem.eql(u8, name, "colors")) "256" else if (std.mem.eql(u8, name, "RGB") or std.mem.eql(u8, name, "Tc")) "" else if (std.mem.eql(u8, name, "Ms")) "\x1b]52;%p1%s;%p2%s\x07" else if (std.mem.eql(u8, name, "Sync")) "\x1b[?2026%?%p1%{1}%-%tl%eh%;" else null;
        var buf: [512]u8 = undefined;
        if (value) |v| {
            if (v.len == 0) {
                try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1+r{s}\x1b\\", .{encoded}));
            } else {
                var hex_buf: [256]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "{x}", .{v});
                try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1+r{s}={s}\x1b\\", .{ encoded, hex }));
            }
        } else try self.reply(try std.fmt.bufPrint(&buf, "\x1bP0+r{s}\x1b\\", .{encoded}));
    }
}
fn status(self: *Session, bytes: []const u8) !void {
    var buf: [128]u8 = undefined;
    if (std.mem.eql(u8, bytes, "r")) {
        try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}r\x1b\\", .{ self.screen.scroll_top + 1, self.screen.scroll_bottom }));
    } else if (std.mem.eql(u8, bytes, "s")) {
        try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}s\x1b\\", .{ self.screen.scroll_left + 1, self.screen.scroll_right }));
    } else if (std.mem.eql(u8, bytes, " q")) {
        const shape: u8 = switch (self.screen.cursor.shape) {
            .block => 2,
            .underline => 4,
            .bar => 6,
        };
        try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1$r{d} q\x1b\\", .{shape}));
    } else try self.reply("\x1bP0$r\x1b\\");
}
