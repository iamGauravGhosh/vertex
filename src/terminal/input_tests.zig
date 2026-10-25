const std = @import("std");
const vt = @import("root.zig");
const t = std.testing;

test "keyboard protocols negotiate query and isolate alternate screen stacks" {
    var session = try vt.Session.init(t.allocator, 2, 10);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("main\x1b[>3u\x1b[?u\x1b[?1049h\x1b[>31u\x1b[?u", &session);
    try t.expectEqualStrings("\x1b[?3u\x1b[?31u", session.replies.items);
    try t.expectEqual(@as(u5, 31), session.getModes().kitty);
    parser.feed("\x1b[?1049l", &session);
    try t.expectEqual(@as(u5, 3), session.getModes().kitty);
    try t.expectEqual(@as(u21, 'm'), session.screen.getCell(0, 0).?.codepoint);
    parser.feed("\x1b[<u\x1b[>4;2m\x1b[?4m\x1b[?1002;1006;2004h", &session);
    try t.expectEqual(@as(u5, 0), session.getModes().kitty);
    try t.expect(session.modes.bracketed_paste and session.modes.mouse_sgr);
    try t.expectEqual(@as(u16, 1002), session.modes.mouse_tracking);
    try t.expectEqual(@as(u2, 2), session.modes.modify_other_keys);
    try t.expect(session.takeError() == null);
    try session.resize(3, 12);
    parser.feed("\x1bc", &session);
    try t.expectEqualDeep(vt.Input.Modes{}, session.getModes());
}

test "mixed DEC mode lists apply in wire order across a screen switch" {
    var session = try vt.Session.init(t.allocator, 3, 8);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[?6;1049h", &session);
    try t.expect(session.other.origin_mode);
    try t.expect(!session.screen.origin_mode);
    parser.feed("\x1b[?1049l", &session);
    try t.expect(session.screen.origin_mode);
}

test "key wire formats preserve defaults and implement progressive flags" {
    var buffer: [256]u8 = undefined;
    const encode = vt.Input.encodeKey;
    try t.expectEqualStrings("\x03", try encode(&buffer, .{ .code = 'c', .text = "c", .modifiers = .{ .control = true } }, .{}));
    try t.expectEqualStrings("\x1b[99;5:3u", try encode(&buffer, .{ .code = 'c', .modifiers = .{ .control = true }, .action = .release }, .{ .kitty = 3 }));
    try t.expectEqualStrings("\x1b[97:65:97;2:1;65u", try encode(&buffer, .{ .code = 'a', .shifted = 'A', .base = 'a', .text = "A", .modifiers = .{ .shift = true } }, .{ .kitty = 31 }));
    try t.expectEqualStrings("\x1b[27;6;65~", try encode(&buffer, .{ .code = 'a', .shifted = 'A', .modifiers = .{ .control = true, .shift = true } }, .{ .modify_other_keys = 2 }));
    try t.expectEqualStrings("\x1bOA", try encode(&buffer, .{ .code = 57352 }, .{ .application_cursor = true }));
    try t.expectEqualStrings("", try encode(&buffer, .{ .code = 'a', .action = .release }, .{}));
    try t.expectEqualStrings("\x1b[27;1u", try encode(&buffer, .{ .code = 57344 }, .{ .kitty = 1 }));
    try t.expectEqualStrings("\x1b[9;6u", try encode(&buffer, .{ .code = 57346, .modifiers = .{ .control = true, .shift = true } }, .{ .kitty = 1 }));
    try t.expectEqualStrings("\x1b[1;1:2A", try encode(&buffer, .{ .code = 57352, .action = .repeat }, .{ .kitty = 31 }));
    try t.expectEqualStrings("😀", try encode(&buffer, .{ .code = 0x1f600, .text = "😀" }, .{}));
    try t.expectEqualStrings("\r", try encode(&buffer, .{ .code = 13 }, .{}));
    try t.expectEqualStrings("\x1b[27;1u", try encode(&buffer, .{ .code = 27 }, .{ .kitty = 1 }));
    try t.expectEqualStrings("\x1b[27;1:1u", try encode(&buffer, .{ .code = 57344, .shifted = 57344 }, .{ .kitty = 31 }));
    try t.expectEqualStrings("\x1b[F", try encode(&buffer, .{ .code = 57424 }, .{}));
    try t.expectEqualStrings("\x1b[57424;1u", try encode(&buffer, .{ .code = 57424 }, .{ .kitty = 1 }));
}

test "grapheme edits are invariant at every byte split and allocation failures are clean" {
    const bytes = "e\xcc\x81界👩‍💻🇮🇳\x1b[1;3H\x1b[@\x1b[P\r\nZ";
    var reference = try vt.Screen.init(t.allocator, 3, 12);
    defer reference.deinit();
    var parser = vt.Parser.init();
    parser.feed(bytes, &reference);
    for (0..bytes.len + 1) |split| {
        var screen = try vt.Screen.init(t.allocator, 3, 12);
        defer screen.deinit();
        parser.reset();
        parser.feed(bytes[0..split], &screen);
        parser.feed(bytes[split..], &screen);
        for (reference.cells, screen.cells) |a, b| {
            try t.expectEqual(a.codepoint, b.codepoint);
            try t.expectEqual(a.width, b.width);
            try t.expectEqualSlices(u21, a.grapheme, b.grapheme);
        }
    }
    try t.checkAllAllocationFailures(t.allocator, exerciseAllocations, .{});
}

fn exerciseAllocations(allocator: std.mem.Allocator) !void {
    var session = try vt.Session.init(allocator, 2, 5);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("e\xcc\x81👩‍💻\x1b[?u\x1b[?1049h🇮🇳", &session);
    if (session.takeError()) |err| return err;
    try session.resize(3, 8);
}

test "late emoji width expands across a margin and bidi controls do not advance" {
    var screen = try vt.Screen.init(t.allocator, 2, 3);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("ab♥\xef\xb8\x8f", &screen);
    try t.expectEqual(@as(u21, 0x2665), screen.getCell(1, 0).?.codepoint);
    try t.expectEqual(@as(u2, 2), screen.getCell(1, 0).?.width);
    try t.expectEqual(@as(u21, ' '), screen.getCell(0, 2).?.codepoint);
    screen.reset();
    parser.feed("\u{2067}אב\u{2069}", &screen);
    try t.expectEqual(@as(usize, 2), screen.cursor.column);
    try t.expectEqualSlices(u21, &.{ 0x2067, 0x5d0 }, screen.getGrapheme(0, 0).?);
}

test "mouse tracking filters motion encodes release and avoids legacy overflow" {
    var buffer: [128]u8 = undefined;
    const encode = vt.Input.encodePointer;
    const event: vt.Input.Pointer = .{ .kind = .release, .button = 0, .column = 300, .row = 4 };
    try t.expectEqualStrings("\x1b[<0;301;5m", try encode(&buffer, event, .{ .mouse_tracking = 1000, .mouse_sgr = true }));
    try t.expectEqualStrings("", try encode(&buffer, event, .{ .mouse_tracking = 1000 }));
    try t.expectEqualStrings("", try encode(&buffer, .{ .kind = .motion, .column = 0, .row = 0 }, .{ .mouse_tracking = 1002 }));
    try t.expectEqualStrings("\x1b[<35;1;1M", try encode(&buffer, .{ .kind = .motion, .column = 0, .row = 0 }, .{ .mouse_tracking = 1003, .mouse_sgr = true }));
}

test "paste is normalized and framed as one transaction" {
    const bytes = try vt.Input.paste(t.allocator, "é\r\nx\ny\x00\x1b[201~", true);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("\x1b[200~é\rx\ry[201~\x1b[201~", bytes);
    const large = try t.allocator.alloc(u8, 100000);
    defer t.allocator.free(large);
    @memset(large, 'x');
    const transaction = try vt.Input.paste(t.allocator, large, true);
    defer t.allocator.free(transaction);
    try t.expectEqual(@as(usize, 100012), transaction.len);
}

test "grapheme ownership survives wide edits scrolling resize and emoji extension" {
    var session = try vt.Session.init(t.allocator, 2, 6);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("e\xcc\x81👩‍💻\x1b[1;2H\x1b[P\r\n🇮🇳\r\nA", &session);
    try t.expect(session.takeError() == null);
    try t.expectEqualSlices(u21, &.{ 0x1f1ee, 0x1f1f3 }, session.screen.getGrapheme(0, 0).?);
    try session.resize(3, 8);
    try t.expectEqualSlices(u21, &.{ 0x1f1ee, 0x1f1f3 }, session.screen.getGrapheme(0, 0).?);
    parser.feed("\x1b[2J", &session);
}
