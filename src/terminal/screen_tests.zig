//! Screen behavior exercised through the public parser/event boundary.
const std = @import("std");
const t = std.testing;
const vt = @import("root.zig");

fn feed(screen: *vt.Screen, bytes: []const u8) void {
    var parser = vt.Parser.init();
    parser.feed(bytes, screen);
    finish(&parser, screen);
}

fn finish(parser: *vt.Parser, screen: *vt.Screen) void {
    for (parser.finish()) |event| if (event) |value| screen.handle(value);
}

fn expectRows(screen: *const vt.Screen, expected: []const []const u8) !void {
    try t.expectEqual(expected.len, screen.rows);
    for (expected, 0..) |text, r| {
        const row = screen.getRow(r).?;
        try t.expectEqual(text.len, row.len);
        for (text, row) |byte, cell| try t.expectEqual(@as(u21, byte), cell.codepoint);
    }
}

fn expectCursor(screen: *const vt.Screen, row: usize, column: usize) !void {
    const cursor = screen.getCursor();
    try t.expectEqual(row, cursor.row);
    try t.expectEqual(column, cursor.column);
}

test "screen owns a blank fixed grid and checks dimensions and access bounds" {
    var screen = try vt.Screen.init(t.allocator, 2, 3);
    defer screen.deinit();
    try expectRows(&screen, &.{ "   ", "   " });
    try expectCursor(&screen, 0, 0);
    try t.expect(screen.getCursor().visible);
    try t.expectEqualDeep(vt.Cell{}, screen.getCell(1, 2).?);
    try t.expectEqual(@as(?vt.Cell, null), screen.getCell(2, 0));
    try t.expectEqual(@as(?vt.Cell, null), screen.getCell(0, 3));
    try t.expect(screen.getRow(2) == null);
    try t.expectError(error.InvalidDimensions, vt.Screen.init(t.allocator, 0, 1));
    try t.expectError(error.InvalidDimensions, vt.Screen.init(t.allocator, 1, 0));
    try t.expectError(error.InvalidDimensions, vt.Screen.init(t.allocator, std.math.maxInt(usize), 2));
    try t.expectError(error.InvalidDimensions, vt.Screen.init(t.allocator, 1, std.math.maxInt(usize)));
}

test "allocation failure is clean and events do not allocate" {
    var allocator = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, vt.Screen.init(allocator.allocator(), 2, 4));
    allocator = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 1 });
    {
        var screen = try vt.Screen.init(allocator.allocator(), 2, 4);
        defer screen.deinit();
        feed(&screen, "\x1b[38;2;1;2;3mhello\r\nworld\x1b[2S\x1b[2T\x1b[2J\x1b[c");
        screen.reset();
        try t.expectEqual(@as(usize, 1), allocator.alloc_index);
        try t.expect(!allocator.has_induced_failure);
    }
    try t.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "print overwrites cells and delays wrap until the next printable scalar" {
    var screen = try vt.Screen.init(t.allocator, 2, 3);
    defer screen.deinit();
    feed(&screen, "abc");
    try expectRows(&screen, &.{ "abc", "   " });
    try expectCursor(&screen, 0, 2);
    feed(&screen, "\x1b[31mD");
    try expectRows(&screen, &.{ "abc", "D  " });
    try t.expectEqualDeep(vt.Color{ .indexed = 1 }, screen.getCell(1, 0).?.style.foreground);
    feed(&screen, "\rX\x1b[1;2HY");
    try expectRows(&screen, &.{ "aYc", "X  " });
    feed(&screen, "\x1b[2;3HZ\x1b[1D!");
    try expectRows(&screen, &.{ "aYc", "X!Z" });
}

test "controls preserve LF column and tabs use eight-column stops without erasing" {
    var screen = try vt.Screen.init(t.allocator, 4, 12);
    defer screen.deinit();
    feed(&screen, "ab\nC\rD\tE\tF");
    try expectRows(&screen, &.{ "ab          ", "D C     E  F", "            ", "            " });
    feed(&screen, "\x08!\r\x08Z\x0bV\x0cW");
    try expectRows(&screen, &.{ "ab          ", "Z C     E !F", " V          ", "  W         " });
    try expectCursor(&screen, 3, 3);
}

test "each Unicode scalar occupies exactly one cell and EOF replaces incomplete UTF-8" {
    var screen = try vt.Screen.init(t.allocator, 1, 6);
    defer screen.deinit();
    feed(&screen, "λ水🚀\u{0301}\xf0\x9f");
    const expected = [_]u21{ 'λ', '水', 0x1f680, 0x0301, 0xfffd, ' ' };
    for (screen.getRow(0).?, expected) |cell, scalar| try t.expectEqual(scalar, cell.codepoint);
}

test "cursor commands default zero to one and clamp large movement" {
    var screen = try vt.Screen.init(t.allocator, 4, 5);
    defer screen.deinit();
    const cases = [_]struct { bytes: []const u8, row: usize, column: usize }{
        .{ .bytes = "\x1b[999;999H", .row = 3, .column = 4 },
        .{ .bytes = "\x1b[0A\x1b[D", .row = 2, .column = 3 },
        .{ .bytes = "\x1b[2F", .row = 0, .column = 0 },
        .{ .bytes = "\x1b[2E", .row = 2, .column = 0 },
        .{ .bytes = "\x1b[65535C\x1b[65535B", .row = 3, .column = 4 },
        .{ .bytes = "\x1b[0G\x1b[0d", .row = 0, .column = 0 },
        .{ .bytes = "\x1b[3;4f", .row = 2, .column = 3 },
        .{ .bytes = "\x1b[1d", .row = 0, .column = 3 },
        .{ .bytes = "\x1b[65535D\x1b[65535A", .row = 0, .column = 0 },
        .{ .bytes = "\x1b[;H", .row = 0, .column = 0 },
    };
    for (cases) |case| {
        feed(&screen, case.bytes);
        try expectCursor(&screen, case.row, case.column);
    }
}

test "autowrap can be disabled and cursor visibility changes do not cancel pending wrap" {
    var screen = try vt.Screen.init(t.allocator, 2, 3);
    defer screen.deinit();
    feed(&screen, "\x1b[?7lABCDE");
    try expectRows(&screen, &.{ "ABE", "   " });
    feed(&screen, "\x1b[?7hF\x1b[?25lG");
    try expectRows(&screen, &.{ "ABF", "G  " });
    try t.expect(!screen.getCursor().visible);
    feed(&screen, "\x1b[?25h");
    try t.expect(screen.getCursor().visible);
}

test "both save restore forms retain attributes origin mode and pending wrap" {
    for ([_][2][]const u8{ .{ "\x1b7", "\x1b8" }, .{ "\x1b[s", "\x1b[u" } }) |commands| {
        var screen = try vt.Screen.init(t.allocator, 4, 3);
        defer screen.deinit();
        feed(&screen, "\x1b[2;4r\x1b[?6h\x1b[31mabc");
        feed(&screen, commands[0]);
        feed(&screen, "\x1b[?6l\x1b[?7l\x1b[?25l\x1b[0m\x1b[HX");
        feed(&screen, commands[1]);
        try expectCursor(&screen, 1, 2);
        try t.expect(!screen.getCursor().visible);
        feed(&screen, "Y\x1b[1;2HZ");
        try expectRows(&screen, &.{ "X  ", "aZc", "Y  ", "   " });
        try t.expectEqualDeep(vt.Color{ .indexed = 1 }, screen.getCell(2, 0).?.style.foreground);
    }
}

test "16-color SGR maps normal bright foreground and background independently" {
    var screen = try vt.Screen.init(t.allocator, 1, 16);
    defer screen.deinit();
    var buffer: [40]u8 = undefined;
    for (0..16) |index| {
        const fg = if (index < 8) 30 + index else 90 + index - 8;
        const bg = if (index < 8) 40 + index else 100 + index - 8;
        const bytes = try std.fmt.bufPrint(&buffer, "\x1b[{d};{d}mX", .{ fg, bg });
        feed(&screen, bytes);
        const style = screen.getCell(0, index).?.style;
        try t.expectEqualDeep(vt.Color{ .indexed = @intCast(index) }, style.foreground);
        try t.expectEqualDeep(vt.Color{ .indexed = @intCast(index) }, style.background);
    }
}

test "indexed and RGB colors accept semicolons and colon subparameters" {
    const cases = [_]struct { bytes: []const u8, foreground: vt.Color, background: vt.Color }{
        .{ .bytes = "\x1b[38;5;255;48;5;0mX", .foreground = .{ .indexed = 255 }, .background = .{ .indexed = 0 } },
        .{ .bytes = "\x1b[38:5:23;48:5:200mX", .foreground = .{ .indexed = 23 }, .background = .{ .indexed = 200 } },
        .{ .bytes = "\x1b[38;2;0;128;255;48;2;3;4;5mX", .foreground = .{ .rgb = .{ .r = 0, .g = 128, .b = 255 } }, .background = .{ .rgb = .{ .r = 3, .g = 4, .b = 5 } } },
        .{ .bytes = "\x1b[38:2:1:2:3;48:2::4:5:6mX", .foreground = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .background = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } } },
        .{ .bytes = "\x1b[38:2:0:7:8:9mX", .foreground = .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } }, .background = .default },
    };
    for (cases) |case| {
        var screen = try vt.Screen.init(t.allocator, 1, 1);
        defer screen.deinit();
        feed(&screen, case.bytes);
        const style = screen.getCell(0, 0).?.style;
        try t.expectEqualDeep(case.foreground, style.foreground);
        try t.expectEqualDeep(case.background, style.background);
    }
}

test "malformed color groups cannot accidentally set other attributes" {
    for ([_][]const u8{
        "38;2;1;5",       "38;2;;5;7",    "38;2;256;5;7",  "38;5;999", "38;5;",
        "38:2:1:5",       "38:2:1:2:5:7", "38:2::1:5:999", "38:5:",    "38:5:256",
        "38:2:1:2:3:4:5", "38;2:1;5;7",   "38;99;1;5;7",   "38",       "48;2;1;5",
    }) |parameters| {
        var screen = try vt.Screen.init(t.allocator, 1, 1);
        defer screen.deinit();
        feed(&screen, "\x1b[31;44m");
        var buffer: [100]u8 = undefined;
        feed(&screen, try std.fmt.bufPrint(&buffer, "\x1b[{s}mX", .{parameters}));
        const expected: vt.Style = .{ .foreground = .{ .indexed = 1 }, .background = .{ .indexed = 4 } };
        try t.expectEqualDeep(expected, screen.getCell(0, 0).?.style);
    }
    var screen = try vt.Screen.init(t.allocator, 1, 2);
    defer screen.deinit();
    feed(&screen, "\x1b[38;2;999;5;7;4mX\x1b[4:3;1mY");
    try t.expect(screen.getCell(0, 0).?.style.underline);
    try t.expect(screen.getCell(0, 1).?.style.bold);
    // The unsupported underline subgroup is ignored as a group.
    try t.expect(!screen.getCell(0, 1).?.style.italic);
}

test "SGR attributes and selective full omitted resets only affect subsequent cells" {
    var screen = try vt.Screen.init(t.allocator, 1, 6);
    defer screen.deinit();
    feed(&screen, "\x1b[31;44;1;2;3;4;5;7;8;9mA" ++
        "\x1b[22;23;24;25;27;28;29mB\x1b[39mC\x1b[49mD" ++
        "\x1b[6;91;101m\x1b[0mE\x1b[1;31m\x1b[mF");
    const all: vt.Style = .{
        .foreground = .{ .indexed = 1 },
        .background = .{ .indexed = 4 },
        .bold = true,
        .faint = true,
        .italic = true,
        .underline = true,
        .blink = true,
        .inverse = true,
        .hidden = true,
        .strikethrough = true,
    };
    try t.expectEqualDeep(all, screen.getCell(0, 0).?.style);
    try t.expectEqualDeep(vt.Style{ .foreground = .{ .indexed = 1 }, .background = .{ .indexed = 4 } }, screen.getCell(0, 1).?.style);
    try t.expectEqualDeep(vt.Style{ .background = .{ .indexed = 4 } }, screen.getCell(0, 2).?.style);
    for (3..6) |column| try t.expectEqualDeep(vt.Style{}, screen.getCell(0, column).?.style);
}

test "display and line erase include the cursor and preserve cursor position" {
    const cases = [_]struct { command: []const u8, expected: [2][]const u8 }{
        .{ .command = "J", .expected = .{ "a  ", "   " } },
        .{ .command = "1J", .expected = .{ "  c", "def" } },
        .{ .command = "2J", .expected = .{ "   ", "   " } },
        .{ .command = "K", .expected = .{ "a  ", "def" } },
        .{ .command = "1K", .expected = .{ "  c", "def" } },
        .{ .command = "2K", .expected = .{ "   ", "def" } },
    };
    for (cases) |case| {
        var screen = try vt.Screen.init(t.allocator, 2, 3);
        defer screen.deinit();
        feed(&screen, "abc\r\ndef\x1b[1;2H\x1b[42m");
        var buffer: [20]u8 = undefined;
        feed(&screen, try std.fmt.bufPrint(&buffer, "\x1b[{s}", .{case.command}));
        try expectRows(&screen, &case.expected);
        try expectCursor(&screen, 0, 1);
        try t.expectEqualDeep(vt.Color{ .indexed = 2 }, screen.getCell(0, 1).?.style.background);
    }
}

test "character insertion deletion and erasure move styles and clamp at row end" {
    var screen = try vt.Screen.init(t.allocator, 2, 6);
    defer screen.deinit();
    feed(&screen, "ab\x1b[31mcd\x1b[0mef\r\nKEEP!!\x1b[1;2H\x1b[44m\x1b[2@");
    try expectRows(&screen, &.{ "a  bcd", "KEEP!!" });
    try t.expectEqualDeep(vt.Color{ .indexed = 1 }, screen.getCell(0, 4).?.style.foreground);
    try t.expectEqualDeep(vt.Color{ .indexed = 4 }, screen.getCell(0, 1).?.style.background);
    feed(&screen, "\x1b[3P");
    try expectRows(&screen, &.{ "acd   ", "KEEP!!" });
    try t.expectEqualDeep(vt.Color{ .indexed = 1 }, screen.getCell(0, 1).?.style.foreground);
    feed(&screen, "\x1b[999X");
    try expectRows(&screen, &.{ "a     ", "KEEP!!" });
    try expectCursor(&screen, 0, 1);
    feed(&screen, "\x1b[999@\x1b[999P");
    try expectRows(&screen, &.{ "a     ", "KEEP!!" });
}

test "LF autowrap and indexing scroll only at the bottom and fill with active style" {
    var screen = try vt.Screen.init(t.allocator, 2, 3);
    defer screen.deinit();
    feed(&screen, "\x1b[31mabc\r\n\x1b[32mdef");
    try expectRows(&screen, &.{ "abc", "def" });
    feed(&screen, "\x1b[44mG");
    try expectRows(&screen, &.{ "def", "G  " });
    try t.expectEqualDeep(vt.Color{ .indexed = 2 }, screen.getCell(0, 0).?.style.foreground);
    try t.expectEqualDeep(vt.Color{ .indexed = 4 }, screen.getCell(1, 2).?.style.background);
    feed(&screen, "\x1bD");
    try expectRows(&screen, &.{ "G  ", "   " });
    try expectCursor(&screen, 1, 1);
    feed(&screen, "Z\x1bE");
    try expectRows(&screen, &.{ " Z ", "   " });
    try expectCursor(&screen, 1, 0);
}

test "explicit scrolling and reverse index respect margins and preserve outside rows" {
    var screen = try vt.Screen.init(t.allocator, 4, 3);
    defer screen.deinit();
    feed(&screen, "AAA\r\nBBB\r\nCCC\r\nDDD\x1b[2;3r\x1b[S");
    try expectRows(&screen, &.{ "AAA", "CCC", "   ", "DDD" });
    try expectCursor(&screen, 0, 0);
    feed(&screen, "\x1b[T");
    try expectRows(&screen, &.{ "AAA", "   ", "CCC", "DDD" });
    feed(&screen, "\x1b[2;2HX\x1bM");
    try expectRows(&screen, &.{ "AAA", "   ", " X ", "DDD" });
    try expectCursor(&screen, 1, 2);
    feed(&screen, "\x1b[999S\x1b[999T");
    try expectRows(&screen, &.{ "AAA", "   ", "   ", "DDD" });
    feed(&screen, "\x1b[4;1H\n\x1bM");
    try expectCursor(&screen, 2, 0);
    try expectRows(&screen, &.{ "AAA", "   ", "   ", "DDD" });
}

test "origin mode and relative moves use margins while absolute positions can leave them" {
    var screen = try vt.Screen.init(t.allocator, 5, 4);
    defer screen.deinit();
    feed(&screen, "\x1b[2;4r");
    try expectCursor(&screen, 0, 0);
    feed(&screen, "\x1b[?6h");
    try expectCursor(&screen, 1, 0);
    feed(&screen, "\x1b[999;999H");
    try expectCursor(&screen, 3, 3);
    feed(&screen, "\x1b[999A");
    try expectCursor(&screen, 1, 3);
    feed(&screen, "\x1b[2d");
    try expectCursor(&screen, 2, 3);
    feed(&screen, "\x1b[?6l\x1b[5;1H\x1b[999B");
    try expectCursor(&screen, 4, 0);
    feed(&screen, "\x1b[999A\x1b[999B");
    try expectCursor(&screen, 3, 0);
    feed(&screen, "\x1b[H\x1b[999A");
    try expectCursor(&screen, 0, 0);
    feed(&screen, "\x1b[r\x1b[999B");
    try expectCursor(&screen, 4, 0);
}

test "invalid margins do not move cursor or change the active region" {
    var screen = try vt.Screen.init(t.allocator, 4, 3);
    defer screen.deinit();
    feed(&screen, "AAA\r\nBBB\r\nCCC\r\nDDD\x1b[2;3r\x1b[2;2H");
    feed(&screen, "\x1b[3;2r\x1b[2;2r\x1b[1;999r\x1b[999;0r");
    try expectCursor(&screen, 1, 1);
    feed(&screen, "\x1b[S");
    try expectRows(&screen, &.{ "AAA", "CCC", "   ", "DDD" });
}

test "line insertion and deletion stay inside margins and are ignored outside" {
    var screen = try vt.Screen.init(t.allocator, 5, 3);
    defer screen.deinit();
    feed(&screen, "AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE\x1b[2;4r\x1b[3;2H\x1b[L");
    try expectRows(&screen, &.{ "AAA", "BBB", "   ", "CCC", "EEE" });
    try expectCursor(&screen, 2, 0);
    feed(&screen, "\x1b[M");
    try expectRows(&screen, &.{ "AAA", "BBB", "CCC", "   ", "EEE" });
    feed(&screen, "\x1b[H\x1b[99L\x1b[99M");
    try expectRows(&screen, &.{ "AAA", "BBB", "CCC", "   ", "EEE" });
    feed(&screen, "\x1b[2;2H\x1b[999M");
    try expectRows(&screen, &.{ "AAA", "   ", "   ", "   ", "EEE" });
}

test "single-cell screens safely wrap scroll edit and reset" {
    var screen = try vt.Screen.init(t.allocator, 1, 1);
    defer screen.deinit();
    feed(&screen, "AB\t\x08\x1b[999A\x1b[999B\x1b[999C\x1b[999D\x1b[r");
    try expectRows(&screen, &.{"B"});
    feed(&screen, "\x1b[999@\x1b[999P\x1b[999X\x1b[999L\x1b[999M\x1bM\x1bD\x1b[999S\x1b[999T");
    try expectRows(&screen, &.{" "});
    try expectCursor(&screen, 0, 0);
}

test "screen reset restores cells modes margins attributes and saved state" {
    var screen = try vt.Screen.init(t.allocator, 3, 2);
    defer screen.deinit();
    for (0..2) |method| {
        feed(&screen, "\x1b[2;3r\x1b[?6h\x1b[?7l\x1b[?25l\x1b[31;44;1mAB\x1b7");
        if (method == 0) screen.reset() else feed(&screen, "\x1bc");
        feed(&screen, "\x1b8");
        try expectRows(&screen, &.{ "  ", "  ", "  " });
        try expectCursor(&screen, 0, 0);
        try t.expect(screen.getCursor().visible);
        feed(&screen, "ABC");
        try expectRows(&screen, &.{ "AB", "C ", "  " });
        try t.expectEqualDeep(vt.Style{}, screen.getCell(0, 0).?.style);
    }
}

test "unsupported private intermediate subparameter and string commands leave state alone" {
    var screen = try vt.Screen.init(t.allocator, 2, 3);
    defer screen.deinit();
    feed(&screen, "abc\x1b[?1049h\x1b[?2J\x1b[>31m\x1b[1 A\x1b[1:2H\x1b[?6:1h" ++
        "\x1b[999m\x1b[3J\x1b[3K\x1b[6n\x1b#8\x07\x00" ++
        "\x1b]0;title\x07\x1bPqhidden\x1b\\\x1b_Ghidden\x1b\\D");
    try expectRows(&screen, &.{ "abc", "D  " });
    try t.expectEqualDeep(vt.Style{}, screen.getCell(1, 0).?.style);
}

test "screen state is invariant at every input split including UTF-8 and strings" {
    const input = "\x1b[31;44;1mλ水🚀AB\r\ncd\x1b[2;3r\x1b[?6h" ++
        "\x1b[2;2H\x1b7\x1b[38:2::1:2:3mX\x1b[2S\x1bM\x1b8" ++
        "\x1b[2@\x1b[P\x1b[K\x1b[?25l\x1b]0;hidden\x07\x1bPqhidden\x1b\\\xf0\x9f";
    var expected = try vt.Screen.init(t.allocator, 4, 5);
    defer expected.deinit();
    feed(&expected, input);
    for (0..input.len + 1) |split| {
        var actual = try vt.Screen.init(t.allocator, 4, 5);
        defer actual.deinit();
        var parser = vt.Parser.init();
        parser.feed(input[0..split], &actual);
        parser.feed("", &actual);
        parser.feed(input[split..], &actual);
        finish(&parser, &actual);
        try t.expectEqualDeep(expected.cells, actual.cells);
        try t.expectEqualDeep(expected.getCursor(), actual.getCursor());
        try t.expectEqualDeep(expected.style, actual.style);
        try t.expectEqualDeep(expected.saved, actual.saved);
        try t.expectEqual(expected.origin_mode, actual.origin_mode);
        try t.expectEqual(expected.autowrap, actual.autowrap);
        try t.expectEqual(expected.wrap_pending, actual.wrap_pending);
        try t.expectEqual(expected.scroll_top, actual.scroll_top);
        try t.expectEqual(expected.scroll_bottom, actual.scroll_bottom);
    }
}

test "arbitrary byte streams keep cursor and scroll bounds valid" {
    var screen = try vt.Screen.init(t.allocator, 3, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    var state: u32 = 0x61bc239d;
    for (0..10000) |i| {
        state = state *% 1664525 +% 1013904223;
        const byte: u8 = @truncate(state >> 24);
        parser.feed(&.{byte}, &screen);
        if (i % 97 == 0) parser.feed("\x1b[?6h\x1b[65535;65535H\x1b[999L\x1b[999P", &screen);
        try t.expect(screen.getCursor().row < screen.rows);
        try t.expect(screen.getCursor().column < screen.columns);
        try t.expect(screen.scroll_top < screen.scroll_bottom);
        try t.expect(screen.scroll_bottom <= screen.rows);
    }
    finish(&parser, &screen);
}
