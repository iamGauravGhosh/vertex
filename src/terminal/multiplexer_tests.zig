const std = @import("std");
const t = std.testing;
const vt = @import("root.zig");

fn feed(session: *vt.Session, parser: *vt.Parser, bytes: []const u8) !void {
    parser.feed(bytes, session);
    if (session.takeError()) |err| return err;
}
fn row(screen: *const vt.Screen, index: usize, expected: []const u21) !void {
    try t.expectEqual(screen.columns, expected.len);
    for (expected, screen.getRow(index).?) |cp, cell| try t.expectEqual(cp, cell.codepoint);
}

test "synchronized presentation expires without output and repeated begins cannot freeze it" {
    var session = try vt.Session.init(t.allocator, 2, 8);
    defer session.deinit();
    var parser = vt.Parser.init();
    _ = session.presentationHeld(1000);
    try feed(&session, &parser, "\x1b[?2026hA\x1b[?2026$p");
    try t.expect(session.presentationHeld(1100));
    try feed(&session, &parser, "\x1b[?2026hB");
    try t.expectEqual(@as(?i64, 1150), session.sync_deadline_ms);
    try t.expect(!session.presentationHeld(1150));
    try feed(&session, &parser, "\x1b[?2026hC");
    try t.expect(!session.presentationHeld(1200));
    try t.expectEqualStrings("\x1b[?2026;1$y", session.replies.items);
    try row(&session.screen, 0, &.{ 'A', 'B', 'C', ' ', ' ', ' ', ' ', ' ' });
    try t.expect(session.screen.getDamageRows()[0]);
    try feed(&session, &parser, "\x1b[?2026l\x1b[?2026h");
    try t.expect(session.presentationHeld(1201));
    try feed(&session, &parser, "\x1bc");
    try t.expect(!session.presentationHeld(1201));
}

test "queries reply accurately in stream order including unknown modes and capabilities" {
    var session = try vt.Session.init(t.allocator, 24, 80);
    defer session.deinit();
    session.geometry = .{ .width = 800, .height = 600, .cell_width = 10, .cell_height = 25 };
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
    try feed(&session, &parser, "\x1b[?2004$p\x1b[?2004h\x1b[?2004;9999$p\x1b[>c\x1b[14t\x1b[16t\x1b[18t");
    try t.expectEqualStrings("\x1b[?2004;2$y\x1b[?2004;1$y\x1b[?9999;0$y\x1b[>0;0;0c\x1b[4;600;800t\x1b[6;25;10t\x1b[8;24;80t", session.replies.items);
    session.replies.clearRetainingCapacity();
    try feed(&session, &parser, "\x1bP+q544e;436f;524742;4e6f7065\x1b\\\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]4;1;?;255;?\x07");
    try t.expectEqualStrings("\x1bP1+r544e=787465726d2d323536636f6c6f72\x1b\\\x1bP1+r436f=323536\x1b\\\x1bP1+r524742\x1b\\\x1bP0+r4e6f7065\x1b\\\x1b]10;rgb:d8d8/dede/e9e9\x1b\\\x1b]11;rgb:1515/1717/1a1a\x1b\\\x1b]4;1;rgb:bfbf/6161/6a6a\x1b\\\x1b]4;255;rgb:eeee/eeee/eeee\x1b\\", session.replies.items);
    session.replies.clearRetainingCapacity();
    try feed(&session, &parser, "\x1b[6 q\x1bP$q q\x1b\\\x1bP$qbad\x1b\\");
    try t.expectEqualStrings("\x1bP1$r6 q\x1b\\\x1bP0$r\x1b\\", session.replies.items);
}

test "DEC graphics tab stops cursor shape and repeat remain isolated across screens" {
    var session = try vt.Session.init(t.allocator, 2, 12);
    defer session.deinit();
    var parser = vt.Parser.init();
    try feed(&session, &parser, "\x1b(0lqk\x1b(Ba\x1b[2b\x1b[3g\x1b[1;8H\x1bH\r\tX\x1b[5 q");
    try row(&session.screen, 0, &.{ 0x250c, 0x2500, 0x2510, 'a', 'a', 'a', ' ', 'X', ' ', ' ', ' ', ' ' });
    try t.expectEqual(.bar, session.screen.cursor.shape);
    try feed(&session, &parser, "\x1b[?1049h\tZ");
    try t.expectEqual(@as(u21, 'Z'), session.screen.getCell(0, 8).?.codepoint);
    try feed(&session, &parser, "\x1b[?1049l\x1b[1;12H\x1b[Z");
    try t.expectEqual(@as(usize, 7), session.screen.cursor.column);
    try session.resize(3, 14);
    try t.expect(session.screen.tab_stops[7]);
}

test "rectangular scrolling edits and origin addressing preserve adjacent panes" {
    var session = try vt.Session.init(t.allocator, 3, 8);
    defer session.deinit();
    var parser = vt.Parser.init();
    try feed(&session, &parser, "11AAAAaa\r\n22BBBBbb\r\n33CCCCcc\x1b[?69h\x1b[3;6s\x1b[S");
    try row(&session.screen, 0, &.{ '1', '1', 'B', 'B', 'B', 'B', 'a', 'a' });
    try row(&session.screen, 1, &.{ '2', '2', 'C', 'C', 'C', 'C', 'b', 'b' });
    try row(&session.screen, 2, &.{ '3', '3', ' ', ' ', ' ', ' ', 'c', 'c' });
    try feed(&session, &parser, "\x1b[T\x1b[?6h\x1b[2;2HX\x1b[2@\x1b[6n");
    try t.expectEqualStrings("\x1b[2;3R", session.replies.items);
    try row(&session.screen, 1, &.{ '2', '2', 'B', 'X', ' ', ' ', 'b', 'b' });
    try feed(&session, &parser, "\x1b[?69l\x1b[?6l");
    try t.expectEqual(@as(usize, 0), session.screen.scroll_left);
    try t.expectEqual(@as(usize, 8), session.screen.scroll_right);
}

test "wide grapheme ownership survives rectangular scrolling and boundary repairs" {
    var session = try vt.Session.init(t.allocator, 3, 8);
    defer session.deinit();
    var parser = vt.Parser.init();
    try feed(&session, &parser, "ab界é!xy\r\nab界é!xy\r\nab界é!xy\x1b[?69h\x1b[3;6s\x1b[S\x1b[T\x1b[2;3H\x1b[L\x1b[M");
    if (session.takeError()) |err| return err;
    // Move a margin through a cluster: repair both halves before moving rows.
    try feed(&session, &parser, "\x1b[4;6s\x1b[S");
    for (session.screen.cells, 0..) |cell, i| {
        if (cell.width == 0) try t.expect(i % 8 != 0 and session.screen.cells[i - 1].width == 2);
        if (cell.width == 2) try t.expect(i % 8 < 7 and session.screen.cells[i + 1].width == 0);
    }
}

test "OSC 52 streams past parser capacity and accepts only complete clipboard writes" {
    var session = try vt.Session.init(t.allocator, 2, 8);
    defer session.deinit();
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
    try feed(&session, &parser, "\x1b]52;c;");
    for (0..2048) |_| try feed(&session, &parser, "YWJj");
    try t.expect(session.takeClipboard() == null);
    try feed(&session, &parser, "\x1b\\");
    const bytes = session.takeClipboard().?;
    defer t.allocator.free(bytes);
    try t.expectEqual(@as(usize, 6144), bytes.len);
    for (0..2048) |i| try t.expectEqualStrings("abc", bytes[i * 3 ..][0..3]);
    for ([_][]const u8{ "\x1b]52;c;?\x07", "\x1b]52;c;YQ==x\x07", "\x1b]52;c;YQ=\x07", "\x1b]52;c;!!!!\x07", "\x1b]52;p;YQ==\x07", "\x1b]52;c;YQ==\x18" }) |invalid| {
        try feed(&session, &parser, invalid);
        try t.expect(session.takeClipboard() == null);
    }
    try feed(&session, &parser, "\x1b]52;c;YQ==");
    for (parser.finish()) |event| if (event) |value| session.handle(value);
    try t.expect(session.takeClipboard() == null);
    try feed(&session, &parser, "\x1b]52;;\x07");
    const empty = session.takeClipboard().?;
    defer t.allocator.free(empty);
    try t.expectEqual(@as(usize, 0), empty.len);
    try t.expectEqual(@as(usize, 0), session.replies.items.len);
}

test "row generations track deferred edits but not cursor and style changes" {
    var screen = try vt.Screen.init(t.allocator, 2, 8);
    defer screen.deinit();
    var parser = vt.Parser.init();
    const initial = screen.row_generations[0];
    parser.feed("A", &screen);
    const first = screen.row_generations[0];
    try t.expect(first != initial);
    parser.feed("B", &screen);
    try t.expect(screen.row_generations[0] != first);
    const last = screen.row_generations[0];
    parser.feed("\x1b[31m\x1b[2;1H\x1b[6 q", &screen);
    try t.expectEqual(last, screen.row_generations[0]);
    const identity = screen.identity;
    try screen.resize(3, 10);
    try t.expect(identity != screen.identity);
}

test "oversized OSC 52 and allocation failures preserve previous complete clipboard data" {
    var session = try vt.Session.init(t.allocator, 2, 8);
    defer session.deinit();
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
    try feed(&session, &parser, "\x1b]52;c;YWJj\x07\x1b]52;c;");
    // At the size boundary, one more decoded quantum must reject the whole transfer.
    try session.strings.decoded.resize(t.allocator, @import("ControlStrings.zig").max_clipboard_bytes);
    try feed(&session, &parser, "YWJj\x07");
    const previous = session.takeClipboard().?;
    defer t.allocator.free(previous);
    try t.expectEqualStrings("abc", previous);
    try t.checkAllAllocationFailures(t.allocator, clipboardAllocation, .{});
}
fn clipboardAllocation(allocator: std.mem.Allocator) !void {
    var session = try vt.Session.init(allocator, 2, 8);
    defer session.deinit();
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
    try feed(&session, &parser, "\x1b]52;c;YWJjYWJjYWJj\x07");
    const bytes = session.takeClipboard().?;
    defer allocator.free(bytes);
    try t.expectEqualStrings("abcabcabc", bytes);
}

test "horizontal-margin streams are invariant at every byte split" {
    const bytes = "\x1b[?69h\x1b[3;7s\x1b[?6h界é😀\r\n01234\r\n界é\x1b[S\x1b[T\x1b[2;2H\x1b[@\x1b[P\x1b[?6l\x1b[?69l";
    var expected = try vt.Session.init(t.allocator, 4, 10);
    defer expected.deinit();
    var parser = vt.Parser.init();
    try feed(&expected, &parser, bytes);
    for (0..bytes.len + 1) |split| {
        var session = try vt.Session.init(t.allocator, 4, 10);
        defer session.deinit();
        var chunked = vt.Parser.init();
        try feed(&session, &chunked, bytes[0..split]);
        try feed(&session, &chunked, bytes[split..]);
        for (expected.screen.cells, session.screen.cells) |a, b| try t.expectEqualDeep(a, b);
        try t.expectEqualDeep(expected.screen.cursor, session.screen.cursor);
    }
}

test "configured palette queries and bounded dynamic titles reflect session state" {
    var session = try vt.Session.init(std.testing.allocator, 2, 8);
    defer session.deinit();
    session.theme.background = 0x123456;
    session.theme.foreground = 0xabcdef;
    session.theme.normal[1] = 0xaabbcc;
    var parser = vt.Parser.init();
    parser.feed("\x1b]10;?\x07\x1b]11;?\x07\x1b]4;1;?\x07\x1b]2;editor - file.zig\x07", &session);
    try std.testing.expect(std.mem.indexOf(u8, session.replies.items, "rgb:abab/cdcd/efef") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.replies.items, "rgb:1212/3434/5656") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.replies.items, "rgb:aaaa/bbbb/cccc") != null);
    try std.testing.expect(session.title_changed);
    try std.testing.expectEqualStrings("editor - file.zig", session.title[0..session.title_len]);
    parser.feed("\x1b[5 q", &session);
    try std.testing.expect(!session.screen.cursor.configured and session.screen.cursor.blinking);
    parser.feed("\x1b[0 q", &session);
    try std.testing.expect(session.screen.cursor.configured);
}
