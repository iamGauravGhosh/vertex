const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("vertex: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var diagnostic_buffer: [1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var diagnostic = std.Io.File.stderr().writerStreaming(init.io, &diagnostic_buffer);
    const status = try cli.run(args[1..], &input.interface, &output.interface, &diagnostic.interface);
    try output.interface.flush();
    try diagnostic.interface.flush();
    return status;
}

test {
    _ = @import("terminal/root.zig");
    _ = cli;
}

test "entry point compiles against the Zig process and I/O APIs" {
    std.mem.doNotOptimizeAway(&main);
}
