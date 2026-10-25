const std = @import("std");
const vt = @import("root.zig");
const t = std.testing;
fn parser() vt.Parser {
    return vt.Parser.initWithOptions(.{ .osc_mode = .streaming, .apc_mode = .streaming });
}
fn session(allocator: std.mem.Allocator) !vt.Session {
    var s = try vt.Session.initWithOptions(allocator, 8, 40, .{ .images = true, .decoder = fakeDecode });
    s.geometry = .{ .width = 320, .height = 128, .cell_width = 8, .cell_height = 16 };
    return s;
}
fn fakeDecode(allocator: std.mem.Allocator, bytes: []const u8) !vt.Graphics.Decoded {
    if (!std.mem.eql(u8, bytes, "abc")) return error.InvalidImage;
    return .{ .width = 2, .height = 1, .pixels = try allocator.dupe(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 128 }) };
}
test "OSC 8 targets retain ownership across styles wide graphemes edits resize and screens" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b]8;id=one;https://example.com/a;b\x1b\\A\x1b[0m界\x1b]8;;\x07Z", &s);
    try t.expectEqualStrings("https://example.com/a;b", s.screen.getLink(0, 0).?);
    try t.expectEqualStrings(s.screen.getLink(0, 1).?, s.screen.getLink(0, 2).?);
    try t.expect(s.screen.getLink(0, 3) == null);
    try s.resize(9, 41);
    try t.expectEqualStrings("https://example.com/a;b", s.screen.getLink(0, 2).?);
    p.feed("\x1b[?1049hother\x1b[?1049l\x1b[1;1H\x1b[P", &s);
    try t.expect(s.screen.getLink(0, 0) != null);
    p.feed("\x1b[2J\x1bc", &s);
    try t.expect(s.screen.getLink(0, 0) == null);
    try t.expect(s.screen.current_link == null);
    try t.expect(s.takeError() == null);
}
test "URL detection joins only soft wraps and trims punctuation with balanced parentheses" {
    var s = try vt.Session.init(t.allocator, 5, 12);
    defer s.deinit();
    var p = parser();
    p.feed("(https://a.test/x(y)).", &s);
    const match = (try vt.Links.find(t.allocator, &s.screen, 1, 2)).?;
    defer t.allocator.free(match.uri);
    try t.expectEqualStrings("https://a.test/x(y)", match.uri);
    try t.expect((try vt.Links.find(t.allocator, &s.screen, 0, 0)) == null);
    p.feed("\x1b[2J\x1b[Hhttps://a.\r\ntest", &s);
    try t.expect((try vt.Links.find(t.allocator, &s.screen, 1, 1)) == null);
}
test "desktop targets permit web mail local files and reject remote files and control bytes" {
    for ([_][]const u8{ "https://example.com", "HTTP://example.com/a", "mailto:a@example.com", "file:///tmp/a%20b", "file://localhost/tmp/a", "file:/tmp/a" }) |uri| try t.expect(vt.Links.allowed(uri));
    for ([_][]const u8{ "javascript:alert(1)", "file://evil/tmp/a", "file:relative", "https://", "https://a\nbye", "data:text/plain,x", "--help" }) |uri| try t.expect(!vt.Links.allowed(uri));
}
test "Kitty chunking replies placements cropping delete and query are split invariant" {
    const stream = "\x1b_Ga=T,f=32,s=1,v=1,i=42,p=3,C=1,m=1;/wAA\x1b\\\x1b_Gm=0;gA==\x1b\\";
    for (0..stream.len + 1) |split| {
        var s = try session(t.allocator);
        defer s.deinit();
        var p = parser();
        p.feed(stream[0..split], &s);
        p.feed(stream[split..], &s);
        try t.expect(s.takeError() == null);
        try t.expectEqual(@as(usize, 1), s.screen.graphics.placements.items.len);
        const image = s.screen.graphics.assets.items[0].bitmap;
        try t.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, image.pixels);
        try t.expectEqualStrings("\x1b_Gi=42,p=3;OK\x1b\\", s.replies.items);
        p.feed("\x1b_Ga=p,i=42,p=4,c=2,r=1,C=1,z=-1;\x1b\\", &s);
        try t.expectEqual(@as(usize, 2), s.screen.graphics.placements.items.len);
        p.feed("\x1b_Ga=d,d=i,i=42,p=3;\x1b\\", &s);
        try t.expectEqual(@as(usize, 1), s.screen.graphics.placements.items.len);
        p.feed("\x1b_Ga=d,d=I,i=42;\x1b\\", &s);
        try t.expectEqual(@as(usize, 0), s.screen.graphics.assets.items.len);
        try t.expectEqual(@as(usize, 0), s.screen.graphics.placements.items.len);
    }
}
test "Kitty queries do not persist images and quiet unsupported transports recover" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b_Ga=q,f=24,s=1,v=1,i=7;/wAA\x1b\\", &s);
    try t.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", s.replies.items);
    try t.expectEqual(@as(usize, 0), s.screen.graphics.assets.items.len);
    p.feed("\x1b_Ga=T,t=f,i=8,q=2;L2V0Yy9wYXNzd2Q=\x1b\\OK", &s);
    try t.expectEqual(@as(u21, 'O'), s.screen.cells[0].codepoint);
    try t.expect(s.takeError() == null);
}
test "Sixel repeats palettes transparency raster aspect modes and capability queries" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1bP0;1q\"1;1;3;6#1;2;100;0;0!3~\x1b\\", &s);
    try t.expect(s.takeError() == null);
    const image = s.screen.graphics.placements.items[0].bitmap;
    try t.expectEqual(@as(usize, 3), image.width);
    try t.expectEqual(@as(usize, 6), image.height);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels[0..4]);
    p.feed("\x1b[?80h\x1b[?80$p\x1b[?1;1S\x1b[c", &s);
    try t.expectEqualStrings("\x1b[?80;1$y\x1b[?1;0;256S\x1b[?1;2;4c", s.replies.items);
    p.feed("\x1b[2J", &s);
    try t.expectEqual(@as(usize, 0), s.screen.graphics.placements.items.len);
}
test "iTerm single multipart arbitrary base64 splits and sizing agree" {
    for ([_][]const u8{
        "\x1b]1337;File=inline=1;width=4;height=1;preserveAspectRatio=0:YWJj\x07",
        "\x1b]1337;MultipartFile=inline=1;width=4;height=1;preserveAspectRatio=0\x1b\\\x1b]1337;FilePart=Y\x07\x1b]1337;FilePart=WJj\x07\x1b]1337;FileEnd\x07",
    }) |stream| for (0..stream.len + 1) |split| {
        var s = try session(t.allocator);
        defer s.deinit();
        var p = parser();
        p.feed(stream[0..split], &s);
        p.feed(stream[split..], &s);
        try t.expect(s.takeError() == null);
        try t.expectEqual(@as(usize, 1), s.screen.graphics.placements.items.len);
        const placement = s.screen.graphics.placements.items[0];
        try t.expectEqual(@as(usize, 32), placement.width);
        try t.expectEqual(@as(usize, 16), placement.height);
        try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 128, 128 }, placement.bitmap.pixels);
    };
}
test "cancelled malformed and unfinished images preserve completed content and clipboard" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b_Ga=T,f=24,s=1,v=1,i=1,C=1;/wAA\x1b\\", &s);
    const original = s.screen.graphics.assets.items[0].bitmap.identity;
    p.feed("\x1b_Ga=T,f=24,s=1,v=1,i=1;bad!\x1b\\\x1b]1337;File=inline=1:YWJj\x18\x1bPq!999999999999999999999~\x1b\\\x1b]52;c;YWJj\x07text", &s);
    try t.expectEqual(original, s.screen.graphics.assets.items[0].bitmap.identity);
    const clipboard = s.takeClipboard().?;
    defer t.allocator.free(clipboard);
    try t.expectEqualStrings("abc", clipboard);
    try t.expectEqual(@as(u21, 't'), s.screen.cells[0].codepoint);
    try t.expect(s.takeError() == null);
}
test "graphics buffers clone through resize isolate alternate screens and survive text erases" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b_Ga=T,f=24,s=1,v=1,i=5,C=1;/wAA\x1b\\\x1b[K", &s);
    try t.expectEqual(@as(usize, 1), s.screen.graphics.placements.items.len);
    try s.resize(9, 41);
    p.feed("\x1b[?1049h\x1b_Ga=T,f=24,s=1,v=1,i=5,C=1;AAD/\x1b\\\x1b[?1049l", &s);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, s.screen.graphics.assets.items[0].bitmap.pixels);
    p.feed("\x1b[2J", &s);
    try t.expectEqual(@as(usize, 0), s.screen.graphics.placements.items.len);
}
fn allocations(allocator: std.mem.Allocator) !void {
    var s = try session(allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b]8;id=a;https://a.test\x07界\xef\xb8\x8f\x1b]8;;\x07\x1b_Ga=T,f=32,s=1,v=1,i=1,C=1;/wAAgA==\x1b\\", &s);
    if (s.takeError()) |err| return err;
    try s.resize(9, 41);
    const match = try vt.Links.find(allocator, &s.screen, 0, 0);
    if (match) |value| allocator.free(value.uri);
    p.feed("\x1b[2;1H\x1bP0;1q\"1;1;24;16#1;2;100;0;0!24~\x1b\\\x1b[2;2H\x1b[@\x1b[P\x1b[K\x1b]1337;File=inline=1:YWJj\x07", &s);
    if (s.takeError()) |err| return err;
}
test "every link image and resize allocation failure releases ownership" {
    try t.checkAllAllocationFailures(t.allocator, allocations, .{});
}

test "compressed raw pixels validate checksum and invalid placements preserve old assets" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b_Ga=T,f=32,s=1,v=1,o=z,i=4,C=1;eJz7z8DQAAAEgAGA\x1b\\", &s);
    try t.expect(s.takeError() == null);
    const id = s.screen.graphics.assets.items[0].bitmap.identity;
    p.feed("\x1b_Ga=T,f=32,s=1,v=1,i=4,C=1,x=999;/wAAgA==\x1b\\", &s);
    try t.expectEqual(id, s.screen.graphics.assets.items[0].bitmap.identity);
    p.feed("\x1b_Ga=T,f=32,s=1,v=1,o=z,i=4,C=1;eJz7z8DQAAAEgAGB\x1b\\", &s);
    try t.expectEqual(id, s.screen.graphics.assets.items[0].bitmap.identity);
    try t.expect(s.takeError() == null);
}

test "anonymous images are not cached and scrolling erasing and character edits release inline fragments" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b_Ga=T,f=24,s=1,v=1,C=1;/wAA\x1b\\", &s);
    try t.expectEqual(@as(usize, 0), s.screen.graphics.assets.items.len);
    try t.expectEqualStrings("", s.replies.items);
    p.feed("\x1b[2J\x1b[H\x1bP0;1q\"1;1;24;16#1;2;100;0;0!24~-!24~\x1b\\", &s);
    try t.expectEqual(@as(usize, 1), s.screen.getImages().len);
    p.feed("\x1b[1;1H\x1b[@", &s);
    var moved = false;
    for (s.screen.getImages()) |image| if (image.column == 1) {
        moved = true;
    };
    try t.expect(moved);
    p.feed("\x1b[P\x1b[2K\x1b[2J", &s);
    try t.expectEqual(@as(usize, 0), s.screen.getImages().len);
    try t.expect(s.takeError() == null);
}

test "large iTerm payloads stream past parser capacity and storage limits reject without fatal errors" {
    const Decoder = struct {
        fn decode(allocator: std.mem.Allocator, bytes: []const u8) !vt.Graphics.Decoded {
            if (bytes.len != 6000) return error.InvalidImage;
            return fakeDecode(allocator, "abc");
        }
    };
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    s.graphics.options.decoder = Decoder.decode;
    p.feed("\x1b]1337;File=inline=1:", &s);
    for (0..2000) |_| p.feed("YWJj", &s);
    p.feed("\x07", &s);
    try t.expectEqual(@as(usize, 1), s.screen.getImages().len);
    const budget = s.screen.graphics.budget.?;
    const used = budget.used;
    budget.used = vt.Graphics.max_storage;
    p.feed("\x1b_Ga=T,f=24,s=1,v=1,i=3,C=1;/wAA\x1b\\", &s);
    budget.used = used;
    try t.expectEqual(@as(usize, 0), s.screen.graphics.assets.items.len);
    try t.expect(s.takeError() == null);
    try t.expectError(error.ImageTooLarge, vt.Graphics.byteSize(8193, 1));
    try t.expectError(error.ImageTooLarge, vt.Graphics.byteSize(8192, 8192));
}

test "images crossing the bottom scroll into view and resize clips their source coverage" {
    var s = try session(t.allocator);
    defer s.deinit();
    var p = parser();
    p.feed("\x1b[8;1H\x1b]1337;File=inline=1;width=4;height=3;preserveAspectRatio=0:YWJj\x07", &s);
    try t.expect(s.takeError() == null);
    try t.expectEqual(@as(usize, 1), s.screen.getImages().len);
    const image = s.screen.getImages()[0];
    try t.expectEqual(@as(i32, 4), image.row);
    try t.expectEqual(@as(usize, 48), image.height);
    try s.resize(6, 40);
    try t.expectEqual(@as(i32, 32), s.screen.getImages()[0].clip_bottom);
}
