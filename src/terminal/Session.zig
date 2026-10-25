//! Terminal protocol state and active main/alternate screen, without OS I/O.
const std = @import("std");
const Parser = @import("Parser.zig");
const Screen = @import("Screen.zig");
const Input = @import("Input.zig");
const Strings = @import("ControlStrings.zig");
const Colors = @import("Colors.zig");
const GraphicsProtocol = @import("GraphicsProtocol.zig");
const History = @import("History.zig");
const Reflow = @import("Reflow.zig");
pub const Position = Reflow.Position;
pub const Selection = struct { first: Position, end: Position };
pub const Options = struct {
    images: bool = false,
    decoder: ?Screen.Graphics.Decoder = null,
    history_lines: usize = 0,
    history: bool = false,
    history_bytes: usize = 64 * 1024 * 1024,
    reflow: bool = false,
};
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
history: ?*History = null,
reflow: bool = false,
scroll_offset: usize = 0,
selection: ?Selection = null,
modes: Input.Modes = .{},
keyboards: [2]Keyboard = .{ .{}, .{} },
replies: std.ArrayList(u8) = .empty,
failure: ?anyerror = null,
strings: Strings = .{},
graphics: GraphicsProtocol = .{},
theme: Colors.Theme = .{},
base_theme: ?Colors.Theme = null,
palette_overrides: [256]?u32 = @splat(null),
foreground_override: ?u32 = null,
background_override: ?u32 = null,
cursor_override: ?u32 = null,
color_generation: u64 = 0,
bell_pending: bool = false,
title: [4096]u8 = undefined,
title_len: usize = 0,
title_changed: bool = false,
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
    var history: ?*History = null;
    if (options.history or options.history_lines > 0 or options.reflow) {
        history = try allocator.create(History);
        history.?.* = .{ .allocator = allocator, .max_rows = options.history_lines, .max_bytes = options.history_bytes };
        screen.history = history;
    }
    errdefer if (history) |h| {
        h.deinit();
        allocator.destroy(h);
    };
    if (options.images) try other.graphics.shareBudget(&screen.graphics);
    if (screen.graphics.budget) |budget| budget.refs += 1;
    return .{ .allocator = allocator, .screen = screen, .other = other, .history = history, .reflow = options.reflow, .graphics = .{ .options = .{ .images = options.images, .decoder = options.decoder }, .budget = screen.graphics.budget } };
}
pub fn deinit(self: *Session) void {
    self.graphics.deinit(self.allocator);
    self.screen.deinit();
    self.other.deinit();
    self.replies.deinit(self.allocator);
    self.strings.deinit(self.allocator);
    if (self.history) |h| {
        h.deinit();
        self.allocator.destroy(h);
    }
    self.* = undefined;
}
pub fn activeScreen(self: *Session) *Screen {
    return &self.screen;
}
pub fn setTheme(self: *Session, theme: Colors.Theme) void {
    self.base_theme = theme;
    self.theme = theme;
    self.refreshColors();
}
fn refreshColors(self: *Session) void {
    if (self.base_theme) |base| self.theme = base;
    for (self.palette_overrides, 0..) |color, i| if (color) |value| {
        self.theme.indexed[i] = value;
    };
    if (self.foreground_override) |color| self.theme.foreground = color;
    if (self.background_override) |color| self.theme.background = color;
    if (self.cursor_override) |color| self.theme.cursor = color;
    self.color_generation +%= 1;
    self.screen.invalidateAll();
    self.other.invalidateAll();
}
pub fn takeBell(self: *Session) bool {
    const pending = self.bell_pending;
    self.bell_pending = false;
    return pending;
}
pub fn historyCount(self: *const Session) usize {
    return if (!self.alternate) if (self.history) |h| h.count() else 0 else 0;
}
pub fn setHistoryLimits(self: *Session, lines: usize, bytes: usize) void {
    if (self.history) |h| {
        h.max_rows = lines;
        h.max_bytes = bytes;
        h.trim();
        self.scroll_offset = @min(self.scroll_offset, h.count());
    }
    self.pruneSelection();
    self.screen.invalidateAll();
}
fn pruneSelection(self: *Session) void {
    if (self.selection) |s| {
        const next = if (!self.alternate) if (self.history) |h| h.next_id else @as(u64, 0) else 0;
        const oldest = next - self.historyCount();
        if (s.first.row < oldest or s.end.row < oldest or s.first.row >= next + self.screen.rows or s.end.row >= next + self.screen.rows) self.selection = null;
    }
}
pub fn scroll(self: *Session, lines: i32) void {
    if (lines > 0) self.scroll_offset = @min(self.historyCount(), self.scroll_offset + @as(usize, @intCast(lines))) else self.scroll_offset -|= @intCast(-@as(i64, lines));
    self.screen.invalidateAll();
}
pub fn live(self: *Session) void {
    if (self.scroll_offset != 0 or self.selection != null) self.screen.invalidateAll();
    self.scroll_offset = 0;
    self.selection = null;
}
pub fn point(self: *const Session, row: usize, column: usize) Position {
    return .{ .row = (if (!self.alternate) if (self.history) |h| h.next_id else @as(u64, 0) else 0) -| self.scroll_offset + row, .column = @min(column, self.screen.columns) };
}
fn textRow(self: *const Session, id: u64) ?struct { cells: []const Screen.Cell, wrapped: bool } {
    const next = if (!self.alternate) if (self.history) |h| h.next_id else @as(u64, 0) else 0;
    if (id < next) {
        const h = self.history orelse return null;
        const oldest = next - h.count();
        if (id < oldest) return null;
        const row = h.get(@intCast(id - oldest)) orelse return null;
        return .{ .cells = row.cells, .wrapped = row.wrapped };
    }
    const row: usize = @intCast(id - next);
    const cells = self.screen.getRow(row) orelse return null;
    return .{ .cells = cells[0..if (self.screen.soft_wrapped[row]) self.screen.wrap_columns[row] else cells.len], .wrapped = self.screen.soft_wrapped[row] };
}
fn before(a: Position, b: Position) bool {
    return a.row < b.row or (a.row == b.row and a.column < b.column);
}
pub fn selected(self: *const Session, point_: Position) bool {
    const s = self.selection orelse return false;
    const first = if (before(s.first, s.end)) s.first else s.end;
    const end = if (before(s.first, s.end)) s.end else s.first;
    return !before(point_, first) and before(point_, end);
}
pub fn select(self: *Session, first: Position, end: Position) void {
    if (std.meta.eql(first, end)) {
        self.selection = null;
    } else {
        var a = first;
        var b = end;
        const reversed = before(b, a);
        if (self.textRow(a.row)) |row| if (a.column < row.cells.len and row.cells[a.column].width == 0) {
            if (reversed) a.column += 1 else a.column -|= 1;
        };
        if (self.textRow(b.row)) |row| if (b.column < row.cells.len and row.cells[b.column].width == 0) {
            if (reversed) b.column -|= 1 else b.column += 1;
        };
        self.selection = .{ .first = a, .end = b };
    }
    self.screen.invalidateAll();
}
pub fn selectWord(self: *Session, at: Position, line: bool) void {
    const row = self.textRow(at.row) orelse return;
    var left = @min(at.column, row.cells.len - 1);
    if (row.cells[left].width == 0) left -|= 1;
    var right = left + @max(1, row.cells[left].width);
    if (line) {
        left = 0;
        right = row.cells.len;
    } else {
        const space = row.cells[left].codepoint == ' ';
        while (left > 0 and (row.cells[left - 1].codepoint == ' ') == space) left -= 1;
        while (right < row.cells.len and (row.cells[right].codepoint == ' ') == space) right += 1;
    }
    self.select(.{ .row = at.row, .column = left }, .{ .row = at.row, .column = right });
}
pub fn copySelection(self: *const Session, allocator: std.mem.Allocator) ![]u8 {
    const s = self.selection orelse return allocator.alloc(u8, 0);
    const first = if (before(s.first, s.end)) s.first else s.end;
    const end = if (before(s.first, s.end)) s.end else s.first;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var id = first.row;
    while (id <= end.row) : (id += 1) {
        const row = self.textRow(id) orelse break;
        var start = if (id == first.row) @min(first.column, row.cells.len) else 0;
        if (start < row.cells.len and row.cells[start].width == 0) start -|= 1;
        var stop = if (id == end.row) @min(end.column, row.cells.len) else row.cells.len;
        if (!row.wrapped) {
            while (stop > start and row.cells[stop - 1].codepoint == ' ' and row.cells[stop - 1].grapheme.len == 0) stop -= 1;
        }
        for (row.cells[start..stop]) |cell| {
            if (cell.width == 0) continue;
            const cps: []const u21 = if (cell.grapheme.len != 0) cell.grapheme else &.{cell.codepoint};
            for (cps) |cp| {
                var bytes: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(cp, &bytes);
                try output.appendSlice(allocator, bytes[0..n]);
            }
        }
        if (id < end.row and !row.wrapped) try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}
/// An owned snapshot of history and selection; never alters the live application grid.
pub fn viewport(self: *const Session) !Screen {
    var view = try self.screen.resized(self.screen.rows, self.screen.columns);
    errdefer view.deinit();
    view.history = null;
    if (self.scroll_offset != 0) {
        view.graphics.clear();
        view.cursor.visible = false;
        for (0..view.rows) |row| {
            const source = self.textRow(self.point(row, 0).row);
            try view.copyRow(row, if (source) |s| s.cells else &.{}, if (source) |s| s.wrapped else false);
        }
    }
    for (0..view.rows) |row| for (0..view.columns) |col| {
        const head = if (view.cells[row * view.columns + col].width == 0) col -| 1 else col;
        if (self.selected(self.point(row, head))) view.cells[row * view.columns + col].style.inverse = !view.cells[row * view.columns + col].style.inverse;
    };
    return view;
}
pub fn setCursorDefaults(self: *Session, shape: @FieldType(Screen.Cursor, "shape"), blinking: bool) void {
    for ([_]*Screen{ &self.screen, &self.other }) |screen| {
        screen.default_cursor.shape = shape;
        screen.default_cursor.blinking = blinking;
        if (screen.cursor.configured) {
            screen.cursor.shape = shape;
            screen.cursor.blinking = blinking;
        }
    }
}
pub fn getModes(self: *const Session) Input.Modes {
    var modes = self.modes;
    modes.newline_mode = self.screen.newline_mode;
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
    if (rows == 0 or columns == 0) return error.InvalidDimensions;
    if (rows == self.screen.rows and columns == self.screen.columns) return;
    if (self.history) |history| if (self.reflow) {
        const main = if (self.alternate) &self.other else &self.screen;
        const alternate = if (self.alternate) &self.screen else &self.other;
        var replacement = try Reflow.prepare(main, history, rows, columns, .{
            .{ .row = history.next_id + main.cursor.row, .column = main.cursor.column + @intFromBool(main.wrap_pending) },
            .{ .row = history.next_id + main.saved.row, .column = main.saved.column },
            if (self.selection) |s| s.first else .{ .row = history.next_id, .column = 0 },
            if (self.selection) |s| s.end else .{ .row = history.next_id, .column = 0 },
            .{ .row = history.next_id -| self.scroll_offset, .column = 0 },
        });
        errdefer {
            replacement.screen.deinit();
            replacement.history.deinit();
        }
        const alt = try alternate.resized(rows, columns);
        main.deinit();
        alternate.deinit();
        history.deinit();
        history.* = replacement.history;
        main.* = replacement.screen;
        main.history = history;
        alternate.* = alt;
        if (!self.alternate) if (self.selection) |*s| {
            s.first = replacement.positions[2];
            s.end = replacement.positions[3];
        };
        self.pruneSelection();
        if (self.scroll_offset != 0) self.scroll_offset = @intCast(@min(history.count(), history.next_id -| replacement.positions[4].row));
        return;
    };
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
    const old_id = if (self.history) |h| h.next_id else 0;
    defer if (self.history) |h| {
        if (self.scroll_offset != 0) self.scroll_offset = @min(h.count(), self.scroll_offset + @as(usize, @intCast(h.next_id - old_id)));
        self.pruneSelection();
    };
    switch (event) {
        .execute => |byte| if (byte == 7) {
            self.bell_pending = true;
        },
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
            if (cmd.private_prefix == null and std.mem.eql(u8, cmd.intermediates, "!") and cmd.final == 'p') {
                self.modes.application_cursor = false;
                self.modes.application_keypad = false;
                self.sync_deadline_ms = null;
                self.sync_expired = false;
            }
            if (std.mem.eql(u8, cmd.intermediates, "$") and cmd.final == 'p' and prefix == 0) {
                for (p) |item| {
                    const mode = item.value orelse 0;
                    const enabled: ?bool = switch (mode) {
                        4 => self.screen.insert_mode,
                        20 => self.screen.newline_mode,
                        else => null,
                    };
                    var buf: [64]u8 = undefined;
                    try self.reply(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}$y", .{ mode, if (enabled) |set| @as(u8, if (set) 1 else 2) else @as(u8, 0) }));
                }
                return;
            }
            if (cmd.final == 'q' and prefix == '>' and cmd.intermediates.len == 0 and a == 0) {
                try self.reply("\x1bP>|Vertex(0.0.1)\x1b\\");
                return;
            }
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
                    1007 => self.modes.alternate_scroll = enabled,
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
    self.scroll_offset = 0;
    self.selection = null;
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
    if (mode == 2027) return 3; // Grapheme clustering is permanently enabled.
    const enabled = switch (mode) {
        1 => self.modes.application_cursor,
        6 => self.screen.origin_mode,
        5 => self.screen.reverse_video,
        12 => self.screen.cursor.blinking,
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
        1007 => self.modes.alternate_scroll,
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
    if (std.mem.eql(u8, command, "0") or std.mem.eql(u8, command, "2")) {
        const title = parts.rest();
        if (title.len >= self.title.len or !std.unicode.utf8ValidateSlice(title)) return;
        for (title) |byte| if (byte < 0x20 or byte == 0x7f) return;
        @memcpy(self.title[0..title.len], title);
        self.title[title.len] = 0;
        self.title_len = title.len;
        self.title_changed = true;
    } else if (std.mem.eql(u8, command, "8")) {
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
                try self.colorReply(prefix, self.theme.at(n));
            } else if (Colors.parse(query)) |color| {
                if (self.base_theme == null) self.base_theme = self.theme;
                self.palette_overrides[n] = color;
                self.refreshColors();
            }
        }
    } else if (std.mem.eql(u8, command, "104")) {
        if (self.base_theme == null) self.base_theme = self.theme;
        if (parts.rest().len == 0) {
            self.palette_overrides = @splat(null);
        } else {
            while (parts.next()) |index| {
                const n = std.fmt.parseInt(u8, index, 10) catch continue;
                self.palette_overrides[n] = null;
            }
        }
        self.refreshColors();
    } else {
        const number = std.fmt.parseInt(u16, command, 10) catch return;
        if (number >= 110 and number <= 112) {
            if (self.base_theme == null) self.base_theme = self.theme;
            switch (number) {
                110 => self.foreground_override = null,
                111 => self.background_override = null,
                112 => self.cursor_override = null,
                else => unreachable,
            }
            self.refreshColors();
        } else if (number >= 10 and number <= 12) {
            var n = number;
            while (parts.next()) |value| : (n += 1) {
                if (n > 12) break;
                if (std.mem.eql(u8, value, "?")) {
                    var buf: [8]u8 = undefined;
                    try self.colorReply(try std.fmt.bufPrint(&buf, "{d}", .{n}), switch (n) {
                        10 => self.theme.foreground,
                        11 => self.theme.background,
                        else => self.theme.cursor orelse self.theme.foreground,
                    });
                } else if (Colors.parse(value)) |color| {
                    if (self.base_theme == null) self.base_theme = self.theme;
                    switch (n) {
                        10 => self.foreground_override = color,
                        11 => self.background_override = color,
                        else => self.cursor_override = color,
                    }
                    self.refreshColors();
                }
            }
        }
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
        const value: ?[]const u8 = if (std.mem.eql(u8, name, "TN")) "xterm-256color" else if (std.mem.eql(u8, name, "Co") or std.mem.eql(u8, name, "colors")) "256" else if (std.mem.eql(u8, name, "RGB") or std.mem.eql(u8, name, "Tc") or std.mem.eql(u8, name, "Su")) "" else if (std.mem.eql(u8, name, "Smulx")) "\x1b[4:%p1%dm" else if (std.mem.eql(u8, name, "Setulc")) "\x1b[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%dm" else if (std.mem.eql(u8, name, "Ms")) "\x1b]52;%p1%s;%p2%s\x07" else if (std.mem.eql(u8, name, "Sync")) "\x1b[?2026%?%p1%{1}%-%tl%eh%;" else null;
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
    var buf: [512]u8 = undefined;
    if (std.mem.eql(u8, bytes, "m")) {
        var writer = std.Io.Writer.fixed(&buf);
        try writer.writeAll("\x1bP1$r0");
        const style = self.screen.style;
        inline for (.{ .{ "bold", 1 }, .{ "faint", 2 }, .{ "italic", 3 }, .{ "blink", 5 }, .{ "inverse", 7 }, .{ "hidden", 8 }, .{ "strikethrough", 9 } }) |attribute| {
            if (@field(style, attribute[0])) try writer.print(";{d}", .{@as(u8, attribute[1])});
        }
        if (style.underline) try writer.print(";4:{d}", .{@as(u8, @backingInt(style.underline_style)) + 1});
        try statusColor(&writer, 38, style.foreground);
        try statusColor(&writer, 48, style.background);
        try statusColor(&writer, 58, style.underline_color);
        try writer.writeAll("m\x1b\\");
        try self.reply(writer.buffered());
    } else if (std.mem.eql(u8, bytes, "r")) {
        try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}r\x1b\\", .{ self.screen.scroll_top + 1, self.screen.scroll_bottom }));
    } else if (std.mem.eql(u8, bytes, "s")) {
        try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}s\x1b\\", .{ self.screen.scroll_left + 1, self.screen.scroll_right }));
    } else if (std.mem.eql(u8, bytes, " q")) {
        const shape: u8 = (@as(u8, switch (self.screen.cursor.shape) {
            .block => 2,
            .underline => 4,
            .bar => 6,
        }) - @as(u8, @intFromBool(self.screen.cursor.blinking)));
        try self.reply(try std.fmt.bufPrint(&buf, "\x1bP1$r{d} q\x1b\\", .{shape}));
    } else try self.reply("\x1bP0$r\x1b\\");
}
fn statusColor(writer: *std.Io.Writer, kind: u8, color: Screen.Color) !void {
    switch (color) {
        .default => {},
        .indexed => |index| try writer.print(";{d};5;{d}", .{ kind, index }),
        .rgb => |rgb| try writer.print(";{d};2;{d};{d};{d}", .{ kind, rgb.r, rgb.g, rgb.b }),
    }
}
