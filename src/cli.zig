const std = @import("std");
const terminal = @import("terminal/root.zig");
const trace = @import("terminal/trace.zig");

const usage =
    \\Usage: vertex [parse [--stream-strings] | --help]
    \\
    \\  parse       Read VT bytes from stdin and write an escaped event trace.
    \\  --stream-strings  Trace OSC and APC incrementally (after parse).
    \\  --help, -h  Show this help.
    \\
    \\Example: printf '\033[31mHello\033[0m\n' | vertex parse
    \\
;

/// Arguments exclude argv[0]. Streams are injected for headless CLI tests.
pub fn run(
    args: []const []const u8,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    diagnostic: *std.Io.Writer,
) !u8 {
    if (args.len == 0) {
        try diagnostic.writeAll("Vertex: terminal emulator project initialized.\n");
        return 0;
    }
    if ((args.len == 1 and isHelp(args[0])) or
        (args.len == 2 and std.mem.eql(u8, args[0], "parse") and isHelp(args[1])))
    {
        try output.writeAll(usage);
        return 0;
    }
    const stream_strings = args.len == 2 and std.mem.eql(u8, args[1], "--stream-strings");
    if (!std.mem.eql(u8, args[0], "parse") or !(args.len == 1 or stream_strings)) {
        try diagnostic.writeAll("vertex: invalid arguments\n");
        try diagnostic.writeAll(usage);
        return 2;
    }

    var parser = terminal.Parser.initWithOptions(if (stream_strings)
        .{ .osc_mode = .streaming, .apc_mode = .streaming }
    else
        .{});
    var bytes: [4096]u8 = undefined;
    while (true) {
        var buffers = [_][]u8{&bytes};
        const len = input.readVec(&buffers) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        for (bytes[0..len]) |byte| {
            for (parser.next(byte)) |maybe_event| {
                if (maybe_event) |event| try trace.writeEvent(output, event);
            }
        }
        // Make each available input chunk visible without waiting for EOF.
        try output.flush();
    }
    for (parser.finish()) |maybe_event| {
        if (maybe_event) |event| try trace.writeEvent(output, event);
    }
    return 0;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

test {
    _ = @import("cli_tests.zig");
}
