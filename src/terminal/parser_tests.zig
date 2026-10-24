//! Behavioral tests written for Vertex's parser contract.
const std = @import("std");
const t = std.testing;
const vt = @import("root.zig");
const trace = @import("trace.zig");

const streaming: vt.Options = .{ .osc_mode = .streaming, .apc_mode = .streaming };

// Serialize events synchronously, while borrowed sequence slices are valid.
// Comparing these transcripts also checks event order across chunk boundaries.
const Transcript = struct {
    storage: [32768]u8 = undefined,
    used: usize = 0,

    pub fn handle(self: *@This(), event: vt.Event) void {
        var writer = std.Io.Writer.fixed(self.storage[self.used..]);
        trace.writeEvent(&writer, event) catch @panic("transcript capacity exceeded");
        self.used += writer.buffered().len;
    }

    fn accept(self: *@This(), events: vt.Events) void {
        var saw_null = false;
        for (events) |item| {
            if (item) |event| {
                std.debug.assert(!saw_null);
                self.handle(event);
            } else saw_null = true;
        }
    }

    fn bytes(self: *const @This()) []const u8 {
        return self.storage[0..self.used];
    }
};

fn transcript(input: []const u8, options: vt.Options) Transcript {
    var result: Transcript = .{};
    var parser = vt.Parser.initWithOptions(options);
    parser.feed(input, &result);
    result.accept(parser.finish());
    return result;
}

fn expect(input: []const u8, options: vt.Options, expected: []const u8) !void {
    const result = transcript(input, options);
    try t.expectEqualStrings(expected, result.bytes());
}

const Probe = struct {
    prints: usize = 0,
    replacements: usize = 0,
    controls: usize = 0,
    commands: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    data: usize = 0,
    sum: usize = 0,
    last_final: u8 = 0,
    param_count: usize = 0,
    last_value: ?u16 = null,
    intermediate_count: usize = 0,

    pub fn handle(self: *@This(), event: vt.Event) void {
        switch (event) {
            .print => |cp| {
                self.prints += 1;
                if (cp == 0xfffd) self.replacements += 1;
            },
            .execute => self.controls += 1,
            .esc => |command| {
                self.commands += 1;
                self.intermediate_count = command.intermediates.len;
                self.last_final = command.final;
            },
            .csi, .dcs_begin => |command| {
                self.commands += 1;
                self.param_count = command.parameters.len;
                if (self.param_count != 0) self.last_value = command.parameters[self.param_count - 1].value;
                self.intermediate_count = command.intermediates.len;
                self.last_final = command.final;
                if (event == .dcs_begin) self.begins += 1;
            },
            .osc_begin, .apc_begin => self.begins += 1,
            .osc_data, .apc_data, .dcs_data => |byte| {
                self.data += 1;
                self.sum +%= byte;
            },
            .osc_end, .apc_end, .dcs_end => self.ends += 1,
            .osc => self.commands += 1,
        }
    }

    fn accept(self: *@This(), events: vt.Events) void {
        for (events) |item| {
            if (item) |event| self.handle(event);
        }
    }
};

test "text decoding emits Unicode scalars and C0 separately" {
    try expect("xλ水🚀\u{009b}\u{10ffff}\x00\n\x7f", .{}, "PRINT U+0078 \"x\"\n" ++
        "PRINT U+03BB \"\\xCE\\xBB\"\n" ++
        "PRINT U+6C34 \"\\xE6\\xB0\\xB4\"\n" ++
        "PRINT U+1F680 \"\\xF0\\x9F\\x9A\\x80\"\n" ++
        "PRINT U+009B \"\\xC2\\x9B\"\n" ++
        "PRINT U+10FFFF \"\\xF4\\x8F\\xBF\\xBF\"\n" ++
        "EXECUTE 0x00\nEXECUTE 0x0A\n");
}

test "invalid UTF-8 replaces maximal invalid prefixes without eating following bytes" {
    const cases = [_]struct { bytes: []const u8, replacements: usize }{
        .{ .bytes = "\xc1\xbf", .replacements = 2 },
        .{ .bytes = "\xe0\x9f\xbf", .replacements = 3 },
        .{ .bytes = "\xed\xa0\x80", .replacements = 3 },
        .{ .bytes = "\xf0\x8f\xbf\xbf", .replacements = 4 },
        .{ .bytes = "\xf4\x90\x80\x80", .replacements = 4 },
        .{ .bytes = "\xf5\x80", .replacements = 2 },
        .{ .bytes = "\xe2\x82", .replacements = 1 },
        .{ .bytes = "\xf1\x80\x80", .replacements = 1 },
        .{ .bytes = "\x9b", .replacements = 1 },
    };
    for (cases) |case| {
        var parser = vt.Parser.init();
        var probe: Probe = .{};
        parser.feed(case.bytes, &probe);
        parser.feed("Q\x1b[7m\n", &probe);
        probe.accept(parser.finish());
        try t.expectEqual(case.replacements, probe.replacements);
        try t.expectEqual(case.replacements + 1, probe.prints);
        try t.expectEqual(@as(usize, 1), probe.commands);
        try t.expectEqual(@as(usize, 1), probe.controls);
    }
}

test "headers preserve private prefixes omitted values separators and intermediates" {
    try expect("\x1b[?;0:4; m\x1b[H\x1b[>9u\x1b(0", .{}, "CSI prefix=\"?\" params=[_;0:4;_] intermediates=\" \" final=\"m\"\n" ++
        "CSI prefix=\"\" params=[] intermediates=\"\" final=\"H\"\n" ++
        "CSI prefix=\">\" params=[9] intermediates=\"\" final=\"u\"\n" ++
        "ESC intermediates=\"(\" final=\"0\"\n");
    var parser = vt.Parser.init();
    var probe: Probe = .{};
    parser.feed("\x1b[9999999999999999m", &probe);
    try t.expectEqual(@as(?u16, 65535), probe.last_value);
}

test "C0 executes in ESC and CSI but DCS header controls are ignored" {
    try expect("\x1b\t7\x1b[3\nJ\x1bP\tqz\x1b\\", .{}, "EXECUTE 0x09\nESC intermediates=\"\" final=\"7\"\n" ++
        "EXECUTE 0x0A\nCSI prefix=\"\" params=[3] intermediates=\"\" final=\"J\"\n" ++
        "DCS_BEGIN prefix=\"\" params=[] intermediates=\"\" final=\"q\"\nDCS_DATA 0x7A\nDCS_END st\n");
}

test "OSC buffers complete messages and supports both terminators" {
    try expect("\x1b]9;λ\x01\x07\x1b]2;tab\x1b\\", .{}, "OSC terminator=bel data=\"9;\\xCE\\xBB\"\n" ++
        "OSC terminator=st data=\"2;tab\"\n");
    try expect("\x1b]discard\x18\x1b]discard\x1a\x1b]unfinished", .{}, "EXECUTE 0x18\nEXECUTE 0x1A\n");
}

test "default APC SOS and PM payloads stay out of the text stream" {
    try expect("\x1b_Ghidden\x07still\x1b\\\x1bXhidden\x1b\\\x1b^hidden\x1b\\!", .{}, "PRINT U+0021 \"!\"\n");
}

test "streamed strings report bytes and successful endings without aggregate OSC" {
    try expect("\x1b]A\x01\x7f\xff\x07\x1b_G\x00\x07\x7f\xff\x1b\\", streaming, "OSC_BEGIN\nOSC_DATA 0x41\nOSC_DATA 0x7F\nOSC_DATA 0xFF\nOSC_END bel\n" ++
        "APC_BEGIN\nAPC_DATA 0x47\nAPC_DATA 0x00\nAPC_DATA 0x07\nAPC_DATA 0x7F\nAPC_DATA 0xFF\nAPC_END st\n");
}

test "DCS keeps its header and streams bytes including C0 and high bytes" {
    try expect("\x1bP1;2q\x00\x07\xff\x7f\x1b\\", .{}, "DCS_BEGIN prefix=\"\" params=[1;2] intermediates=\"\" final=\"q\"\n" ++
        "DCS_DATA 0x00\nDCS_DATA 0x07\nDCS_DATA 0xFF\nDCS_END st\n");
}

test "stream cancellation is ordered before execute and permits subsequent text" {
    try expect("\x1b_X\x18Z\x1b]Y\x1a\x1bPq\x18", streaming, "APC_BEGIN\nAPC_DATA 0x58\nAPC_END cancelled\nEXECUTE 0x18\nPRINT U+005A \"Z\"\n" ++
        "OSC_BEGIN\nOSC_DATA 0x59\nOSC_END cancelled\nEXECUTE 0x1A\n" ++
        "DCS_BEGIN prefix=\"\" params=[] intermediates=\"\" final=\"q\"\nDCS_END cancelled\nEXECUTE 0x18\n");
    try expect("\x1b_\x1b\x1a", streaming, "APC_BEGIN\nAPC_END cancelled\nEXECUTE 0x1A\n");
}

test "an interrupted payload ends before a new escape command" {
    try expect("\x1b_\x1b]v\x1b[5m\x1bPq\x1b\x1b7", streaming, "APC_BEGIN\nAPC_END interrupted\nOSC_BEGIN\nOSC_DATA 0x76\nOSC_END interrupted\n" ++
        "CSI prefix=\"\" params=[5] intermediates=\"\" final=\"m\"\n" ++
        "DCS_BEGIN prefix=\"\" params=[] intermediates=\"\" final=\"q\"\nDCS_END interrupted\n" ++
        "ESC intermediates=\"\" final=\"7\"\n");
}

test "EOF closes each streamed family including a pending ESC exactly once" {
    for ([_][]const u8{ "\x1b_", "\x1b_\x1b", "\x1b]", "\x1b]\x1b", "\x1bPq", "\x1bPq\x1b" }) |input| {
        var parser = vt.Parser.initWithOptions(streaming);
        var probe: Probe = .{};
        parser.feed(input, &probe);
        probe.accept(parser.finish());
        probe.accept(parser.finish());
        try t.expectEqual(@as(usize, 1), probe.begins);
        try t.expectEqual(@as(usize, 1), probe.ends);
    }
    try expect("\x1b_", streaming, "APC_BEGIN\nAPC_END end_of_input\n");
    try expect("\xf0\x90", .{}, "PRINT U+FFFD \"\\xEF\\xBF\\xBD\"\n");
    try expect("\x1b[23", .{}, "");
}

test "reset silently abandons input and both reset and finish retain options" {
    var parser = vt.Parser.initWithOptions(streaming);
    var probe: Probe = .{};
    parser.feed("\x1b_", &probe);
    parser.reset();
    parser.feed("\x1b]b\x07\x1b_", &probe);
    probe.accept(parser.finish());
    parser.feed("\x1b]c\x1b\\", &probe);
    probe.accept(parser.finish());
    try t.expectEqual(@as(usize, 4), probe.begins);
    try t.expectEqual(@as(usize, 3), probe.ends);
    try t.expectEqual(@as(usize, 2), probe.data);
}

test "parameter and intermediate storage accepts the boundary then rejects overflow" {
    var parser = vt.Parser.init();
    var probe: Probe = .{};
    parser.feed("\x1b[", &probe);
    for (0..vt.Parser.max_parameters - 1) |_| parser.feed(";", &probe);
    parser.feed("m", &probe);
    try t.expectEqual(vt.Parser.max_parameters, probe.param_count);
    try t.expectEqual(@as(usize, 1), probe.commands);
    parser.feed("\x1b[", &probe);
    for (0..vt.Parser.max_parameters) |_| parser.feed(":", &probe);
    parser.feed("m", &probe);
    try t.expectEqual(@as(usize, 1), probe.commands);
    for ([_][]const u8{ "\x1b", "\x1b[", "\x1bP" }) |start| {
        parser.reset();
        probe = .{};
        parser.feed(start, &probe);
        for (0..vt.Parser.max_intermediates) |_| parser.feed(" ", &probe);
        parser.feed("q", &probe);
        try t.expectEqual(vt.Parser.max_intermediates, probe.intermediate_count);
        try t.expectEqual(@as(u8, 'q'), probe.last_final);
        parser.feed("\x1b\\", &probe);
        parser.reset();
        probe = .{};
        parser.feed(start, &probe);
        for (0..vt.Parser.max_intermediates + 1) |_| parser.feed(" ", &probe);
        parser.feed("q", &probe);
        try t.expectEqual(@as(usize, 0), probe.commands);
        parser.feed("\x1b\\\x1b[8m", &probe);
        try t.expectEqual(@as(u8, 'm'), probe.last_final);
    }
}

test "malformed headers discard the entire command and recover on terminator or cancellation" {
    try expect("\x1bP??\x1b\\Q", .{}, "PRINT U+0051 \"Q\"\n");
    try expect("\x1b[1?m\x1b[??m\x1b[1 2m\x1bP1?qlost\x1b\\\x1b[4m", .{}, "CSI prefix=\"\" params=[4] intermediates=\"\" final=\"m\"\n");
    try expect("\x1bP??qlost\x18Q\x1b[1?\x1b[2m", .{}, "EXECUTE 0x18\nPRINT U+0051 \"Q\"\nCSI prefix=\"\" params=[2] intermediates=\"\" final=\"m\"\n");
}

test "DCS parameter overflow discards through ST even without a header final" {
    var parser = vt.Parser.init();
    var probe: Probe = .{};
    parser.feed("\x1bP", &probe);
    for (0..vt.Parser.max_parameters - 1) |_| parser.feed(":", &probe);
    parser.feed("q!\x1b\\", &probe);
    try t.expectEqual(vt.Parser.max_parameters, probe.param_count);
    try t.expectEqual(@as(usize, 1), probe.commands);
    try t.expectEqual(@as(usize, 1), probe.begins);
    try t.expectEqual(@as(usize, 1), probe.ends);
    probe = .{};
    parser.feed("\x1bP", &probe);
    for (0..vt.Parser.max_parameters) |_| parser.feed(";", &probe);
    parser.feed("\x1b\\Q", &probe);
    try t.expectEqual(@as(usize, 0), probe.commands);
    try t.expectEqual(@as(usize, 0), probe.begins);
    try t.expectEqual(@as(usize, 1), probe.prints);
}

test "OSC and APC streaming can be enabled independently" {
    try expect("\x1b]a\x07\x1b_b\x1b\\", .{ .osc_mode = .streaming }, "OSC_BEGIN\nOSC_DATA 0x61\nOSC_END bel\n");
    try expect("\x1b]a\x07\x1b_b\x1b\\", .{ .apc_mode = .streaming }, "OSC terminator=bel data=\"a\"\nAPC_BEGIN\nAPC_DATA 0x62\nAPC_END st\n");
    try expect("\x1b]", streaming, "OSC_BEGIN\nOSC_END end_of_input\n");
    try expect("\x1bPq", streaming, "DCS_BEGIN prefix=\"\" params=[] intermediates=\"\" final=\"q\"\nDCS_END end_of_input\n");
}

test "buffered OSC accepts the exact capacity and discards rather than truncates overflow" {
    var parser = vt.Parser.init();
    var probe: Probe = .{};
    parser.feed("\x1b]", &probe);
    const fill: [vt.Parser.max_osc_bytes]u8 = @splat('a');
    parser.feed(&fill, &probe);
    // Inspect the completed borrowed payload before another parser operation.
    const events = parser.next(7);
    try t.expectEqual(vt.Parser.max_osc_bytes, events[0].?.osc.data.len);
    try t.expectEqualSlices(u8, &fill, events[0].?.osc.data);
    parser.feed("\x1b]", &probe);
    parser.feed(&fill, &probe);
    parser.feed("b\x07Q", &probe);
    try t.expectEqual(@as(usize, 0), probe.commands);
    try t.expectEqual(@as(usize, 1), probe.prints);
}

test "large OSC APC and DCS payloads stream without accumulating message storage" {
    const block: [1024]u8 = @splat('e');
    for ([_][]const u8{ "\x1b]", "\x1b_", "\x1bPq" }) |start| {
        var parser = vt.Parser.initWithOptions(streaming);
        var probe: Probe = .{};
        parser.feed(start, &probe);
        for (0..128) |_| parser.feed(&block, &probe);
        parser.feed("\x1b\\Q", &probe);
        probe.accept(parser.finish());
        try t.expectEqual(@as(usize, 128 * block.len), probe.data);
        try t.expectEqual(@as(usize, 128 * block.len * 'e'), probe.sum);
        try t.expectEqual(@as(usize, 1), probe.begins);
        try t.expectEqual(@as(usize, 1), probe.ends);
        try t.expectEqual(@as(usize, 1), probe.prints);
        try t.expectEqual(@as(usize, 0), parser.osc_count);
    }
}

test "protocol-shaped image transports reach a consumer without decoding" {
    const examples = [_]struct { input: []const u8, data: []const u8, final: u8 = 0 }{
        .{ .input = "\x1b_Ga=T,f=32,s=1,v=1;AAAAAA==\x1b\\", .data = "Ga=T,f=32,s=1,v=1;AAAAAA==" },
        .{ .input = "\x1b]1337;File=inline=1:AAAA\x07", .data = "1337;File=inline=1:AAAA" },
        .{ .input = "\x1bP0;1q~$@\x1b\\", .data = "~$@", .final = 'q' },
    };
    for (examples) |example| {
        var parser = vt.Parser.initWithOptions(streaming);
        var probe: Probe = .{};
        parser.feed(example.input, &probe);
        probe.accept(parser.finish());
        var sum: usize = 0;
        for (example.data) |byte| sum += byte;
        try t.expectEqual(example.data.len, probe.data);
        try t.expectEqual(sum, probe.sum);
        try t.expectEqual(example.final, probe.last_final);
        try t.expectEqual(@as(usize, 1), probe.ends);
    }
}

test "every split point and empty chunk produces the same events" {
    const input = "λ\xe2\x82Q\x1b[?2:;4 m\x1b]title\x07\x1b_G;AA\x1b\\\x1bPq@\x1b[3m\x1bXhide\x1b\\\xf1\x80";
    for ([_]vt.Options{ .{}, streaming }) |options| {
        const reference = transcript(input, options);
        for (0..input.len + 1) |split| {
            var parser = vt.Parser.initWithOptions(options);
            var actual: Transcript = .{};
            parser.feed(input[0..split], &actual);
            parser.feed("", &actual);
            parser.feed(input[split..], &actual);
            actual.accept(parser.finish());
            try t.expectEqualStrings(reference.bytes(), actual.bytes());
        }
    }
}

test "every possible next byte from representative states recovers at a fresh CSI" {
    const prefixes = [_][]const u8{ "", "\xf0", "\x1b", "\x1b(", "\x1b[", "\x1b[??", "\x1bP", "\x1bPq", "\x1bP??q", "\x1b]a", "\x1b]a\x1b", "\x1b_G", "\x1b_\x1b", "\x1bX" };
    for ([_]vt.Options{ .{}, streaming }) |options| {
        for (prefixes) |prefix| {
            for (0..256) |value| {
                var parser = vt.Parser.initWithOptions(options);
                var probe: Probe = .{};
                parser.feed(prefix, &probe);
                probe.accept(parser.next(@intCast(value)));
                parser.feed("\x18\x1b[6m", &probe);
                try t.expectEqual(@as(u8, 'm'), probe.last_final);
                try t.expectEqual(@as(?u16, 6), probe.last_value);
            }
        }
    }
}

test "deterministic arbitrary inputs are invariant under byte-sized feeds" {
    var seed: u32 = 0xa5b79321;
    for (0..32) |_| {
        var input: [192]u8 = undefined;
        for (&input) |*byte| {
            seed = seed *% 1664525 +% 1013904223;
            byte.* = @truncate(seed >> 16);
        }
        for ([_]vt.Options{ .{}, streaming }) |options| {
            const reference = transcript(&input, options);
            var parser = vt.Parser.initWithOptions(options);
            var actual: Transcript = .{};
            for (input) |byte| actual.accept(parser.next(byte));
            actual.accept(parser.finish());
            try t.expectEqualStrings(reference.bytes(), actual.bytes());
        }
    }
}
