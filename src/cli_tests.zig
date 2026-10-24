const std = @import("std");
const testing = std.testing;
const cli = @import("cli.zig");

test "CLI traces piped controls, colors and Unicode without raw escapes" {
    var input = std.Io.Reader.fixed("\x1b[31mAé\x1b[0m\n");
    var output_bytes: [2048]u8 = undefined;
    var diagnostic_bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    var diagnostic = std.Io.Writer.fixed(&diagnostic_bytes);
    try testing.expectEqual(@as(u8, 0), try cli.run(&.{"parse"}, &input, &output, &diagnostic));
    try testing.expectEqualStrings(
        "CSI prefix=\"\" params=[31] intermediates=\"\" final=\"m\"\n" ++
            "PRINT U+0041 \"A\"\n" ++
            "PRINT U+00E9 \"\\xC3\\xA9\"\n" ++
            "CSI prefix=\"\" params=[0] intermediates=\"\" final=\"m\"\n" ++
            "EXECUTE 0x0A\n",
        output.buffered(),
    );
    try testing.expectEqual(@as(usize, 0), diagnostic.buffered().len);
}

test "CLI escapes OSC data, traces DCS and preserves missing subparameters" {
    var input = std.Io.Reader.fixed("\x1b[38:2::1:2:3m\x1b]2;\"\\\xff\x07\x1bP$qA\x1b\\");
    var output_bytes: [2048]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    var diagnostic = std.Io.Writer.fixed(&.{});
    try testing.expectEqual(@as(u8, 0), try cli.run(&.{"parse"}, &input, &output, &diagnostic));
    try testing.expectEqualStrings(
        "CSI prefix=\"\" params=[38:2:_:1:2:3] intermediates=\"\" final=\"m\"\n" ++
            "OSC terminator=bel data=\"2;\\\"\\\\\\xFF\"\n" ++
            "DCS_BEGIN prefix=\"\" params=[] intermediates=\"$\" final=\"q\"\n" ++
            "DCS_DATA 0x41\nDCS_END st\n",
        output.buffered(),
    );
    for (output.buffered()) |byte| try testing.expect(byte == '\n' or (byte >= 0x20 and byte <= 0x7e));
}

test "CLI selects the window without consuming streams" {
    var input = std.Io.Reader.fixed("");
    var output = std.Io.Writer.fixed(&.{});
    var diagnostic_bytes: [256]u8 = undefined;
    var diagnostic = std.Io.Writer.fixed(&diagnostic_bytes);
    try testing.expectError(error.WindowRequired, cli.run(&.{}, &input, &output, &diagnostic));
    try testing.expectEqualStrings("", diagnostic.buffered());
    try testing.expect(cli.opensWindow(&.{}));
    try testing.expect(cli.opensWindow(&.{ "--", "/bin/sh", "-c", "exit 0" }));
    try testing.expect(!cli.opensWindow(&.{"--"}));
    try testing.expect(!cli.opensWindow(&.{"parse"}));
}

test "CLI help and invalid arguments do not consume stdin" {
    const cases = [_]struct { args: []const []const u8, status: u8 }{
        .{ .args = &.{"--help"}, .status = 0 },
        .{ .args = &.{"-h"}, .status = 0 },
        .{ .args = &.{ "parse", "--help" }, .status = 0 },
        .{ .args = &.{"unknown"}, .status = 2 },
        .{ .args = &.{ "parse", "extra" }, .status = 2 },
        .{ .args = &.{ "--help", "extra" }, .status = 2 },
        .{ .args = &.{ "parse", "--unknown" }, .status = 2 },
        .{ .args = &.{ "--stream-strings", "parse" }, .status = 2 },
        .{ .args = &.{ "parse", "--stream-strings", "extra" }, .status = 2 },
    };
    for (cases) |case| {
        var input = std.Io.Reader.fixed("unread");
        var output_bytes: [1024]u8 = undefined;
        var diagnostic_bytes: [1024]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_bytes);
        var diagnostic = std.Io.Writer.fixed(&diagnostic_bytes);
        try testing.expectEqual(case.status, try cli.run(case.args, &input, &output, &diagnostic));
        const message = if (case.status == 0) output.buffered() else diagnostic.buffered();
        try testing.expect(std.mem.indexOf(u8, message, "Usage: vertex") != null);
        try testing.expectEqual(@as(usize, 0), input.seek);
    }
}

test "CLI finalizes incomplete UTF-8 and an empty input stream" {
    for ([_][]const u8{ "", "\xf0\x9f" }) |bytes| {
        var input = std.Io.Reader.fixed(bytes);
        var output_bytes: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_bytes);
        var diagnostic = std.Io.Writer.fixed(&.{});
        try testing.expectEqual(@as(u8, 0), try cli.run(&.{"parse"}, &input, &output, &diagnostic));
        try testing.expectEqualStrings(if (bytes.len == 0) "" else "PRINT U+FFFD \"\\xEF\\xBF\\xBD\"\n", output.buffered());
    }
}

test "CLI propagates read and write failures" {
    var failed_input: std.Io.Reader = .{
        .vtable = &.{ .stream = failRead },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var output_bytes: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_bytes);
    var diagnostic = std.Io.Writer.fixed(&.{});
    try testing.expectError(error.ReadFailed, cli.run(&.{"parse"}, &failed_input, &output, &diagnostic));

    var input = std.Io.Reader.fixed("A");
    var failed_output = std.Io.Writer.fixed(&.{});
    try testing.expectError(error.WriteFailed, cli.run(&.{"parse"}, &input, &failed_output, &diagnostic));
}

fn failRead(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
    return error.ReadFailed;
}

test "CLI streaming mode exposes escaped OSC and APC lifecycles" {
    var input = std.Io.Reader.fixed("\x1b]x\x07\x1b_G\xff\x1b\\\x1b_\x18");
    var bytes: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&bytes);
    var diagnostic = std.Io.Writer.fixed(&.{});
    try testing.expectEqual(@as(u8, 0), try cli.run(&.{ "parse", "--stream-strings" }, &input, &output, &diagnostic));
    try testing.expectEqualStrings(
        "OSC_BEGIN\nOSC_DATA 0x78\nOSC_END bel\n" ++
            "APC_BEGIN\nAPC_DATA 0x47\nAPC_DATA 0xFF\nAPC_END st\n" ++
            "APC_BEGIN\nAPC_END cancelled\nEXECUTE 0x18\n",
        output.buffered(),
    );
    for (output.buffered()) |byte| try testing.expect(byte == '\n' or (byte >= 0x20 and byte <= 0x7e));
}
