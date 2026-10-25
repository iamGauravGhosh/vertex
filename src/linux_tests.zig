//! Headless Linux integration tests. Optional Wayland test uses a nested compositor.
const std = @import("std");
const t = std.testing;
const c = @import("c");
const Pty = @import("platform/Pty.zig");
const common = @import("platform/common.zig");
const input = @import("platform/input.zig");
const Renderer = @import("renderer/root.zig");
const vt = @import("terminal/root.zig");
const linux = @import("platform/linux.zig");

test "the complete native event loop compiles" {
    std.mem.doNotOptimizeAway(&linux.run);
}

test "keyboard encodes UTF-8, navigation, modifiers, and shell controls" {
    var bytes: [128]u8 = undefined;
    try t.expectEqualStrings("é", try input.encode(&bytes, 0xe9, "é", .{}));
    try t.expectEqualStrings("\x03", try input.encode(&bytes, 'c', "c", .{ .control = true }));
    try t.expectEqualStrings("\x00", try input.encode(&bytes, ' ', " ", .{ .control = true }));
    try t.expectEqualStrings("\x1bb", try input.encode(&bytes, 'b', "b", .{ .alt = true }));
    try t.expectEqualStrings("\r", try input.encode(&bytes, c.XKB_KEY_Return, "", .{}));
    try t.expectEqualStrings("\x7f", try input.encode(&bytes, c.XKB_KEY_BackSpace, "", .{}));
    try t.expectEqualStrings("\x1b[A", try input.encode(&bytes, c.XKB_KEY_Up, "", .{}));
    try t.expectEqualStrings("\x1b[1;5D", try input.encode(&bytes, c.XKB_KEY_Left, "", .{ .control = true }));
    try t.expectEqualStrings("\x1b[3~", try input.encode(&bytes, c.XKB_KEY_Delete, "", .{}));
    try t.expectEqualStrings("\x1b[Z", try input.encode(&bytes, c.XKB_KEY_ISO_Left_Tab, "", .{ .shift = true }));
    try t.expectEqualStrings("", try input.encode(&bytes, c.XKB_KEY_Shift_L, "", .{}));
}

fn readUntil(pty: *Pty, buffer: []u8, needle: []const u8) ![]const u8 {
    var length: usize = 0;
    const deadline = common.milliseconds() + 5000;
    while (common.milliseconds() < deadline) {
        const count = pty.read(buffer[length..]) catch |err| switch (err) {
            error.WouldBlock => {
                var fd = c.pollfd{ .fd = pty.master, .events = c.POLLIN, .revents = 0 };
                _ = c.poll(&fd, 1, 20);
                continue;
            },
            else => return err,
        };
        length += count;
        if (std.mem.indexOf(u8, buffer[0..length], needle) != null) return buffer[0..length];
        if (count == 0 or length == buffer.len) break;
    }
    std.debug.print("PTY output: {s}\n", .{buffer[0..length]});
    return error.ExpectedPtyOutputMissing;
}

fn waitExit(pty: *Pty) !u8 {
    const deadline = common.milliseconds() + 5000;
    while (common.milliseconds() < deadline) {
        if (try pty.pollExit()) |status| return status;
        _ = c.poll(null, 0, 10);
    }
    return error.ChildDidNotExit;
}

test "PTY gives the child a controlling terminal, environment, input, and initial size" {
    var pty = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2 && test -r /dev/tty || exit 90; printf '%s %s\\n' \"$TERM\" \"$COLORTERM\"; stty size; printf 'READY\\n'; read answer; printf 'GOT:%s\\n' \"$answer\"; exit 7" }, 24, 80);
    defer pty.deinit();
    var buffer: [8192]u8 = undefined;
    const output = try readUntil(&pty, &buffer, "READY");
    try t.expect(std.mem.indexOf(u8, output, "xterm-256color truecolor") != null);
    try t.expect(std.mem.indexOf(u8, output, "24 80") != null);
    try t.expectEqual(@as(usize, 6), try pty.write("hello\n"));
    _ = try readUntil(&pty, &buffer, "GOT:hello");
    try t.expectEqual(@as(u8, 7), try waitExit(&pty));
}

test "PTY resize updates kernel dimensions and notifies foreground child" {
    var pty = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "trap 'stty size; exit 0' WINCH; printf 'READY\\n'; while :; do sleep 0.05; done" }, 24, 80);
    defer pty.deinit();
    var buffer: [4096]u8 = undefined;
    _ = try readUntil(&pty, &buffer, "READY");
    try pty.resize(37, 101);
    _ = try readUntil(&pty, &buffer, "37 101");
    try t.expectEqual(@as(u8, 0), try waitExit(&pty));
}

test "PTY failed exec and forced cleanup do not leak a child or master fd" {
    try t.expectError(error.ShellExecFailed, Pty.spawn(t.allocator, &.{"/vertex/no-such-shell"}, 24, 80));
    var pty = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "trap '' HUP; printf 'READY\\n'; while :; do read line; done" }, 24, 80);
    var buffer: [4096]u8 = undefined;
    _ = readUntil(&pty, &buffer, "READY") catch |err| {
        pty.deinit();
        return err;
    };
    const pid = pty.pid;
    const fd = pty.master;
    pty.deinit();
    try t.expectEqual(@as(c_int, -1), c.fcntl(fd, c.F_GETFD));
    var status: c_int = 0;
    try t.expectEqual(@as(c.pid_t, -1), c.waitpid(pid, &status, c.WNOHANG));
    try t.expectEqual(@as(c_int, c.ECHILD), common.errno());
}

test "renderer draws styled cells, cursor, missing glyphs, and clips to the grid" {
    var renderer = try Renderer.init(t.allocator);
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 3);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[41;8mX\x1b[0;1;3;4mA\xf4\x8f\xbf\xbf\x1b[?25l", &screen);
    const width = renderer.cell_width * 3;
    const height = renderer.cell_height;
    const pixels = try t.allocator.alloc(u32, width * height + 2);
    defer t.allocator.free(pixels);
    @memset(pixels, 0xdeadbeef);
    try renderer.draw(&screen, pixels[1 .. pixels.len - 1], width, height);
    try t.expectEqual(@as(u32, 0xdeadbeef), pixels[0]);
    try t.expectEqual(@as(u32, 0xdeadbeef), pixels[pixels.len - 1]);
    for (0..height) |y| for (0..renderer.cell_width) |x| try t.expectEqual(Renderer.color(.{ .indexed = 1 }, 0), pixels[1 + y * width + x]);
    var changed: usize = 0;
    for (pixels[1 .. pixels.len - 1]) |pixel| if (pixel == Renderer.default_foreground) {
        changed += 1;
    };
    try t.expect(changed > 0);
    screen.reset();
    try renderer.draw(&screen, pixels[1 .. pixels.len - 1], width, height);
    try t.expectEqual(Renderer.default_foreground, pixels[1]);
    try t.expectEqual(@as(u32, 0xff0000), Renderer.color(.{ .indexed = 196 }, 0));
    try t.expectEqual(@as(u32, 0x080808), Renderer.color(.{ .indexed = 232 }, 0));
    try renderer.setScale(2);
    // A clipped target also exercises scaled glyph bounds without reallocating it.
    parser.feed("A", &screen);
    try renderer.draw(&screen, pixels[1 .. pixels.len - 1], width, height);
}

test "optional Wayland window starts a child and exits with its status" {
    if (c.getenv("VERTEX_TEST_WAYLAND") == null) return error.SkipZigTest;
    const custom_script = c.getenv("VERTEX_TEST_WAYLAND_SCRIPT");
    const script = if (custom_script != null) std.mem.span(custom_script) else "printf '\\033[31mVertex Wayland smoke\\033[0m\\n'; sleep 0.2; exit 7";
    const expected_environment = c.getenv("VERTEX_TEST_WAYLAND_STATUS");
    const expected: u8 = if (expected_environment != null) try std.fmt.parseInt(u8, std.mem.span(expected_environment), 10) else 7;
    try t.expectEqual(expected, try linux.run(t.allocator, &.{ "/bin/sh", "-c", script }));
}

test "shaping forms ligatures, preserves columns and style boundaries, and caches rows" {
    var renderer = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("ffiX", &screen);
    const glyphs = try renderer.shapeRow(&screen, 0);
    // The test face is selected explicitly, independently of the user's monospace font.
    try t.expect(glyphs.len < 4);
    try t.expectEqual(@as(usize, 0), glyphs[0].column);
    try t.expectEqual(@as(usize, 3), glyphs[0].end);
    const last = glyphs[glyphs.len - 1];
    try t.expectEqual(@as(i64, @intCast(3 * renderer.cell_width * 64)), last.x);
    const shaped = renderer.shaped_rows;
    parser.feed("\x1b[1G\x1b[?25l", &screen);
    _ = try renderer.shapeRow(&screen, 0);
    try t.expectEqual(shaped, renderer.shaped_rows);
    parser.feed("\x1b[2G\x1b[31mf", &screen);
    const split = try renderer.shapeRow(&screen, 0);
    try t.expectEqual(@as(usize, 4), split.len);
    try renderer.setScale(2);
    _ = try renderer.shapeRow(&screen, 0);
    try t.expectEqual(shaped + 2, renderer.shaped_rows);
}

test "incremental CPU and GPU frames match full redraws through edits cursor scroll and scale" {
    const Gpu = @import("renderer/Gpu.zig");
    var renderer = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer renderer.deinit();
    var reference = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer reference.deinit();
    var screen = try vt.Screen.init(t.allocator, 4, 12);
    defer screen.deinit();
    const width = renderer.cell_width * screen.columns + 3;
    const height = renderer.cell_height * screen.rows + 5;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    @memset(pixels, Renderer.default_background);
    const expected = try t.allocator.alloc(u32, pixels.len);
    defer t.allocator.free(expected);
    const rgba = try t.allocator.alloc(u8, pixels.len * 4);
    defer t.allocator.free(rgba);
    var gpu = Gpu.initHeadless(t.allocator, width, height) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    var parser = vt.Parser.init();
    const edits = [_][]const u8{
        "",                                  "ffi ABC\r\nsecond row", "\x1b[1;2H",           "\x1b[?25l",       "\x1b[?25h",
        "\x1b[1;2H\x1b[31;1;3;4;9mf\x1b[0m", "\x1b[2;3H\x1b[2@XY",    "\x1b[P\x1b[K",        "\x1b[2;4r\x1b[S", "\x1b[T",
        "\x1b[3;1H\x1b[L",                   "\x1b[M",                "\x1b[44;7mZZ\x1b[0m", "\x1b[2J",         "\x1b[41;8mhidden\x1b[0m",
        "\x1b[1;1H\xf4\x8f\xbf\xbf",         "\x1bc",
    };
    for (edits) |edit| {
        parser.feed(edit, &screen);
        if (try damage.prepare(&screen, width, height, renderer.cell_height)) {
            if (damage.full) @memset(pixels, Renderer.default_background);
            try renderer.drawRows(&screen, pixels, width, height, damage.rows);
            try gpu.render(&renderer, &screen, &damage);
            try reference.draw(&screen, expected, width, height);
            try t.expectEqualSlices(u32, expected, pixels);
            try gpu.readPixels(rgba);
            for (expected, 0..) |rgb, i| {
                const x = i % width;
                const y = i / width;
                const offset = ((height - 1 - y) * width + x) * 4;
                inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
                    const delta = @as(i32, @intCast((rgb >> shift) & 255)) - rgba[offset + channel];
                    if (@abs(delta) > 1) {
                        std.debug.print("pixel {d},{d} channel {d}: CPU {x}, GPU {d}, edit {s}\n", .{ x, y, channel, rgb, rgba[offset + channel], edit });
                        return error.GpuPixelMismatch;
                    }
                }
            }
            damage.commit(&screen);
        }
    }
    try t.expect(!try damage.prepare(&screen, width, height, renderer.cell_height));
    try renderer.setScale(2);
    try reference.setScale(2);
    damage.invalidate();
    parser.feed("\x1b[1;1Hffi", &screen);
    _ = try damage.prepare(&screen, width, height, renderer.cell_height * 2);
    @memset(pixels, Renderer.default_background);
    try renderer.drawRows(&screen, pixels, width, height, damage.rows);
    try gpu.render(&renderer, &screen, &damage);
    try reference.draw(&screen, expected, width, height);
    try t.expectEqualSlices(u32, expected, pixels);
    try gpu.readPixels(rgba);
    for (expected, 0..) |rgb, i| {
        const offset = ((height - 1 - i / width) * width + i % width) * 4;
        inline for (.{ 16, 8, 0 }, 0..) |shift, channel| try t.expect(@abs(@as(i32, @intCast((rgb >> shift) & 255)) - rgba[offset + channel]) <= 1);
    }
}

fn expectGpuPixels(gpu: *@import("renderer/Gpu.zig"), expected: []const u32) !void {
    const rgba = try t.allocator.alloc(u8, expected.len * 4);
    defer t.allocator.free(rgba);
    try gpu.readPixels(rgba);
    for (expected, 0..) |rgb, i| {
        const offset = ((gpu.height - 1 - i / gpu.width) * gpu.width + i % gpu.width) * 4;
        inline for (.{ 16, 8, 0 }, 0..) |shift, channel| try t.expect(@abs(@as(i32, @intCast((rgb >> shift) & 255)) - rgba[offset + channel]) <= 1);
        try t.expectEqual(@as(u8, 255), rgba[offset + 3]);
    }
}

test "GPU batches survive atlas eviction and oversized tiled glyphs then window resize" {
    const Gpu = @import("renderer/Gpu.zig");
    var renderer = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer renderer.deinit();
    var reference = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer reference.deinit();
    try renderer.setScale(128);
    try reference.setScale(128);
    var screen = try vt.Screen.init(t.allocator, 1, 12);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("WMiABCDXYZfg\x1b[?25l", &screen);
    var gpu = Gpu.initHeadless(t.allocator, 256, 600) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    const expected = try t.allocator.alloc(u32, gpu.width * gpu.height);
    defer t.allocator.free(expected);
    for (0..2) |_| {
        _ = try damage.prepare(&screen, gpu.width, gpu.height, renderer.cell_height * renderer.scale);
        // Populate and evict masks on the CPU before sharing the same atlas with
        // the GPU, including pages that receive both cached and new tiles.
        try renderer.draw(&screen, expected, gpu.width, gpu.height);
        try gpu.render(&renderer, &screen, &damage);
        try reference.draw(&screen, expected, gpu.width, gpu.height);
        try expectGpuPixels(&gpu, expected);
        try gpu.present(damage.rects.items);
        damage.commit(&screen);
        damage.invalidate();
    }
    // At this size glyphs require multiple atlas tiles; twelve distinct glyphs
    // recycle all four pages while earlier quads are still being rendered.
    var tiles: usize = 0;
    for (renderer.atlas.pages) |page| {
        try t.expectEqual(@as(usize, Renderer.Atlas.size * Renderer.Atlas.size), page.pixels.len);
        var keys = page.entries.keyIterator();
        while (keys.next()) |key| if (key.x > 0 or key.y > 0) {
            tiles += 1;
        };
    }
    try t.expect(tiles > 0);
    try renderer.setScale(1);
    try reference.setScale(1);
    try screen.resize(3, 8);
    parser.feed("\x1bc\x1b[31mffi\r\nresize\x1b[0m", &screen);
    try gpu.resize(99, 81);
    damage.invalidate();
    _ = try damage.prepare(&screen, gpu.width, gpu.height, renderer.cell_height);
    try gpu.render(&renderer, &screen, &damage);
    const resized = try t.allocator.alloc(u32, gpu.width * gpu.height);
    defer t.allocator.free(resized);
    try reference.draw(&screen, resized, gpu.width, gpu.height);
    try expectGpuPixels(&gpu, resized);
    // Exercise ordinary swapping when swap-with-damage is unavailable.
    gpu.swap_damage = null;
    try gpu.present(damage.rects.items);
}
