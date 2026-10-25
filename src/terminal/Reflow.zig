//! Transactional main-screen reflow. Work and retained storage are bounded.
const std = @import("std");
const Screen = @import("Screen.zig");
const History = @import("History.zig");
const Unicode = @import("Unicode.zig");
pub const Position = struct { row: u64, column: usize };
pub const Result = struct { screen: Screen, history: History, positions: [5]Position };

pub fn prepare(main: *const Screen, history: *const History, rows: usize, columns: usize, anchors: [5]Position) !Result {
    var screen = try main.resized(rows, columns);
    errdefer screen.deinit();
    screen.history = null;
    // Raster placements retain existing clipping semantics; only text is reflowed.
    for (0..rows) |row| try screen.copyRow(row, &.{}, false);
    var live_bytes: usize = 0;
    for (main.cells) |cell| {
        live_bytes += @sizeOf(Screen.Cell) + cell.grapheme.len * @sizeOf(u21);
        if (cell.link) |link| live_bytes += link.uri.len + link.id.len;
    }
    var output: History = .{ .allocator = main.allocator, .max_rows = history.max_rows + rows, .max_bytes = history.max_bytes + live_bytes + rows * columns * (@sizeOf(Screen.Cell) + 16) };
    defer output.deinit();
    var cells = try main.allocator.alloc(Screen.Cell, columns);
    @memset(cells, .{});
    defer History.freeCells(main.allocator, cells);
    var column: usize = 0;
    var mapped = anchors;
    var found: [5]bool = @splat(false);
    var last = main.cursor.row;
    for (anchors[0..4]) |anchor| {
        if (anchor.row >= history.next_id and anchor.row - history.next_id < main.rows) last = @max(last, @as(usize, @intCast(anchor.row - history.next_id)));
    }
    for (0..main.rows) |row| for (main.getRow(row).?) |cell| {
        if (cell.codepoint != ' ' or cell.grapheme.len != 0 or cell.link != null or !std.meta.eql(cell.style, Screen.Style{})) last = @max(last, row);
    };
    for (0..history.count() + last + 1) |source| {
        const old = if (source < history.count()) history.get(source).? else History.Row{ .cells = main.cells[(source - history.count()) * main.columns ..][0..if (main.soft_wrapped[source - history.count()]) main.wrap_columns[source - history.count()] else main.columns], .wrapped = main.soft_wrapped[source - history.count()], .id = history.next_id + source - history.count(), .bytes = 0 };
        var length = old.cells.len;
        if (!old.wrapped) {
            while (length > 0) : (length -= 1) {
                const cell = old.cells[length - 1];
                if (cell.codepoint != ' ' or cell.grapheme.len != 0 or cell.link != null or !std.meta.eql(cell.style, Screen.Style{})) break;
            }
        }
        for (anchors) |anchor| if (anchor.row == old.id) {
            length = @min(old.cells.len, @max(length, anchor.column));
        };
        var col: usize = 0;
        while (col <= length) {
            const source_width: usize = if (col < length) @max(1, old.cells[col].width) else 0;
            const width: usize = if (col < length and old.cells[col].codepoint == 0xfffd and old.cells[col].grapheme.len > 0) Unicode.width(old.cells[col].grapheme) else source_width;
            if (col < length and (column == columns or (width == 2 and column + 1 == columns and columns > 1))) {
                try output.push(cells[0..column], true);
                for (cells) |*cell| {
                    main.allocator.free(cell.grapheme);
                    if (cell.link) |link| link.release();
                    cell.* = .{};
                }
                column = 0;
            }
            for (anchors, 0..) |anchor, i| if (!found[i] and anchor.row == old.id and anchor.column <= col) {
                mapped[i] = .{ .row = output.next_id, .column = column };
                found[i] = true;
            };
            if (col == length) break;
            if (old.cells[col].width == 0) {
                col += 1;
                continue;
            }
            cells[column] = try History.cloneCell(main.allocator, old.cells[col]);
            cells[column].width = @intCast(width);
            if (width > source_width and cells[column].grapheme.len > 0) cells[column].codepoint = cells[column].grapheme[0];
            const actual = @min(width, columns);
            if (width == 2 and columns == 1) {
                if (cells[column].grapheme.len == 0) cells[column].grapheme = try main.allocator.dupe(u21, &.{cells[column].codepoint});
                cells[column].codepoint = 0xfffd;
                cells[column].width = 1;
            }
            if (actual == 2) cells[column + 1] = .{ .codepoint = 0, .width = 0, .style = cells[column].style, .link = if (cells[column].link) |link| link.retain() else null };
            column += actual;
            col += source_width;
        }
        if (!old.wrapped) {
            try output.push(cells, false);
            for (cells) |*cell| {
                main.allocator.free(cell.grapheme);
                if (cell.link) |link| link.release();
                cell.* = .{};
            }
            column = 0;
        }
    }
    if (column > 0) try output.push(cells, false);
    var retained: History = .{ .allocator = main.allocator, .max_rows = history.max_rows, .max_bytes = history.max_bytes };
    errdefer retained.deinit();
    const tail = @min(rows, output.count());
    const split = output.count() - tail;
    retained.next_id = if (output.count() > 0) output.get(0).?.id else 0;
    for (0..split) |i| {
        const row = output.get(i).?;
        try retained.push(row.cells, row.wrapped);
    }
    for (0..tail) |i| {
        const row = output.get(split + i).?;
        try screen.copyRow(i, row.cells, row.wrapped);
    }
    const cursor = mapped[0];
    screen.cursor.row = @intCast(@min(rows - 1, cursor.row -| retained.next_id));
    screen.cursor.column = @min(columns - 1, cursor.column);
    screen.wrap_pending = cursor.column >= columns;
    screen.saved.row = @intCast(@min(rows - 1, mapped[1].row -| retained.next_id));
    screen.saved.column = @min(columns - 1, mapped[1].column);
    return .{ .screen = screen, .history = retained, .positions = mapped };
}
