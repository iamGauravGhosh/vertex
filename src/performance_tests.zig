//! Opt-in repeatable text/render workload; timings are diagnostic, not CI gates.
const std = @import("std");
const c = @import("c");
const vt = @import("terminal/root.zig");
const Renderer = @import("renderer/root.zig");

fn nanos() u64 {
    var value: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &value);
    return @as(u64, @intCast(value.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(value.tv_nsec));
}

test "benchmark busy terminal rows" {
    if (c.getenv("VERTEX_BENCH") == null) return error.SkipZigTest;
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    var renderer = try Renderer.initFont(allocator, "DejaVu Sans Mono");
    defer renderer.deinit();
    var screen = try vt.Screen.init(allocator, 48, 160);
    defer screen.deinit();
    var parser = vt.Parser.init();
    const width = screen.columns * renderer.cell_width;
    const height = screen.rows * renderer.cell_height;
    const pixels = try allocator.alloc(u32, width * height);
    defer allocator.free(pixels);
    var samples: [200]u64 = undefined;
    var buffer: [256]u8 = undefined;
    var warm_allocations: usize = 0;
    for (0..220) |iteration| {
        screen.clearDamage();
        const start = nanos();
        for (0..8) |pane| {
            const bytes = try std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[38;2;50;180;220mworkspace {d}: build step {d} -- []{{}}() => log output\x1b[0m\x1b[K", .{ pane * 6 + 1, pane, iteration });
            parser.feed(bytes, &screen);
        }
        try renderer.drawRows(&screen, pixels, width, height, screen.getDamageRows());
        if (iteration == 19) warm_allocations = counted.alloc_index;
        if (iteration >= 20) samples[iteration - 20] = nanos() - start;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    try std.testing.expectEqual(warm_allocations, counted.alloc_index);
    std.debug.print("\nvertex benchmark: 160x48, 8 active rows, CPU, DejaVu Sans Mono; p50={d}us p95={d}us p99={d}us shaped={d}\n", .{ samples[100] / 1000, samples[190] / 1000, samples[198] / 1000, renderer.shaped_rows });
}
