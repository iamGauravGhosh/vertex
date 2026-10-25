//! Owned grapheme-aware grid. apply() reports allocation failures; handle()
//! latches them for parser-handler compatibility. No I/O or renderer is involved.
const std = @import("std");
const Parser = @import("Parser.zig");
const Screen = @This();
const Unicode = @import("Unicode.zig");

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
};

const Saved = struct {
    row: usize = 0,
    column: usize = 0,
    style: Style = .{},
    origin_mode: bool = false,
    autowrap: bool = true,
    wrap_pending: bool = false,
};

allocator: std.mem.Allocator,
/// Dimensions and backing storage must not be modified by callers.
rows: usize,
columns: usize,
cells: []Cell,
damage_rows: []bool,
soft_wrapped: []bool,
cursor: Cursor = .{},
style: Style = .{},
scroll_top: usize = 0,
scroll_bottom: usize,
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
    const soft_wrapped = try allocator.alloc(bool, rows);
    @memset(soft_wrapped, false);
    @memset(damage_rows, true);
    @memset(cells, .{});
    return .{
        .allocator = allocator,
        .rows = rows,
        .columns = columns,
        .cells = cells,
        .damage_rows = damage_rows,
        .soft_wrapped = soft_wrapped,
        .scroll_bottom = rows,
    };
}

pub fn deinit(self: *Screen) void {
    for (self.cells) |cell| self.allocator.free(cell.grapheme);
    self.allocator.free(self.cells);
    self.allocator.free(self.damage_rows);
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
    @memset(self.damage_rows, true);
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
        .print => |codepoint| try self.print(codepoint),
        .execute => |control| {
            self.last_print = null;
            self.execute(control);
        },
        .esc => |command| {
            if (command.intermediates.len != 0) return;
            self.last_print = null;
            switch (command.final) {
                '7' => self.save(),
                '8' => self.restore(),
                'D' => self.index(),
                'E' => {
                    self.cursor.column = 0;
                    self.index();
                },
                'M' => self.reverseIndex(),
                'c' => self.reset(),
                else => {},
            }
        },
        .csi => |command| {
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
            self.damage_rows[at / self.columns] = true;
            if (new_width == 2 and at % self.columns == self.columns - 1) {
                self.clearCluster(at);
                if (self.autowrap and self.columns > 1) {
                    self.soft_wrapped[self.cursor.row] = true;
                    self.cursor.column = 0;
                    self.index();
                    target = self.cursor.row * self.columns;
                } else {
                    self.allocator.free(joined);
                    cell = .{ .codepoint = 0xfffd, .style = cell.style };
                }
            }
            const old_width = cell.width;
            cell.width = if (new_width == 2 and target % self.columns + 1 >= self.columns) 1 else new_width;
            if (target != at) self.clearCluster(target);
            if (cell.width == 2) {
                self.clearCluster(target + 1);
                self.cells[target + 1] = .{ .codepoint = 0, .width = 0, .style = cell.style };
            } else if (old_width == 2 and target + 1 < self.cells.len) self.clearCell(target + 1);
            self.cells[target] = cell;
            self.last_print = target;
            if (Unicode.isFormat(cp)) {
                self.damage_rows[target / self.columns] = true;
                return;
            }
            self.cursor.row = target / self.columns;
            self.advance(target % self.columns, cell.width);
            self.damage_rows[self.cursor.row] = true;
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
    if (self.wrap_pending or (width == 2 and self.cursor.column == self.columns - 1 and self.autowrap and self.columns > 1)) {
        self.soft_wrapped[self.cursor.row] = true;
        self.cursor.column = 0;
        self.index();
    }
    const at = self.cursor.row * self.columns + self.cursor.column;
    const actual: u2 = if (width == 2 and self.cursor.column + 1 < self.columns) 2 else 1;
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
    self.damage_rows[self.cursor.row] = true;
    self.advance(at % self.columns, actual);
}
fn advance(self: *Screen, column: usize, width: u2) void {
    const next = column + width;
    self.cursor.column = @min(next, self.columns - 1);
    self.wrap_pending = next >= self.columns and self.autowrap;
}

fn execute(self: *Screen, control: u8) void {
    switch (control) {
        0x08 => {
            self.cursor.column -|= 1;
            self.wrap_pending = false;
        },
        0x09 => {
            const distance = @min(8 - self.cursor.column % 8, self.columns - 1 - self.cursor.column);
            self.cursor.column += distance;
            self.wrap_pending = false;
        },
        0x0a, 0x0b, 0x0c => {
            self.soft_wrapped[self.cursor.row] = false;
            self.index();
        },
        0x0d => {
            self.cursor.column = 0;
            self.wrap_pending = false;
        },
        else => {},
    }
}

fn index(self: *Screen) void {
    self.wrap_pending = false;
    if (self.cursor.row == self.scroll_bottom - 1) {
        self.scrollUp(self.scroll_top, self.scroll_bottom, 1);
    } else if (self.cursor.row < self.rows - 1) {
        self.cursor.row += 1;
    }
}

fn reverseIndex(self: *Screen) void {
    self.wrap_pending = false;
    if (self.cursor.row == self.scroll_top) {
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
    };
}

fn restore(self: *Screen) void {
    self.style = self.saved.style;
    self.origin_mode = self.saved.origin_mode;
    self.autowrap = self.saved.autowrap;
    const top = if (self.origin_mode) self.scroll_top else 0;
    const bottom = if (self.origin_mode) self.scroll_bottom else self.rows;
    self.cursor.row = std.math.clamp(self.saved.row, top, bottom - 1);
    self.cursor.column = self.saved.column;
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
    if (command.intermediates.len != 0) return;
    const p = command.parameters;
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
            self.cursor.column += @min(n, self.columns - 1 - self.cursor.column);
            self.wrap_pending = false;
        },
        'D' => {
            self.cursor.column -|= n;
            self.wrap_pending = false;
        },
        'E' => {
            self.moveDown(n);
            self.cursor.column = 0;
        },
        'F' => {
            self.moveUp(n);
            self.cursor.column = 0;
        },
        'G' => {
            self.cursor.column = @min(n, self.columns) - 1;
            self.wrap_pending = false;
        },
        'H', 'f' => self.position(n, countParameter(p, 1)),
        'd' => self.position(n, self.cursor.column + 1),
        's' => self.save(),
        'u' => self.restore(),
        'J' => self.eraseDisplay(parameter(p, 0, 0)),
        'K' => self.eraseLine(parameter(p, 0, 0)),
        'X' => {
            const start = self.cursor.row * self.columns + self.cursor.column;
            self.blank(start, start + @min(n, self.columns - self.cursor.column));
            self.wrap_pending = false;
        },
        '@' => self.insertCharacters(n),
        'P' => self.deleteCharacters(n),
        'L', 'M' => {
            if (self.cursor.row < self.scroll_top or self.cursor.row >= self.scroll_bottom) return;
            if (command.final == 'L') {
                self.scrollDown(self.cursor.row, self.scroll_bottom, n);
            } else {
                self.scrollUp(self.cursor.row, self.scroll_bottom, n);
            }
            self.cursor.column = 0;
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
    self.cursor.column = @min(column, self.columns) - 1;
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
    @memset(self.damage_rows[start / self.columns .. (end - 1) / self.columns + 1], true);
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
    const n = @min(count, self.columns - self.cursor.column);
    const start = self.cursor.row * self.columns + self.cursor.column;
    const end = (self.cursor.row + 1) * self.columns;
    if (self.cells[start].width == 0) self.clearCluster(start);
    if (end - n > start and self.cells[end - n].width == 0) self.clearCluster(end - n);
    for (end - n..end) |at| self.clearCell(at);
    std.mem.copyBackwards(Cell, self.cells[start + n .. end], self.cells[start .. end - n]);
    @memset(self.cells[start .. start + n], .{ .style = self.style });
    self.damage_rows[self.cursor.row] = true;
    self.wrap_pending = false;
}

fn deleteCharacters(self: *Screen, count: usize) void {
    const n = @min(count, self.columns - self.cursor.column);
    const start = self.cursor.row * self.columns + self.cursor.column;
    const end = (self.cursor.row + 1) * self.columns;
    if (self.cells[start].width == 0) self.clearCluster(start);
    if (start + n < end and self.cells[start + n].width == 0) self.clearCluster(start + n);
    for (start..start + n) |at| self.clearCell(at);
    std.mem.copyForwards(Cell, self.cells[start .. end - n], self.cells[start + n .. end]);
    @memset(self.cells[end - n .. end], .{ .style = self.style });
    self.damage_rows[self.cursor.row] = true;
    self.wrap_pending = false;
}

fn scrollUp(self: *Screen, top: usize, bottom: usize, count: usize) void {
    const start = top * self.columns;
    const end = bottom * self.columns;
    const distance = @min(count, bottom - top) * self.columns;
    for (start..start + distance) |at| self.clearCell(at);
    std.mem.copyForwards(Cell, self.cells[start .. end - distance], self.cells[start + distance .. end]);
    const lines = distance / self.columns;
    std.mem.copyForwards(bool, self.soft_wrapped[top .. bottom - lines], self.soft_wrapped[top + lines .. bottom]);
    @memset(self.soft_wrapped[bottom - lines .. bottom], false);
    @memset(self.damage_rows[top..bottom], true);
    @memset(self.cells[end - distance .. end], .{ .style = self.style });
}

fn scrollDown(self: *Screen, top: usize, bottom: usize, count: usize) void {
    const start = top * self.columns;
    const end = bottom * self.columns;
    const distance = @min(count, bottom - top) * self.columns;
    for (end - distance..end) |at| self.clearCell(at);
    std.mem.copyBackwards(Cell, self.cells[start + distance .. end], self.cells[start .. end - distance]);
    const lines = distance / self.columns;
    std.mem.copyBackwards(bool, self.soft_wrapped[top + lines .. bottom], self.soft_wrapped[top .. bottom - lines]);
    @memset(self.soft_wrapped[top .. top + lines], false);
    @memset(self.damage_rows[top..bottom], true);
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
