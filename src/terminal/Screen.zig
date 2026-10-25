//! Owned grapheme-aware grid. apply() reports allocation failures; handle()
//! latches them for parser-handler compatibility. No I/O or renderer is involved.
const std = @import("std");
const Parser = @import("Parser.zig");
const Screen = @This();
const Unicode = @import("Unicode.zig");
var next_identity = std.atomic.Value(u64).init(1);

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},
    width: u2 = 1,
    /// Immutable owned cluster on a head cell; empty for single scalars.
    grapheme: []const u21 = &.{},
};

pub const Cursor = struct {
    row: usize = 0,
    column: usize = 0,
    visible: bool = true,
    shape: enum { block, underline, bar } = .block,
};

const Saved = struct {
    row: usize = 0,
    column: usize = 0,
    style: Style = .{},
    origin_mode: bool = false,
    autowrap: bool = true,
    wrap_pending: bool = false,
    charsets: [2]bool = .{ false, false },
    active_charset: u1 = 0,
};

allocator: std.mem.Allocator,
/// Unique across allocation reuse, including temporary IME overlays.
identity: u64,
/// Dimensions and backing storage must not be modified by callers.
rows: usize,
columns: usize,
cells: []Cell,
damage_rows: []bool,
row_generations: []u64,
tab_stops: []bool,
soft_wrapped: []bool,
cursor: Cursor = .{},
style: Style = .{},
scroll_top: usize = 0,
scroll_bottom: usize,
scroll_left: usize = 0,
scroll_right: usize,
left_right_mode: bool = false,
charsets: [2]bool = .{ false, false },
active_charset: u1 = 0,
repeat_codepoint: ?u21 = null,
origin_mode: bool = false,
autowrap: bool = true,
wrap_pending: bool = false,
saved: Saved = .{},
last_print: ?usize = null,
failure: ?anyerror = null,
revision: u64 = 0,
format_pending: std.ArrayList(u21) = .empty,

pub fn init(allocator: std.mem.Allocator, rows: usize, columns: usize) !Screen {
    if (rows == 0 or columns == 0) return error.InvalidDimensions;
    const count = std.math.mul(usize, rows, columns) catch return error.InvalidDimensions;
    _ = std.math.mul(usize, count, @sizeOf(Cell)) catch return error.InvalidDimensions;
    const cells = try allocator.alloc(Cell, count);
    errdefer allocator.free(cells);
    const damage_rows = try allocator.alloc(bool, rows);
    errdefer allocator.free(damage_rows);
    const row_generations = try allocator.alloc(u64, rows);
    errdefer allocator.free(row_generations);
    const tab_stops = try allocator.alloc(bool, columns);
    errdefer allocator.free(tab_stops);
    for (tab_stops, 0..) |*stop, col| stop.* = col != 0 and col % 8 == 0;
    @memset(row_generations, 1);
    const soft_wrapped = try allocator.alloc(bool, rows);
    @memset(soft_wrapped, false);
    @memset(damage_rows, true);
    @memset(cells, .{});
    return .{
        .allocator = allocator,
        .identity = next_identity.fetchAdd(1, .monotonic),
        .rows = rows,
        .columns = columns,
        .cells = cells,
        .damage_rows = damage_rows,
        .row_generations = row_generations,
        .tab_stops = tab_stops,
        .scroll_right = columns,
        .soft_wrapped = soft_wrapped,
        .scroll_bottom = rows,
    };
}

pub fn deinit(self: *Screen) void {
    for (self.cells) |cell| self.allocator.free(cell.grapheme);
    self.allocator.free(self.cells);
    self.allocator.free(self.damage_rows);
    self.allocator.free(self.row_generations);
    self.allocator.free(self.tab_stops);
    self.allocator.free(self.soft_wrapped);
    self.format_pending.deinit(self.allocator);
    self.* = undefined;
}

/// Preserve the top-left overlap without reflow. A size change invalidates
/// borrowed rows. Failure leaves every field and the old storage unchanged.
pub fn resize(self: *Screen, rows: usize, columns: usize) !void {
    if (rows == 0 or columns == 0) return error.InvalidDimensions;
    if (rows == self.rows and columns == self.columns) return;
    const replacement = try self.resized(rows, columns);
    self.deinit();
    self.* = replacement;
}

/// Make a fully independent replacement, leaving this screen untouched on failure.
pub fn resized(self: *const Screen, rows: usize, columns: usize) !Screen {
    var replacement = try init(self.allocator, rows, columns);
    errdefer replacement.deinit();
    replacement.cursor = self.cursor;
    replacement.saved = self.saved;
    replacement.style = self.style;
    replacement.origin_mode = self.origin_mode;
    replacement.autowrap = self.autowrap;
    replacement.charsets = self.charsets;
    replacement.active_charset = self.active_charset;
    replacement.left_right_mode = self.left_right_mode;
    @memcpy(replacement.tab_stops[0..@min(columns, self.columns)], self.tab_stops[0..@min(columns, self.columns)]);
    replacement.revision = self.revision +% 1;
    try replacement.format_pending.appendSlice(self.allocator, self.format_pending.items);
    const width = @min(columns, self.columns);
    for (0..@min(rows, self.rows)) |row| {
        for (0..width) |col| {
            const cell = self.cells[row * self.columns + col];
            if (cell.width == 0 or (cell.width == 2 and col + 1 >= columns)) continue;
            var copy = cell;
            copy.grapheme = try self.allocator.dupe(u21, cell.grapheme);
            replacement.cells[row * columns + col] = copy;
            if (cell.width == 2) replacement.cells[row * columns + col + 1] = .{ .codepoint = 0, .width = 0, .style = cell.style };
        }
    }
    replacement.cursor.row = @min(self.cursor.row, rows - 1);
    replacement.cursor.column = @min(self.cursor.column, columns - 1);
    replacement.saved.row = @min(self.saved.row, rows - 1);
    replacement.saved.column = @min(self.saved.column, columns - 1);
    replacement.saved.wrap_pending = false;
    if (columns == self.columns) @memcpy(replacement.soft_wrapped[0..@min(rows, self.rows)], self.soft_wrapped[0..@min(rows, self.rows)]);
    return replacement;
}

/// Reset screen state only. Reset the separate Parser as well to abandon input.
pub fn reset(self: *Screen) void {
    for (self.cells) |cell| self.allocator.free(cell.grapheme);
    @memset(self.cells, .{});
    @memset(self.soft_wrapped, false);
    self.last_print = null;
    self.format_pending.clearRetainingCapacity();
    self.failure = null;
    self.invalidateAll();
    self.cursor = .{};
    self.style = .{};
    self.scroll_top = 0;
    self.scroll_bottom = self.rows;
    self.scroll_left = 0;
    self.scroll_right = self.columns;
    self.left_right_mode = false;
    self.charsets = .{ false, false };
    self.active_charset = 0;
    self.repeat_codepoint = null;
    for (self.tab_stops, 0..) |*stop, col| stop.* = col != 0 and col % 8 == 0;
    self.origin_mode = false;
    self.autowrap = true;
    self.wrap_pending = false;
    self.saved = .{};
}

/// Accessors use zero-based coordinates and return null outside the grid.
pub fn getCell(self: *const Screen, row: usize, column: usize) ?Cell {
    if (row >= self.rows or column >= self.columns) return null;
    return self.cells[row * self.columns + column];
}

/// Borrowed rows remain valid until resize/deinit; events update their cells.
pub fn getRow(self: *const Screen, row: usize) ?[]const Cell {
    if (row >= self.rows) return null;
    return self.cells[row * self.columns ..][0..self.columns];
}

pub fn getCursor(self: *const Screen) Cursor {
    return self.cursor;
}

pub fn getRowGeneration(self: *const Screen, row: usize) ?u64 {
    return if (row < self.rows) self.row_generations[row] else null;
}

/// Borrowed row damage since the last clear; cursor damage is tracked by the renderer.
/// Valid until resize/deinit. A single presentation consumer owns clearing damage.
pub fn getDamageRows(self: *const Screen) []const bool {
    return self.damage_rows;
}

/// Acknowledge only after a successful presentation, never while a frame is deferred.
pub fn clearDamage(self: *Screen) void {
    @memset(self.damage_rows, false);
}

pub fn invalidateAll(self: *Screen) void {
    self.revision +%= 1;
    self.touchRange(0, self.rows);
}

/// Synchronously consume an event, including its borrowed parameter slices.
pub fn handle(self: *Screen, event: Parser.Event) void {
    if (self.failure != null) return;
    self.apply(event) catch |err| {
        self.failure = err;
    };
}

pub fn takeError(self: *Screen) ?anyerror {
    const failure = self.failure;
    self.failure = null;
    return failure;
}

pub fn getGrapheme(self: *const Screen, row: usize, column: usize) ?[]const u21 {
    if (row >= self.rows or column >= self.columns) return null;
    const cell = &self.cells[row * self.columns + column];
    if (cell.width == 0) return &.{};
    return if (cell.grapheme.len != 0) cell.grapheme else @as(*const [1]u21, &cell.codepoint)[0..];
}

pub fn apply(self: *Screen, event: Parser.Event) !void {
    self.revision +%= 1;
    switch (event) {
        .print => |codepoint| {
            const cp = if (self.charsets[self.active_charset]) decGraphic(codepoint) else codepoint;
            try self.print(cp);
            self.repeat_codepoint = cp;
        },
        .execute => |control| {
            self.last_print = null;
            self.execute(control);
        },
        .esc => |command| {
            if (std.mem.eql(u8, command.intermediates, "(") or std.mem.eql(u8, command.intermediates, ")")) {
                if (command.final == '0' or command.final == 'B') self.charsets[if (command.intermediates[0] == '(') @as(usize, 0) else 1] = command.final == '0';
                return;
            }
            if (command.intermediates.len != 0) return;
            self.last_print = null;
            switch (command.final) {
                'H' => self.tab_stops[self.cursor.column] = true,
                '7' => self.save(),
                '8' => self.restore(),
                'D' => self.index(),
                'E' => {
                    self.cursor.column = self.leftEdge();
                    self.index();
                },
                'M' => self.reverseIndex(),
                'c' => self.reset(),
                else => {},
            }
        },
        .csi => |command| {
            if (command.final == 'b' and command.private_prefix == null and command.intermediates.len == 0) {
                for (command.parameters) |item| if (item.separator == .colon) return;
                if (self.repeat_codepoint) |cp| for (0..@min(countParameter(command.parameters, 0), self.cells.len)) |_| try self.print(cp);
                return;
            }
            if (command.final != 'm' or command.private_prefix != null) self.last_print = null;
            self.csi(command);
        },
        else => {},
    }
}

fn clearCell(self: *Screen, at: usize) void {
    self.allocator.free(self.cells[at].grapheme);
    self.cells[at] = .{ .style = self.style };
}
fn clearCluster(self: *Screen, at: usize) void {
    const head = if (self.cells[at].width == 0 and at % self.columns > 0) at - 1 else at;
    const width = self.cells[head].width;
    self.clearCell(head);
    if (width == 2 and head + 1 < self.cells.len) self.clearCell(head + 1);
}
fn print(self: *Screen, cp: u21) !void {
    if (self.last_print) |at| {
        const existing = self.getGrapheme(at / self.columns, at % self.columns).?;
        if (Unicode.joins(existing, cp) or Unicode.isFormat(cp)) {
            const joined = try self.allocator.alloc(u21, existing.len + 1);
            @memcpy(joined[0..existing.len], existing);
            joined[existing.len] = cp;
            var cell = self.cells[at];
            const new_width = if (Unicode.isFormat(cp)) cell.width else Unicode.width(joined);
            self.allocator.free(cell.grapheme);
            cell.grapheme = joined;
            self.cells[at].grapheme = &.{};
            var target = at;
            self.touch(at / self.columns);
            if (new_width == 2 and at % self.columns == self.rightEdge() - 1) {
                self.clearCluster(at);
                if (self.autowrap and self.rightEdge() - self.leftEdge() > 1) {
                    self.soft_wrapped[self.cursor.row] = true;
                    self.cursor.column = self.leftEdge();
                    self.index();
                    target = self.cursor.row * self.columns + self.leftEdge();
                } else {
                    self.allocator.free(joined);
                    cell = .{ .codepoint = 0xfffd, .style = cell.style };
                }
            }
            const old_width = cell.width;
            cell.width = if (new_width == 2 and target % self.columns + 1 >= self.rightEdge()) 1 else new_width;
            if (target != at) self.clearCluster(target);
            if (cell.width == 2) {
                self.clearCluster(target + 1);
                self.cells[target + 1] = .{ .codepoint = 0, .width = 0, .style = cell.style };
            } else if (old_width == 2 and target + 1 < self.cells.len) self.clearCell(target + 1);
            self.cells[target] = cell;
            self.last_print = target;
            if (Unicode.isFormat(cp)) {
                self.touch(target / self.columns);
                return;
            }
            self.cursor.row = target / self.columns;
            self.advance(target % self.columns, cell.width);
            self.touch(self.cursor.row);
            return;
        }
    }
    if (Unicode.isFormat(cp)) {
        try self.format_pending.append(self.allocator, cp);
        return;
    }
    const width = Unicode.scalarWidth(cp);
    var owned: []const u21 = &.{};
    if (self.format_pending.items.len != 0) {
        const prefix = self.format_pending.items;
        const cluster = try self.allocator.alloc(u21, prefix.len + if (width == 0) @as(usize, 2) else 1);
        @memcpy(cluster[0..prefix.len], prefix);
        if (width == 0) cluster[prefix.len] = 0x25cc;
        cluster[cluster.len - 1] = cp;
        owned = cluster;
        self.format_pending.clearRetainingCapacity();
    } else if (width == 0) owned = try self.allocator.dupe(u21, &.{ 0x25cc, cp });
    if (self.wrap_pending or (width == 2 and self.cursor.column == self.rightEdge() - 1 and self.autowrap and self.rightEdge() - self.leftEdge() > 1)) {
        self.soft_wrapped[self.cursor.row] = true;
        self.cursor.column = self.leftEdge();
        self.index();
    }
    const at = self.cursor.row * self.columns + self.cursor.column;
    const actual: u2 = if (width == 2 and self.cursor.column + 1 < self.rightEdge()) 2 else 1;
    if (width == 2 and actual == 1) {
        self.allocator.free(owned);
        owned = &.{};
    }
    self.clearCluster(at);
    if (actual == 2) {
        self.clearCluster(at + 1);
        self.cells[at + 1] = .{ .codepoint = 0, .width = 0, .style = self.style };
    }
    self.cells[at] = .{ .codepoint = if (width == 0) 0x25cc else if (width == 2 and actual == 1) 0xfffd else cp, .style = self.style, .width = actual, .grapheme = owned };
    self.last_print = at;
    self.touch(self.cursor.row);
    self.advance(at % self.columns, actual);
}
fn advance(self: *Screen, column: usize, width: u2) void {
    const next = column + width;
    const right = self.rightEdge();
    self.cursor.column = @min(next, right - 1);
    self.wrap_pending = next >= right and self.autowrap;
}

fn execute(self: *Screen, control: u8) void {
    switch (control) {
        0x08 => {
            self.cursor.column -= @min(@as(usize, 1), self.cursor.column - self.leftEdge());
            self.wrap_pending = false;
        },
        0x09 => {
            self.tabForward(1);
            self.wrap_pending = false;
        },
        0x0a, 0x0b, 0x0c => {
            self.soft_wrapped[self.cursor.row] = false;
            self.index();
        },
        0x0d => {
            self.cursor.column = self.leftEdge();
            self.wrap_pending = false;
        },
        0x0e => self.active_charset = 1,
        0x0f => self.active_charset = 0,
        else => {},
    }
}

fn index(self: *Screen) void {
    self.wrap_pending = false;
    if (self.cursor.row == self.scroll_bottom - 1 and self.insideHorizontal()) {
        self.scrollUp(self.scroll_top, self.scroll_bottom, 1);
    } else if (self.cursor.row < self.rows - 1) {
        self.cursor.row += 1;
    }
}

fn reverseIndex(self: *Screen) void {
    self.wrap_pending = false;
    if (self.cursor.row == self.scroll_top and self.insideHorizontal()) {
        self.scrollDown(self.scroll_top, self.scroll_bottom, 1);
    } else {
        self.cursor.row -|= 1;
    }
}

fn save(self: *Screen) void {
    self.saved = .{
        .row = self.cursor.row,
        .column = self.cursor.column,
        .style = self.style,
        .origin_mode = self.origin_mode,
        .autowrap = self.autowrap,
        .wrap_pending = self.wrap_pending,
        .charsets = self.charsets,
        .active_charset = self.active_charset,
    };
}

fn restore(self: *Screen) void {
    self.style = self.saved.style;
    self.origin_mode = self.saved.origin_mode;
    self.autowrap = self.saved.autowrap;
    self.charsets = self.saved.charsets;
    self.active_charset = self.saved.active_charset;
    const top = if (self.origin_mode) self.scroll_top else 0;
    const bottom = if (self.origin_mode) self.scroll_bottom else self.rows;
    self.cursor.row = std.math.clamp(self.saved.row, top, bottom - 1);
    self.cursor.column = @min(self.saved.column, self.columns - 1);
    self.wrap_pending = self.saved.wrap_pending;
}

fn parameter(parameters: []const Parser.Parameter, at: usize, default: u16) u16 {
    if (at >= parameters.len) return default;
    return parameters[at].value orelse default;
}

fn countParameter(parameters: []const Parser.Parameter, at: usize) usize {
    return @max(1, parameter(parameters, at, 1));
}

fn csi(self: *Screen, command: Parser.Sequence) void {
    const p = command.parameters;
    if (std.mem.eql(u8, command.intermediates, " ") and command.final == 'q' and command.private_prefix == null) {
        const shape = parameter(p, 0, 0);
        if (p.len <= 1 and shape <= 6) self.cursor.shape = switch (shape) {
            3, 4 => .underline,
            5, 6 => .bar,
            else => .block,
        };
        return;
    }
    if (command.intermediates.len != 0) return;
    if (command.private_prefix) |prefix| {
        if (prefix == '?' and (command.final == 'h' or command.final == 'l')) {
            // Subparameters are not legal in mode lists.
            for (p) |item| if (item.separator == .colon) return;
            const enabled = command.final == 'h';
            for (p) |item| switch (item.value orelse 0) {
                6 => {
                    self.origin_mode = enabled;
                    self.position(1, 1);
                },
                7 => {
                    self.autowrap = enabled;
                    self.wrap_pending = false;
                },
                25 => self.cursor.visible = enabled,
                69 => {
                    self.left_right_mode = enabled;
                    self.scroll_left = 0;
                    self.scroll_right = self.columns;
                    self.wrap_pending = false;
                },
                else => {},
            };
        }
        return;
    }
    if (command.final == 'm') {
        self.sgr(p);
        return;
    }
    for (p) |item| if (item.separator == .colon) return;
    const n = countParameter(p, 0);
    switch (command.final) {
        'A' => self.moveUp(n),
        'B' => self.moveDown(n),
        'C' => {
            self.cursor.column += @min(n, self.rightEdge() - 1 - self.cursor.column);
            self.wrap_pending = false;
        },
        'D' => {
            self.cursor.column -= @min(n, self.cursor.column - self.leftEdge());
            self.wrap_pending = false;
        },
        'E' => {
            self.moveDown(n);
            self.cursor.column = self.leftEdge();
        },
        'F' => {
            self.moveUp(n);
            self.cursor.column = self.leftEdge();
        },
        'G' => {
            const left = if (self.origin_mode and self.left_right_mode) self.scroll_left else 0;
            const right = if (self.origin_mode and self.left_right_mode) self.scroll_right else self.columns;
            self.cursor.column = left + @min(n, right - left) - 1;
            self.wrap_pending = false;
        },
        'H', 'f' => self.position(n, countParameter(p, 1)),
        'd' => {
            const column = self.cursor.column;
            self.position(n, 1);
            self.cursor.column = column;
        },
        's' => if (self.left_right_mode) {
            const left = countParameter(p, 0);
            const raw_right = parameter(p, 1, 0);
            const right = if (raw_right == 0) self.columns else raw_right;
            if (left >= right or right > self.columns) return;
            self.scroll_left = left - 1;
            self.scroll_right = right;
            self.position(1, 1);
        } else self.save(),
        'u' => self.restore(),
        'g' => switch (parameter(p, 0, 0)) {
            0 => self.tab_stops[self.cursor.column] = false,
            3 => @memset(self.tab_stops, false),
            else => {},
        },
        'I' => self.tabForward(n),
        'Z' => self.tabBackward(n),
        'J' => self.eraseDisplay(parameter(p, 0, 0)),
        'K' => self.eraseLine(parameter(p, 0, 0)),
        'X' => {
            const start = self.cursor.row * self.columns + self.cursor.column;
            self.blank(start, start + @min(n, self.rightEdge() - self.cursor.column));
            self.wrap_pending = false;
        },
        '@' => self.insertCharacters(n),
        'P' => self.deleteCharacters(n),
        'L', 'M' => {
            if (self.cursor.row < self.scroll_top or self.cursor.row >= self.scroll_bottom or !self.insideHorizontal()) return;
            if (command.final == 'L') {
                self.scrollDown(self.cursor.row, self.scroll_bottom, n);
            } else {
                self.scrollUp(self.cursor.row, self.scroll_bottom, n);
            }
            self.cursor.column = self.leftEdge();
            self.wrap_pending = false;
        },
        'S' => {
            self.scrollUp(self.scroll_top, self.scroll_bottom, n);
            self.wrap_pending = false;
        },
        'T' => {
            self.scrollDown(self.scroll_top, self.scroll_bottom, n);
            self.wrap_pending = false;
        },
        'r' => {
            const top = countParameter(p, 0);
            const raw_bottom = parameter(p, 1, 0);
            const bottom = if (raw_bottom == 0) self.rows else raw_bottom;
            if (top >= bottom or bottom > self.rows) return;
            self.scroll_top = top - 1;
            self.scroll_bottom = bottom;
            self.position(1, 1);
        },
        else => {},
    }
}

fn position(self: *Screen, row: usize, column: usize) void {
    const top = if (self.origin_mode) self.scroll_top else 0;
    const bottom = if (self.origin_mode) self.scroll_bottom else self.rows;
    self.cursor.row = top + @min(row, bottom - top) - 1;
    const left = if (self.origin_mode and self.left_right_mode) self.scroll_left else 0;
    const right = if (self.origin_mode and self.left_right_mode) self.scroll_right else self.columns;
    self.cursor.column = left + @min(column, right - left) - 1;
    self.wrap_pending = false;
}

fn moveUp(self: *Screen, count: usize) void {
    const top = if (self.cursor.row >= self.scroll_top) self.scroll_top else 0;
    self.cursor.row -= @min(count, self.cursor.row - top);
    self.wrap_pending = false;
}

fn moveDown(self: *Screen, count: usize) void {
    const bottom = if (self.cursor.row < self.scroll_bottom) self.scroll_bottom else self.rows;
    self.cursor.row += @min(count, bottom - 1 - self.cursor.row);
    self.wrap_pending = false;
}

fn blank(self: *Screen, start: usize, end: usize) void {
    if (start >= end) return;
    for (start..end) |at| self.clearCluster(at);
    for (start / self.columns..(end - 1) / self.columns + 1) |row| {
        if (start <= row * self.columns and end >= (row + 1) * self.columns) self.soft_wrapped[row] = false;
    }
    self.touchRange(start / self.columns, (end - 1) / self.columns + 1);
}

fn eraseDisplay(self: *Screen, mode: u16) void {
    const at = self.cursor.row * self.columns + self.cursor.column;
    switch (mode) {
        0 => self.blank(at, self.cells.len),
        1 => self.blank(0, at + 1),
        2 => self.blank(0, self.cells.len),
        else => return,
    }
    self.wrap_pending = false;
}

fn eraseLine(self: *Screen, mode: u16) void {
    const start = self.cursor.row * self.columns;
    const at = start + self.cursor.column;
    switch (mode) {
        0 => self.blank(at, start + self.columns),
        1 => self.blank(start, at + 1),
        2 => self.blank(start, start + self.columns),
        else => return,
    }
    self.wrap_pending = false;
}

fn insertCharacters(self: *Screen, count: usize) void {
    const n = @min(count, self.rightEdge() - self.cursor.column);
    const start = self.cursor.row * self.columns + self.cursor.column;
    const end = self.cursor.row * self.columns + self.rightEdge();
    if (self.cells[start].width == 0) self.clearCluster(start);
    if (end - n > start and self.cells[end - n].width == 0) self.clearCluster(end - n);
    for (end - n..end) |at| self.clearCell(at);
    std.mem.copyBackwards(Cell, self.cells[start + n .. end], self.cells[start .. end - n]);
    @memset(self.cells[start .. start + n], .{ .style = self.style });
    self.touch(self.cursor.row);
    self.wrap_pending = false;
}

fn deleteCharacters(self: *Screen, count: usize) void {
    const n = @min(count, self.rightEdge() - self.cursor.column);
    const start = self.cursor.row * self.columns + self.cursor.column;
    const end = self.cursor.row * self.columns + self.rightEdge();
    if (self.cells[start].width == 0) self.clearCluster(start);
    if (start + n < end and self.cells[start + n].width == 0) self.clearCluster(start + n);
    for (start..start + n) |at| self.clearCell(at);
    std.mem.copyForwards(Cell, self.cells[start .. end - n], self.cells[start + n .. end]);
    @memset(self.cells[end - n .. end], .{ .style = self.style });
    self.touch(self.cursor.row);
    self.wrap_pending = false;
}

fn scrollUp(self: *Screen, top: usize, bottom: usize, count: usize) void {
    if (self.left_right_mode) return self.scrollRectangle(top, bottom, count, false);
    const start = top * self.columns;
    const end = bottom * self.columns;
    const distance = @min(count, bottom - top) * self.columns;
    for (start..start + distance) |at| self.clearCell(at);
    std.mem.copyForwards(Cell, self.cells[start .. end - distance], self.cells[start + distance .. end]);
    const lines = distance / self.columns;
    std.mem.copyForwards(bool, self.soft_wrapped[top .. bottom - lines], self.soft_wrapped[top + lines .. bottom]);
    @memset(self.soft_wrapped[bottom - lines .. bottom], false);
    self.touchRange(top, bottom);
    @memset(self.cells[end - distance .. end], .{ .style = self.style });
}

fn scrollDown(self: *Screen, top: usize, bottom: usize, count: usize) void {
    if (self.left_right_mode) return self.scrollRectangle(top, bottom, count, true);
    const start = top * self.columns;
    const end = bottom * self.columns;
    const distance = @min(count, bottom - top) * self.columns;
    for (end - distance..end) |at| self.clearCell(at);
    std.mem.copyBackwards(Cell, self.cells[start + distance .. end], self.cells[start .. end - distance]);
    const lines = distance / self.columns;
    std.mem.copyBackwards(bool, self.soft_wrapped[top + lines .. bottom], self.soft_wrapped[top .. bottom - lines]);
    @memset(self.soft_wrapped[top .. top + lines], false);
    self.touchRange(top, bottom);
    @memset(self.cells[start .. start + distance], .{ .style = self.style });
}

fn sgr(self: *Screen, parameters: []const Parser.Parameter) void {
    if (parameters.len == 0) self.style = .{};
    var i: usize = 0;
    while (i < parameters.len) {
        var end = i + 1;
        while (end < parameters.len and parameters[end].separator == .colon) : (end += 1) {}
        const value = parameters[i].value orelse 0;
        if (value == 38 or value == 48) {
            const color = if (end > i + 1)
                colonColor(parameters[i + 1 .. end])
            else color: {
                const mode = parameter(parameters, i + 1, 0);
                // Consume incomplete/invalid components too. An unknown mode
                // has no defined arity, so discard the remainder of this SGR.
                const components: usize = switch (mode) {
                    5 => 2,
                    2 => 4,
                    else => {
                        end = parameters.len;
                        break :color null;
                    },
                };
                end = @min(parameters.len, i + 1 + components);
                // A colon subgroup inside semicolon color syntax is invalid.
                while (end < parameters.len and parameters[end].separator == .colon) : (end += 1) {}
                const group = parameters[i + 1 .. end];
                for (group) |item| if (item.separator != .semicolon) break :color null;
                break :color colonColor(group);
            };
            if (color) |valid| {
                if (value == 38) self.style.foreground = valid else self.style.background = valid;
            }
        } else if (end == i + 1) {
            switch (value) {
                0 => self.style = .{},
                1 => self.style.bold = true,
                2 => self.style.faint = true,
                3 => self.style.italic = true,
                4 => self.style.underline = true,
                5, 6 => self.style.blink = true,
                7 => self.style.inverse = true,
                8 => self.style.hidden = true,
                9 => self.style.strikethrough = true,
                22 => {
                    self.style.bold = false;
                    self.style.faint = false;
                },
                23 => self.style.italic = false,
                24 => self.style.underline = false,
                25 => self.style.blink = false,
                27 => self.style.inverse = false,
                28 => self.style.hidden = false,
                29 => self.style.strikethrough = false,
                30...37 => self.style.foreground = .{ .indexed = @intCast(value - 30) },
                39 => self.style.foreground = .default,
                40...47 => self.style.background = .{ .indexed = @intCast(value - 40) },
                49 => self.style.background = .default,
                90...97 => self.style.foreground = .{ .indexed = @intCast(value - 90 + 8) },
                100...107 => self.style.background = .{ .indexed = @intCast(value - 100 + 8) },
                else => {},
            }
        }
        i = end;
    }
}

/// Accept 5:n, 2:r:g:b, and 2:[colorspace]:r:g:b (empty/zero colorspace).
fn colonColor(group: []const Parser.Parameter) ?Color {
    if (group.len == 0) return null;
    const mode = group[0].value orelse return null;
    if (mode == 5 and group.len == 2) return .{ .indexed = component(group[1]) orelse return null };
    if (mode != 2 or (group.len != 4 and group.len != 5)) return null;
    if (group.len == 5 and (group[1].value orelse 0) != 0) return null;
    const rgb = group[group.len - 3 ..];
    return .{ .rgb = .{
        .r = component(rgb[0]) orelse return null,
        .g = component(rgb[1]) orelse return null,
        .b = component(rgb[2]) orelse return null,
    } };
}

fn component(item: Parser.Parameter) ?u8 {
    const value = item.value orelse return null;
    return std.math.cast(u8, value);
}

fn touch(self: *Screen, row: usize) void {
    self.damage_rows[row] = true;
    self.row_generations[row] +%= 1;
}
fn touchRange(self: *Screen, first: usize, end: usize) void {
    for (first..end) |row| self.touch(row);
}
fn insideHorizontal(self: *const Screen) bool {
    return !self.left_right_mode or (self.cursor.column >= self.scroll_left and self.cursor.column < self.scroll_right);
}
fn leftEdge(self: *const Screen) usize {
    return if (self.left_right_mode and self.cursor.column >= self.scroll_left) self.scroll_left else 0;
}
fn rightEdge(self: *const Screen) usize {
    return if (self.left_right_mode and self.cursor.column < self.scroll_right) self.scroll_right else self.columns;
}
fn tabForward(self: *Screen, count: usize) void {
    for (0..@min(count, self.columns)) |_| {
        var col = self.cursor.column;
        while (col + 1 < self.rightEdge()) {
            col += 1;
            if (self.tab_stops[col]) break;
        }
        self.cursor.column = col;
    }
    self.wrap_pending = false;
}
fn tabBackward(self: *Screen, count: usize) void {
    for (0..@min(count, self.columns)) |_| {
        var col = self.cursor.column;
        while (col > self.leftEdge()) {
            col -= 1;
            if (self.tab_stops[col]) break;
        }
        self.cursor.column = col;
    }
    self.wrap_pending = false;
}
fn scrollRectangle(self: *Screen, top: usize, bottom: usize, count: usize, down: bool) void {
    const n = @min(count, bottom - top);
    const left = self.scroll_left;
    const right = self.scroll_right;
    // A cluster straddling a margin must be erased as a whole before ownership moves.
    for (top..bottom) |row| {
        const base = row * self.columns;
        if (self.cells[base + left].width == 0) self.clearCluster(base + left);
        if (right < self.columns and self.cells[base + right].width == 0) self.clearCluster(base + right);
    }
    const first = if (down) bottom - n else top;
    for (first..first + n) |row| for (left..right) |col| self.clearCell(row * self.columns + col);
    for (0..bottom - top - n) |i| {
        const dest = if (down) bottom - 1 - i else top + i;
        const source = if (down) dest - n else dest + n;
        @memcpy(self.cells[dest * self.columns + left .. dest * self.columns + right], self.cells[source * self.columns + left .. source * self.columns + right]);
    }
    const exposed = if (down) top else bottom - n;
    for (exposed..exposed + n) |row| @memset(self.cells[row * self.columns + left .. row * self.columns + right], .{ .style = self.style });
    @memset(self.soft_wrapped[top..bottom], false);
    self.touchRange(top, bottom);
}
fn decGraphic(cp: u21) u21 {
    const table = [_]u21{ 0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0, 0x00b1, 0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c, 0x23ba, 0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534, 0x252c, 0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7 };
    return if (cp >= 0x60 and cp <= 0x7e) table[cp - 0x60] else cp;
}
