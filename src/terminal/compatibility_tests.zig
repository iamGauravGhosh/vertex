const std = @import("std");
const vt = @import("root.zig");
const t = std.testing;
fn feed(s: *vt.Session, bytes: []const u8) !void {
    var p = vt.Parser.init();
    p.feed(bytes, s);
    if (s.takeError()) |err| return err;
}

test "editor decorations preserve text attributes and consume malformed color groups" {
    var s = try vt.Session.init(t.allocator, 2, 20);
    defer s.deinit();
    try feed(&s, "\x1b[31m\x1b[4:3;58;2;255;0;0mX\x1b[58;2;999;0;0;1mY\x1b[59;24mZ");
    const x = s.screen.getCell(0, 0).?.style;
    try t.expectEqualDeep(vt.Color{ .indexed = 1 }, x.foreground);
    try t.expectEqualDeep(vt.Color{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }, x.underline_color);
    try t.expect(x.underline and x.underline_style == .curly and !x.faint);
    try t.expect(s.screen.getCell(0, 1).?.style.bold);
    try t.expect(!s.screen.getCell(0, 2).?.style.underline);
    try t.expectEqual(vt.Color.default, s.screen.getCell(0, 2).?.style.underline_color);
}
test "Neovim's extended underline detection receives a truthful SGR status" {
    var s = try vt.Session.init(t.allocator, 2, 10);
    defer s.deinit();
    try feed(&s, "\x1b[0m\x1b[4:3m\x1bP$qm\x1b\\");
    try t.expectEqualStrings("\x1bP1$r0;4:3m\x1b\\", s.replies.items);
}
test "legacy Alt Shift Tab and negotiated Super Hyper Meta shortcuts stay distinct" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("\x1b\x1b[Z", try vt.Input.encodeKey(&buf, .{ .code = 9, .modifiers = .{ .alt = true, .shift = true } }, .{}));
    try t.expectEqualStrings("\x1b[97;9u", try vt.Input.encodeKey(&buf, .{ .code = 'a', .text = "a", .modifiers = .{ .super = true } }, .{ .kitty = 1 }));
    try t.expectEqualStrings("\x1b[97;17u", try vt.Input.encodeKey(&buf, .{ .code = 'a', .text = "a", .modifiers = .{ .hyper = true } }, .{ .kitty = 1 }));
    try t.expectEqualStrings("\x1b[97;33u", try vt.Input.encodeKey(&buf, .{ .code = 'a', .text = "a", .modifiers = .{ .meta = true } }, .{ .kitty = 1 }));
}
test "advertised insert blink and reset controls affect real screen state" {
    var s = try vt.Session.init(t.allocator, 4, 12);
    defer s.deinit();
    try feed(&s, "abc\x1b[1;2H\x1b[4hX\x1b[?12h");
    try t.expectEqual(@as(u21, 'b'), s.screen.getCell(0, 2).?.codepoint);
    try t.expect(s.screen.cursor.blinking);
    try feed(&s, "\x1b[2;4r\x1b[?6h\x1b[31m\x1b[!p");
    try t.expect(!s.screen.origin_mode and !s.screen.insert_mode and s.screen.scroll_top == 0);
    try t.expectEqualDeep(vt.Style{}, s.screen.style);
    try feed(&s, "\x1b[4$p\x1b[?2027$p\x1b[>q");
    try t.expectEqualStrings("\x1b[4;2$y\x1b[?2027;3$y\x1bP>|Vertex(0.0.1)\x1b\\", s.replies.items);
}
test "insert mode retains following text when a late emoji selector widens a cluster" {
    var s = try vt.Session.init(t.allocator, 2, 8);
    defer s.deinit();
    try feed(&s, "X\r\x1b[4h❤️");
    try t.expectEqual(@as(u2, 2), s.screen.getCell(0, 0).?.width);
    try t.expectEqual(@as(u21, 'X'), s.screen.getCell(0, 2).?.codepoint);
}
test "restoring origin-mode cursor after margin changes keeps CPR in bounds" {
    var s = try vt.Session.init(t.allocator, 2, 12);
    defer s.deinit();
    try feed(&s, "\x1b[?69h\x1b[3;8s\x1b[?6h\x1b7\x1b[5;10s\x1b8\x1b[6n");
    try t.expectEqualStrings("\x1b[1;1R", s.replies.items);
}
test "palette updates queries resets and configuration reload share one resolved theme" {
    var s = try vt.Session.init(t.allocator, 2, 10);
    defer s.deinit();
    try feed(&s, "\x1b]4;1;rgb:11/22/33\x07\x1b]4;1;?\x07\x1b]10;#abc;#123;#456\x07");
    try t.expectEqualStrings("\x1b]4;1;rgb:1111/2222/3333\x1b\\", s.replies.items);
    s.setTheme(.{ .foreground = 0x010203 });
    try t.expectEqual(@as(u32, 0xaabbcc), s.theme.foreground);
    try t.expectEqual(@as(u32, 0x112233), s.theme.at(1));
    try feed(&s, "\x1b]104;1\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07");
    try t.expectEqual(@as(u32, 0x010203), s.theme.foreground);
    const defaults = vt.Theme{};
    try t.expectEqual(defaults.at(1), s.theme.at(1));
}
test "history survives reflow selection eviction and alternate screen isolation" {
    var s = try vt.Session.initWithOptions(t.allocator, 3, 8, .{ .history_lines = 20, .reflow = true });
    defer s.deinit();
    try feed(&s, "abcdefghijk\r\nline two\r\nline 3\r\nlast");
    try t.expect(s.historyCount() > 0);
    s.scroll(100);
    const start = s.point(0, 0);
    s.select(start, .{ .row = start.row + 1, .column = 3 });
    const before = try s.copySelection(t.allocator);
    defer t.allocator.free(before);
    try t.expectEqualStrings("abcdefghijk", before);
    try s.resize(3, 5);
    const after = try s.copySelection(t.allocator);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
    try s.resize(3, 12);
    const wide = try s.copySelection(t.allocator);
    defer t.allocator.free(wide);
    try t.expectEqualStrings(before, wide);
    var view = try s.viewport();
    defer view.deinit();
    try t.expect(!view.cursor.visible);
    const count = s.historyCount();
    try feed(&s, "\x1b[?1049h1\r\n2\r\n3\r\n4\x1b[?1049l");
    try t.expectEqual(count, s.historyCount());
    try feed(&s, "\x1b[3J");
    try t.expectEqual(@as(usize, 0), s.historyCount());
}
test "history copies graphemes and hyperlinks and excludes partial regions" {
    var s = try vt.Session.initWithOptions(t.allocator, 3, 12, .{ .history_lines = 2, .history_bytes = 4096 });
    defer s.deinit();
    try feed(&s, "\x1b]8;;https://example.com\x07界é👩‍💻\x1b]8;;\x07\r\na\r\nb\r\nc");
    s.scroll(1);
    s.select(s.point(0, 1), s.point(0, 7));
    const copy = try s.copySelection(t.allocator);
    defer t.allocator.free(copy);
    try t.expectEqualStrings("界é👩‍💻", copy);
    var view = try s.viewport();
    defer view.deinit();
    try t.expect(view.getCell(0, 0).?.style.inverse);
    try t.expectEqualStrings("https://example.com", s.history.?.get(0).?.cells[0].link.?.uri);
    const count = s.historyCount();
    try feed(&s, "\x1b[2;3r\x1b[3;1H\n\n\n");
    try t.expectEqual(count, s.historyCount());
    try feed(&s, "\x1b[r\x1b[3;1H\n\n\n\n");
    try t.expectEqual(@as(usize, 2), s.historyCount());
    try t.expect(s.selection == null);
}
fn allocationExercise(a: std.mem.Allocator) !void {
    var s = try vt.Session.initWithOptions(a, 2, 8, .{ .history_lines = 10, .reflow = true });
    defer s.deinit();
    try feed(&s, "界é\r\na\r\nb\r\nc");
    try s.resize(3, 5);
    s.scroll(1);
    var view = try s.viewport();
    defer view.deinit();
}
test "wide wrap padding and one-column resize never enter copied text" {
    var s = try vt.Session.initWithOptions(t.allocator, 4, 5, .{ .history_lines = 30, .reflow = true });
    defer s.deinit();
    const text = "abcd界xé👩‍💻end";
    try feed(&s, text);
    s.select(.{ .row = 0, .column = 0 }, .{ .row = s.history.?.next_id + s.screen.cursor.row, .column = s.screen.cursor.column + @intFromBool(s.screen.wrap_pending) });
    for ([_]usize{ 5, 2, 1, 8 }) |columns| {
        try s.resize(4, columns);
        const copy = try s.copySelection(t.allocator);
        defer t.allocator.free(copy);
        try t.expectEqualStrings(text, copy);
    }
}
test "reflow works when history retention is disabled and newline mode encodes Return" {
    var s = try vt.Session.initWithOptions(t.allocator, 5, 8, .{ .reflow = true });
    defer s.deinit();
    try feed(&s, "abcdefghijk");
    try s.resize(5, 4);
    s.select(.{ .row = 0, .column = 0 }, .{ .row = 2, .column = 3 });
    const text = try s.copySelection(t.allocator);
    defer t.allocator.free(text);
    try t.expectEqualStrings("abcdefghijk", text);
    try t.expectEqual(@as(usize, 0), s.historyCount());
    try feed(&s, "\x1b[20h");
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("\r\n", try vt.Input.encodeKey(&buf, .{ .code = 13 }, s.getModes()));
}
test "history and reflow allocation failures retain ownership" {
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}
