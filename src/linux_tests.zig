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

test {
    _ = linux;
    _ = @import("performance_tests.zig");
}

test "memory image decoder handles PNG JPEG first GIF frame and rejects malformed dimensions" {
    const Decoder = @import("platform/ImageDecoder.zig");
    const png_file = try imageFixture("tests/images/rgba.png");
    defer t.allocator.free(png_file);
    const png = try Decoder.decode(t.allocator, png_file);
    defer t.allocator.free(png.pixels);
    try t.expectEqual(@as(usize, 2), png.width);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 255, 0 }, png.pixels);
    const jpeg_file = try imageFixture("tests/images/rgb.jpg");
    defer t.allocator.free(jpeg_file);
    const jpeg = try Decoder.decode(t.allocator, jpeg_file);
    defer t.allocator.free(jpeg.pixels);
    try t.expectEqual(@as(usize, 2), jpeg.width);
    try t.expect(jpeg.pixels[0] >= 250 and jpeg.pixels[1] <= 5 and jpeg.pixels[3] == 255);
    const gif_file = try imageFixture("tests/images/animated.gif");
    defer t.allocator.free(gif_file);
    const gif = try Decoder.decode(t.allocator, gif_file);
    defer t.allocator.free(gif.pixels);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, gif.pixels);
    try t.expectError(error.InvalidImage, Decoder.decode(t.allocator, "not an image"));
    const oversized = try t.allocator.dupe(u8, png_file);
    defer t.allocator.free(oversized);
    @memcpy(oversized[16..20], &[_]u8{ 0, 1, 0, 0 });
    try t.expectError(error.InvalidImage, Decoder.decode(t.allocator, oversized));
}

fn imageFixture(path: [:0]const u8) ![]u8 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.FixtureMissing;
    defer _ = c.close(fd);
    var data: [4096]u8 = undefined;
    const n = c.read(fd, &data, data.len);
    if (n <= 0 or n == data.len) return error.InvalidFixture;
    return t.allocator.dupe(u8, data[0..@intCast(n)]);
}

test "inline images match CPU GPU full and damaged frames through layering scroll erase and scale" {
    const Gpu = @import("renderer/Gpu.zig");
    const Decoder = @import("platform/ImageDecoder.zig");
    var renderer = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer renderer.deinit();
    var reference = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer reference.deinit();
    var session = try vt.Session.initWithOptions(t.allocator, 5, 16, .{ .images = true, .decoder = Decoder.decode });
    defer session.deinit();
    session.geometry = .{ .width = renderer.cell_width * 16, .height = renderer.cell_height * 5, .cell_width = renderer.cell_width, .cell_height = renderer.cell_height };
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming, .apc_mode = .streaming });
    const width = session.geometry.width;
    const height = session.geometry.height;
    var gpu = Gpu.initHeadless(t.allocator, width, height) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    const expected = try t.allocator.alloc(u32, pixels.len);
    defer t.allocator.free(expected);
    const edits = [_][]const u8{
        "\x1b[?25l\x1b_Ga=T,f=32,s=2,v=2,i=1,C=1,c=3,r=2,z=-1;/wAA/wD/AIAAAP//////AA==\x1b\\",
        "\x1b[2;2H\x1b_Ga=p,i=1,p=2,C=1,c=2,r=2,z=1;\x1b\\",
        "\x1b[1;1H\x1b[44mAB\x1b[0m\x1b_Ga=p,i=1,p=3,C=1,c=3,r=1,z=-2000000000;\x1b\\",
        "\x1b_Ga=d,d=i,i=1,p=2;\x1b\\",
        "\x1b[2;1H\x1bP0;1q\"1;1;8;6#1;2;100;0;0!8~\x1b\\",
        "\x1b[2;1H\x1b[K",
        "\x1b[S",
        "\x1b[T",
        "\x1b[2J",
        "\x1b_Ga=T,f=24,s=1,v=1,i=9,C=1,c=2,r=1;AP8A\x1b\\",
    };
    for (edits) |edit| {
        parser.feed(edit, &session);
        try t.expect(session.takeError() == null);
        if (!try damage.prepare(&session.screen, width, height, renderer.cell_height)) continue;
        if (damage.full) @memset(pixels, Renderer.default_background);
        try renderer.drawRows(&session.screen, pixels, width, height, damage.rows);
        try gpu.render(&renderer, &session.screen, &damage);
        try reference.draw(&session.screen, expected, width, height);
        try t.expectEqualSlices(u32, expected, pixels);
        try expectGpuPixels(&gpu, expected);
        damage.commit(&session.screen);
    }
    try t.expect(!try damage.prepare(&session.screen, width, height, renderer.cell_height));
    // A CPU reference frame also verifies that fallback does not lose resources.
    try renderer.setScale(2);
    try reference.setScale(2);
    damage.invalidate();
    _ = try damage.prepare(&session.screen, width, height, renderer.cell_height * 2);
    try renderer.draw(&session.screen, pixels, width, height);
    try gpu.render(&renderer, &session.screen, &damage);
    try expectGpuPixels(&gpu, pixels);
}

test "hover underline preserves styles and bidi pointer mapping finds logical hyperlinks" {
    var renderer = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer renderer.deinit();
    renderer.bidi = true;
    var session = try vt.Session.init(t.allocator, 2, 20);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[?25lאב \x1b]8;;https://example.com\x07界\x1b]8;;\x07", &session);
    const visual = try renderer.visualColumn(&session.screen, 0, 3);
    const logical = try renderer.logicalColumn(&session.screen, 0, visual);
    const match = (try vt.Links.find(t.allocator, &session.screen, 0, logical)).?;
    defer t.allocator.free(match.uri);
    const width = renderer.cell_width * 20;
    const height = renderer.cell_height * 2;
    const before = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(before);
    const after = try t.allocator.alloc(u32, before.len);
    defer t.allocator.free(after);
    try renderer.draw(&session.screen, before, width, height);
    renderer.hover = match.range;
    try renderer.draw(&session.screen, after, width, height);
    try t.expect(!std.mem.eql(u32, before, after));
    try t.expect(!session.screen.cells[3].style.underline);
}

test "shaping generations reuse cursor-only rows and invalidate deferred edits and screen switches" {
    var renderer = try Renderer.initFont(t.allocator, "Vertex Test Mono");
    defer renderer.deinit();
    var session = try vt.Session.init(t.allocator, 2, 12);
    defer session.deinit();
    var parser = vt.Parser.init();
    parser.feed("first", &session);
    _ = try renderer.shapeRow(&session.screen, 0);
    const shaped = renderer.shaped_rows;
    parser.feed("\x1b[1;1H\x1b[6 q\x1b[31m", &session);
    _ = try renderer.shapeRow(&session.screen, 0);
    try t.expectEqual(shaped, renderer.shaped_rows);
    parser.feed("A", &session);
    _ = try renderer.shapeRow(&session.screen, 0);
    parser.feed("B", &session); // damage has deliberately not been acknowledged
    _ = try renderer.shapeRow(&session.screen, 0);
    try t.expectEqual(shaped + 2, renderer.shaped_rows);
    parser.feed("\x1b[?1049hother", &session);
    _ = try renderer.shapeRow(&session.screen, 0);
    parser.feed("\x1b[?1049l", &session);
    _ = try renderer.shapeRow(&session.screen, 0);
    try t.expectEqual(shaped + 4, renderer.shaped_rows);
}

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

test "PTY supplies initial and resized pixel geometry to image clients" {
    var pty = try Pty.spawnPixels(t.allocator, &.{ "/bin/sh", "-c", "read answer" }, 24, 80, 640, 384);
    defer pty.deinit();
    var size: c.winsize = undefined;
    try t.expectEqual(@as(c_int, 0), c.ioctl(pty.master, c.TIOCGWINSZ, &size));
    try t.expectEqual(@as(u16, 640), size.ws_xpixel);
    try t.expectEqual(@as(u16, 384), size.ws_ypixel);
    try pty.resizePixels(30, 100, 800, 480);
    try t.expectEqual(@as(c_int, 0), c.ioctl(pty.master, c.TIOCGWINSZ, &size));
    try t.expectEqual(@as(u16, 800), size.ws_xpixel);
    try t.expectEqual(@as(u16, 480), size.ws_ypixel);
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
        "\x1b[38;2;1;127;254;48:2::3:5:7m界e\xcc\x81👩‍💻🇮🇳",
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

test "deterministic fallback font renders color glyphs in CPU and GPU" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Mono", "tests/fonts");
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("A😀\x1b[?25l", &screen);
    const glyphs = try renderer.shapeRow(&screen, 0);
    var fallback = false;
    for (glyphs) |glyph| if (glyph.face != 0) {
        fallback = true;
    };
    try t.expect(fallback);
    const width = screen.columns * renderer.cell_width;
    const height = renderer.cell_height;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    try renderer.draw(&screen, pixels, width, height);
    var red = false;
    var green = false;
    for (pixels) |pixel| {
        red = red or pixel == 0xff0000;
        green = green or pixel == 0x00ff00;
    }
    try t.expect(red and green);
    var gpu = @import("renderer/Gpu.zig").initHeadless(t.allocator, width, height) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    _ = try damage.prepare(&screen, width, height, renderer.cell_height);
    try gpu.render(&renderer, &screen, &damage);
    try expectGpuPixels(&gpu, pixels);
}

test "true color channels reach the framebuffer without palette quantization" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Mono", "tests/fonts");
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 2);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[38;2;17;129;253;48:2::3:5:7mA\x1b[?25l", &screen);
    const width = renderer.cell_width * 2;
    const height = renderer.cell_height;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    try renderer.draw(&screen, pixels, width, height);
    var foreground = false;
    var background = false;
    for (pixels) |pixel| {
        foreground = foreground or pixel == 0x1181fd;
        background = background or pixel == 0x030507;
    }
    try t.expect(foreground and background);
}

test "bidi maps logical cells and resolves direction across soft-wrapped rows" {
    var renderer = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer renderer.deinit();
    renderer.bidi = true;
    var screen = try vt.Screen.init(t.allocator, 2, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("אבגד12", &screen);
    try t.expect(screen.soft_wrapped[0]);
    try t.expectEqual(@as(usize, 3), try renderer.visualColumn(&screen, 0, 0));
    try t.expectEqual(@as(usize, 0), try renderer.visualColumn(&screen, 0, 3));
    // The second line inherits the RTL paragraph direction despite starting with numbers.
    try t.expectEqual(@as(usize, 2), try renderer.visualColumn(&screen, 1, 0));
    const width = screen.columns * renderer.cell_width;
    const height = screen.rows * renderer.cell_height;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    try renderer.draw(&screen, pixels, width, height);
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
        try t.expectEqual(@as(usize, Renderer.Atlas.size * Renderer.Atlas.size * 4), page.pixels.len);
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
