//! Integration check using only the package's public module import.
const std = @import("std");
const vt = @import("vertex_terminal");

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
