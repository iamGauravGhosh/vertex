//! Integration check using only the package's public module import.
const std = @import("std");
const vt = @import("vertex_terminal");

test "public media API supports links and raw images without libc or an encoded-file decoder" {
    var session = try vt.Session.initWithOptions(std.testing.allocator, 3, 20, .{ .images = true });
    defer session.deinit();
    session.geometry = .{ .width = 160, .height = 48, .cell_width = 8, .cell_height = 16 };
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming, .apc_mode = .streaming });
    parser.feed("\x1b]8;;https://example.com\x07link\x1b]8;;\x07\x1b_Ga=T,f=24,s=1,v=1,C=1;/wAA\x1b\\", &session);
    try std.testing.expect(session.takeError() == null);
    try std.testing.expectEqualStrings("https://example.com", session.screen.getLink(0, 0).?);
    const match = (try vt.Links.find(std.testing.allocator, &session.screen, 0, 1)).?;
    defer std.testing.allocator.free(match.uri);
    try std.testing.expectEqualStrings("https://example.com", match.uri);
    const images: []const vt.Graphics.Placement = session.screen.getImages();
    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, images[0].bitmap.pixels);
}

test {
    _ = @import("unicode_conformance.zig");
}

test "a public session consumer negotiates input and drains replies without OS dependencies" {
    var session = try vt.Session.init(std.testing.allocator, 2, 8);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[>31u\x1b[?u\x1b[?2004h", &session);
    if (session.takeError()) |err| return err;
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try session.drainReplies(&writer);
    try std.testing.expectEqualStrings("\x1b[?31u", writer.buffered());
    const key: vt.Input.Key = .{ .code = 27 };
    try std.testing.expectEqualStrings("\x1b[27;1:1u", try vt.Input.encodeKey(&buffer, key, session.getModes()));
    try session.resize(3, 10);
    try std.testing.expectEqual(@as(usize, 10), session.activeScreen().columns);
    try std.testing.expect(session.getModes().bracketed_paste);
}

test "a public host can schedule synchronized presentation and own streamed clipboard writes" {
    var session = try vt.Session.init(std.testing.allocator, 2, 8);
    defer session.deinit();
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
    try std.testing.expect(!session.presentationHeld(1000));
    parser.feed("\x1b[?2026hA\x1b]52;c;YWJj\x07", &session);
    if (session.takeError()) |err| return err;
    try std.testing.expect(session.presentationHeld(1100));
    const copied = session.takeClipboard().?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("abc", copied);
    try std.testing.expect(session.activeScreen().getRowGeneration(0) != null);
    try std.testing.expect(session.activeScreen().getRowGeneration(2) == null);
    try std.testing.expect(!session.presentationHeld(1150));
    try std.testing.expect(session.activeScreen().getDamageRows()[0]);
}

test "a public screen consumer applies colors cursor movement and scrolling" {
    var screen = try vt.Screen.init(std.testing.allocator, 2, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[31mABCD\r\n\x1b[38;2;1;2;3mEFGH", &screen);
    parser.feed("\x1b[S\x1b[2;3HX", &screen);
    for (parser.finish()) |item| if (item) |event| screen.handle(event);
    const cell: vt.Cell = screen.getCell(0, 0).?;
    const style: vt.Style = cell.style;
    const color: vt.Color = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    const cursor: vt.Cursor = screen.getCursor();
    try std.testing.expectEqual(@as(u21, 'E'), cell.codepoint);
    try std.testing.expectEqualDeep(color, style.foreground);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getRow(1).?[2].codepoint);
    try std.testing.expectEqual(@as(usize, 1), cursor.row);
    try std.testing.expectEqual(@as(usize, 3), cursor.column);
    try screen.resize(3, 5);
    try std.testing.expectEqual(@as(u21, 'X'), screen.getRow(1).?[2].codepoint);
    try std.testing.expectEqualDeep(vt.Cell{}, screen.getCell(2, 4).?);
}

const Consumer = struct {
    characters: [8]u21 = undefined,
    characters_len: usize = 0,
    controls: usize = 0,
    sgr: usize = 0,

    pub fn handle(self: *@This(), event: vt.Event) void {
        switch (event) {
            .print => |codepoint| {
                self.characters[self.characters_len] = codepoint;
                self.characters_len += 1;
            },
            .execute => self.controls += 1,
            .csi => |sequence| {
                if (sequence.final == 'm') self.sgr += 1;
            },
            else => {},
        }
    }
};

test "a separate consumer can feed chunks and finalize through the public API" {
    var parser = vt.Parser.init();
    var consumer: Consumer = .{};
    parser.feed("\x1b[31mA\xf0\x9f", &consumer);
    parser.feed("\x99\x82\x1b[0m\n", &consumer);
    for (parser.finish()) |maybe_event| {
        if (maybe_event) |event| consumer.handle(event);
    }
    try std.testing.expectEqualSlices(u21, &.{ 'A', 0x1f642 }, consumer.characters[0..consumer.characters_len]);
    try std.testing.expectEqual(@as(usize, 1), consumer.controls);
    try std.testing.expectEqual(@as(usize, 2), consumer.sgr);
}

// A stand-in for a future decoder's input boundary. It owns all transferred
// bytes, and only accepts a complete successfully terminated message.
const Transfer = struct {
    bytes: [16384]u8 = undefined,
    used: usize = 0,
    active: bool = false,
    accepted: bool = false,
    failed: bool = false,

    pub fn handle(self: *@This(), event: vt.Event) void {
        switch (event) {
            .osc_begin, .apc_begin, .dcs_begin => {
                self.used = 0;
                self.active = true;
                self.accepted = false;
                self.failed = false;
            },
            .osc_data, .apc_data, .dcs_data => |byte| {
                if (self.used == self.bytes.len) self.failed = true;
                if (!self.failed) {
                    self.bytes[self.used] = byte;
                    self.used += 1;
                }
            },
            .osc_end => |reason| self.end(reason == .st or reason == .bel),
            .apc_end, .dcs_end => |reason| self.end(reason == .st),
            else => {},
        }
    }

    fn end(self: *@This(), success: bool) void {
        self.accepted = self.active and success and !self.failed;
        self.active = false;
        if (!self.accepted) self.used = 0;
    }
};

test "a public module consumer can own large image transport data for a later decoder" {
    const options: vt.Options = .{ .osc_mode = .streaming, .apc_mode = .streaming };
    const content: [8192]u8 = @splat('C');
    for ([_][]const u8{ "\x1b_G", "\x1b]1337;", "\x1bPq" }) |start| {
        var parser = vt.Parser.initWithOptions(options);
        var transfer: Transfer = .{};
        parser.feed(start, &transfer);
        const prefix_len = transfer.used;
        parser.feed(content[0..1777], &transfer);
        parser.feed(content[1777..], &transfer);
        try std.testing.expect(!transfer.accepted);
        parser.feed("\x1b", &transfer);
        try std.testing.expect(!transfer.accepted);
        parser.feed("\\", &transfer);
        try std.testing.expect(transfer.accepted);
        try std.testing.expectEqualSlices(u8, &content, transfer.bytes[prefix_len..transfer.used]);
        for (parser.finish()) |item| {
            if (item) |event| transfer.handle(event);
        }
        try std.testing.expect(transfer.accepted);
    }
}

test "a consumer rejects incomplete cancelled and over-budget image transfers" {
    var parser = vt.Parser.initWithOptions(.{ .apc_mode = .streaming });
    var transfer: Transfer = .{};
    for ([_][]const u8{ "\x1b_Gabc\x18", "\x1b_Gabc\x1b[0m", "\x1b_Gabc" }) |input| {
        parser.feed(input, &transfer);
        for (parser.finish()) |item| {
            if (item) |event| transfer.handle(event);
        }
        try std.testing.expect(!transfer.accepted);
        try std.testing.expectEqual(@as(usize, 0), transfer.used);
    }
    parser.feed("\x1b_G", &transfer);
    const block: [1024]u8 = @splat('D');
    for (0..20) |_| parser.feed(&block, &transfer);
    parser.feed("\x1b\\", &transfer);
    try std.testing.expect(!transfer.accepted);
    try std.testing.expect(transfer.failed);
    // The parser drained the rejected payload and is ready for another one.
    parser.feed("\x1b_Gok\x1b\\", &transfer);
    try std.testing.expect(transfer.accepted);
    try std.testing.expectEqualStrings("Gok", transfer.bytes[0..transfer.used]);
}

test "a presentation consumer can inspect accumulate and acknowledge row damage" {
    var screen = try vt.Screen.init(std.testing.allocator, 2, 4);
    defer screen.deinit();
    try std.testing.expectEqualSlices(bool, &.{ true, true }, screen.getDamageRows());
    screen.clearDamage();
    var parser = vt.Parser.init();
    parser.feed("X", &screen);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, screen.getDamageRows());
    parser.feed("\r\nY", &screen);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, screen.getDamageRows());
    screen.clearDamage();
    screen.invalidateAll();
    try std.testing.expectEqualSlices(bool, &.{ true, true }, screen.getDamageRows());
}
