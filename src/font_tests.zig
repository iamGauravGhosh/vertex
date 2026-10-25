//! Font layout and pixel regressions, including a reproducible visual proof sheet.
const std = @import("std");
const t = std.testing;
const c = @import("c");
const Renderer = @import("renderer/root.zig");
const Gpu = @import("renderer/Gpu.zig");
const vt = @import("terminal/root.zig");

test "real font styles are selected before shaping and fractional sizes invalidate caches" {
    var renderer = try Renderer.initWithOptions(t.allocator, .{ .family = "Vertex Test Styled", .size = 13.25, .directory = "tests/fonts" });
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("A\x1b[1mA\x1b[22;3mA\x1b[1mA", &screen);
    for ([_]usize{ 1, 2, 1 }) |scale| {
        try renderer.setScale(scale);
        const glyphs = try renderer.shapeRow(&screen, 0);
        try t.expectEqual(@as(usize, 4), glyphs.len);
        for (glyphs, 0..) |g, variant| {
            const face = if (g.face == 0) renderer.face else renderer.faces.items[g.face - 1].face;
            try t.expectEqual(variant & 1 != 0, face.*.style_flags & c.FT_STYLE_FLAG_BOLD != 0);
            try t.expectEqual(variant & 2 != 0, face.*.style_flags & c.FT_STYLE_FLAG_ITALIC != 0);
            try bounds(&renderer, g);
        }
    }
    try t.expectError(error.FontSizeFailed, Renderer.initWithOptions(t.allocator, .{ .size = std.math.nan(f64) }));
}

test "icons borrow only an adjacent unstyled space and retain logical columns" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    defer renderer.deinit();
    var session = try vt.Session.init(t.allocator, 1, 2);
    defer session.deinit();
    const screen = &session.screen;
    var parser = vt.Parser.init();
    for ([_][]const u8{ "\u{e700} ", "\u{e700}A", "\u{e700}\x1b[44m ", "\u{e700} \u{301}", "\u{e700}\u{e700}", "\u{e700}\x1b]8;;https://example.com\x1b\\ \x1b]8;;\x1b\\" }, 0..) |text, step| {
        parser.feed("\x1bc\x1b[?25l", &session);
        parser.feed(text, &session);
        const glyphs = try renderer.shapeRow(screen, 0);
        try t.expectEqual(@as(usize, 1), glyphs[0].end);
        try t.expectEqual(@as(usize, if (step == 0) 2 else 1), glyphs[0].paint_end.?);
        for (glyphs) |g| try bounds(&renderer, g);
    }
    parser.feed("\x1bcA\u{e700}", &session);
    const last = (try renderer.shapeRow(screen, 0))[1];
    try t.expectEqual(@as(usize, 2), last.paint_end.?);
}

test "Unicode glyphs stay visible within their assigned rows and painted spans" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 8, 96);
    defer screen.deinit();
    var parser = vt.Parser.init();
    for (32..127) |cp| screen.handle(.{ .print = @intCast(cp) });
    parser.feed("\r\nA\u{301} café Ω Ж Ελληνικά Кириллица\r\n中文 日本語 한국어\r\nالعربية עברית\r\nहिन्दी தமிழ் বাংলা\r\n😀 👩‍💻 🇮🇳 1️⃣\r\n\u{e700} \u{f0001} \u{100001}\r\n\u{10fffc}\x1b[?25l", &screen);
    try t.expect(screen.takeError() == null);
    for ([_]usize{ 1, 2 }) |scale| {
        try renderer.setScale(scale);
        const width = screen.columns * renderer.cell_width * scale;
        const height = screen.rows * renderer.cell_height * scale;
        const pixels = try t.allocator.alloc(u32, width * height);
        defer t.allocator.free(pixels);
        try renderer.draw(&screen, pixels, width, height);
        for (0..screen.rows) |row| {
            for (try renderer.shapeRow(&screen, row)) |g| {
                try bounds(&renderer, g);
                if (g.width != 0 and g.height != 0) try t.expect(g.id != 0);
            }
        }
    }
}

fn bounds(renderer: *const Renderer, g: Renderer.PositionedGlyph) !void {
    if (g.width == 0 or g.height == 0) return;
    const cw = renderer.cell_width * renderer.scale;
    const ch = renderer.cell_height * renderer.scale;
    try t.expect(@divFloor(g.x, 64) >= g.column * cw);
    try t.expect(@divFloor(g.x, 64) + @as(i64, @intCast(g.width)) <= (g.paint_end orelse g.end) * cw);
    try t.expect(g.y >= 0);
    try t.expect(@divFloor(g.y, 64) + @as(i64, @intCast(g.height)) <= ch);
}

test "cell graphics expanded icons and neighboring edits match full CPU and GPU frames" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    defer renderer.deinit();
    var reference = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    defer reference.deinit();
    var screen = try vt.Screen.init(t.allocator, 5, 18);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[?25l\u{e700} A\r\n┌────┬────┐\r\n│████│▄▄▄▄│\r\n╰────┴────╯\r\n\u{e0b0}\u{e0b1}\u{e0b2}\u{e0b3} ⣿⠿ ░▒▓", &screen);
    const width = screen.columns * renderer.cell_width * 2;
    const height = screen.rows * renderer.cell_height * 2;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    @memset(pixels, Renderer.default_background);
    const expected = try t.allocator.alloc(u32, pixels.len);
    defer t.allocator.free(expected);
    var gpu = Gpu.initHeadless(t.allocator, width, height) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    for ([_][]const u8{ "", "\x1b[1;2HA", "\x1b[1;2H ", "\x1b[?25h\x1b[1;2H", "\x1b[1;2H\x1b[44m ", "\x1b[0m\x1b[?25l\x1b[1;1H A", "\x1b[1;1H\u{f0001} " }, 0..) |edit, step| {
        if (step == 4) {
            try renderer.setScale(2);
            try reference.setScale(2);
            damage.invalidate();
        }
        if (step == 6) {
            renderer.atlas.clear();
            damage.invalidate();
        }
        parser.feed(edit, &screen);
        _ = try damage.prepare(&screen, width, height, renderer.cell_height * renderer.scale);
        if (damage.full) @memset(pixels, Renderer.default_background);
        try renderer.drawRows(&screen, pixels, width, height, damage.rows);
        try reference.draw(&screen, expected, width, height);
        try t.expectEqualSlices(u32, expected, pixels);
        try gpu.render(&renderer, &screen, &damage);
        try expectGpuPixels(&gpu, expected);
        damage.commit(&screen);
    }
}

fn expectGpuPixels(gpu: *Gpu, expected: []const u32) !void {
    const rgba = try t.allocator.alloc(u8, expected.len * 4);
    defer t.allocator.free(rgba);
    try gpu.readPixels(rgba);
    for (expected, 0..) |rgb, i| {
        const offset = ((gpu.height - 1 - i / gpu.width) * gpu.width + i % gpu.width) * 4;
        inline for (.{ 16, 8, 0 }, 0..) |shift, channel| try t.expect(@abs(@as(i32, @intCast((rgb >> shift) & 255)) - rgba[offset + channel]) <= 1);
    }
}

test "optional installed font visual proof sheet" {
    const output = c.getenv("VERTEX_TEST_FONT_PREVIEW");
    if (output == null) return error.SkipZigTest;
    var renderer = try Renderer.initWithOptions(t.allocator, .{ .family = "JetBrainsMonoNL Nerd Font", .size = 13 });
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 24, 100);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[?25l\x1b[38;2;122;162;247m" ++
        "  ██╗      █████╗ ███████╗██╗   ██╗██╗   ██╗██╗███╗   ███╗\r\n" ++
        "  ██║     ██╔══██╗╚══███╔╝╚██╗ ██╔╝██║   ██║██║████╗ ████║\r\n" ++
        "  ██║     ███████║  ███╔╝  ╚████╔╝ ██║   ██║██║██╔████╔██║\r\n" ++
        "  ██║     ██╔══██║ ███╔╝    ╚██╔╝  ╚██╗ ██╔╝██║██║╚██╔╝██║\r\n" ++
        "  ███████╗██║  ██║███████╗   ██║    ╚████╔╝ ██║██║ ╚═╝ ██║\r\n" ++
        "  ╚══════╝╚═╝  ╚═╝╚══════╝   ╚═╝     ╚═══╝  ╚═╝╚═╝     ╚═╝\r\n\r\n" ++
        "\x1b[38;2;125;207;255m  \u{f002}  Find File      \u{f15b}  New File      \u{f013}  Config\r\n" ++
        "  \u{f07b}  vertex         \u{f0001}  Nerd Font    \u{e0b0}\u{e0b1}\u{e0b2}\u{e0b3}\r\n\r\n" ++
        "\x1b[0m  ASCII: ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789\r\n" ++
        "  !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~\r\n" ++
        "  Regular  \x1b[1mBold\x1b[22m  \x1b[3mItalic\x1b[1m  Bold Italic\x1b[0m\r\n" ++
        "  café A\u{301} Ω Ελληνικά Ж Кириллица 中文 日本語 한국어\r\n" ++
        "  हिन्दी தமிழ் বাংলা العربية עברית 😀 👩‍💻 🇮🇳\r\n" ++
        "  ┌──────────┬──────────┐   ╔══════════╦══════════╗\r\n" ++
        "  │ ▀▄█▌▐▖▗▘▝│ ░▒▓ ⣿⠿ │   ║ ▚▞▙▛▜▟   ║          ║\r\n" ++
        "  └──────────┴──────────┘   ╚══════════╩══════════╝\r\n" ++
        "  ╭──────────╮  ┏━━━━━━━━━━┓  ╱╲╳ ┄┅┆┇ ┈┉┊┋\r\n" ++
        "  ╰──────────╯  ┗━━━━━━━━━━┛\r\n", &screen);
    const width = screen.columns * renderer.cell_width;
    const height = screen.rows * renderer.cell_height;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    try renderer.draw(&screen, pixels, width, height);
    const fd = c.open(output, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.PreviewWriteFailed;
    defer _ = c.close(fd);
    const header = try std.fmt.allocPrint(t.allocator, "P6\n{d} {d}\n255\n", .{ width, height });
    defer t.allocator.free(header);
    try writeAll(fd, header);
    const rgb = try t.allocator.alloc(u8, pixels.len * 3);
    defer t.allocator.free(rgb);
    for (pixels, 0..) |pixel, i| {
        rgb[i * 3] = @truncate(pixel >> 16);
        rgb[i * 3 + 1] = @truncate(pixel >> 8);
        rgb[i * 3 + 2] = @truncate(pixel);
    }
    try writeAll(fd, rgb);
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return error.PreviewWriteFailed;
        offset += @intCast(n);
    }
}

test "ligatures default off toggle invalidates rows and preserves graphemes" {
    var renderer = try Renderer.initWithOptions(t.allocator, .{ .family = "Vertex Test Proportional", .directory = "tests/fonts", .features = &.{"liga=1"} });
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 6);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("iiA\u{301}界", &screen);
    const separate = try renderer.shapeRow(&screen, 0);
    try t.expectEqual(@as(usize, 1), separate[0].end);
    try t.expectEqual(@as(usize, 2), separate[1].end);
    const before = renderer.shaped_rows;
    renderer.setLigatures(true);
    const combined = try renderer.shapeRow(&screen, 0);
    try t.expectEqual(@as(usize, 2), combined[0].end);
    try t.expectEqual(before + 1, renderer.shaped_rows);
    renderer.setLigatures(false);
    try t.expectEqual(@as(usize, 1), (try renderer.shapeRow(&screen, 0))[0].end);
    try t.expectEqual(@as(usize, 2), screen.getGrapheme(0, 2).?.len);
    try t.expectEqual(@as(u2, 2), screen.getCell(0, 3).?.width);
}

test "alpha themes padding and incremental rendering agree between CPU and GPU" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    defer renderer.deinit();
    renderer.theme.foreground = 0xf08040;
    renderer.theme.background = 0x204060;
    renderer.theme.normal[1] = 0x40e080;
    renderer.origin_x = 7;
    renderer.origin_y = 11;
    var screen = try vt.Screen.init(t.allocator, 3, 12);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[?25lAi\u{301}\x1b[31mWO\r\n\x1b[44m  \x1b[0m", &screen);
    const width = 12 * renderer.cell_width + 19;
    const height = 3 * renderer.cell_height + 23;
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    const expected = try t.allocator.alloc(u32, pixels.len);
    defer t.allocator.free(expected);
    var gpu = Gpu.initHeadless(t.allocator, width, height) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    const rgba = try t.allocator.alloc(u8, pixels.len * 4);
    defer t.allocator.free(rgba);
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    damage.origin_y = renderer.origin_y;
    for ([_]f64{ 1, 0.5, 0, 0.75 }) |opacity| {
        renderer.background_opacity = opacity;
        damage.invalidate();
        for ([_][]const u8{ "", "\x1b[1;2HW", "\x1b[2;3Hi" }) |edit| {
            parser.feed(edit, &screen);
            _ = try damage.prepare(&screen, width, height, renderer.cell_height);
            if (damage.full) @memset(pixels, renderer.background());
            try renderer.drawRows(&screen, pixels, width, height, damage.rows);
            try renderer.draw(&screen, expected, width, height);
            try t.expectEqualSlices(u32, expected, pixels);
            try t.expectEqual(renderer.background(), pixels[0]);
            try t.expectEqual(renderer.background(), pixels[pixels.len - 1]);
            try gpu.render(&renderer, &screen, &damage);
            try gpu.readPixels(rgba);
            for (0..height) |y| for (0..width) |x| {
                const source = (height - 1 - y) * width * 4 + x * 4;
                const argb = pixels[y * width + x];
                for ([_]u5{ 16, 8, 0, 24 }, 0..) |shift, channel| {
                    const wanted: i32 = @intCast((argb >> shift) & 255);
                    try t.expect(@abs(wanted - @as(i32, rgba[source + channel])) <= 1);
                }
            };
            damage.commit(&screen);
        }
    }
}

test "programming contextual ligatures obey the toggle while Arabic required shaping survives" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 2);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("WW", &screen);
    try t.expectEqual(@as(usize, 1), (try renderer.shapeRow(&screen, 0))[0].end);
    renderer.setLigatures(true);
    try t.expectEqual(@as(usize, 2), (try renderer.shapeRow(&screen, 0))[0].end);
    var arabic = try Renderer.initFont(t.allocator, "DejaVu Sans");
    defer arabic.deinit();
    arabic.bidi = true;
    screen.reset();
    parser.feed("لا", &screen);
    const required = try arabic.shapeRow(&screen, 0);
    try t.expectEqual(@as(usize, 2), required[0].end);
    const id = required[0].id;
    arabic.setLigatures(true);
    const enabled = try arabic.shapeRow(&screen, 0);
    try t.expectEqual(@as(usize, 2), enabled[0].end);
    try t.expectEqual(id, enabled[0].id);
}

test "explicit style families override the regular font's style fallback" {
    var renderer = try Renderer.initWithOptions(t.allocator, .{
        .family = "Vertex Test Mono",
        .bold_family = "Vertex Test Styled",
        .italic_family = "Vertex Test Styled",
        .bold_italic_family = "Vertex Test Styled",
        .directory = "tests/fonts",
    });
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 3);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("\x1b[1mA\x1b[22;3mA\x1b[1mA", &screen);
    for (try renderer.shapeRow(&screen, 0)) |glyph| {
        try t.expect(glyph.face != 0);
        try t.expectEqualStrings("Vertex Test Styled", std.mem.span(renderer.faces.items[glyph.face - 1].face.*.family_name));
    }
}

test "replacing fonts invalidates retained GPU atlas textures" {
    var renderer = try Renderer.initFontDirectory(t.allocator, "Vertex Test Styled", "tests/fonts");
    defer renderer.deinit();
    var screen = try vt.Screen.init(t.allocator, 1, 4);
    defer screen.deinit();
    var parser = vt.Parser.init();
    parser.feed("AA\x1b[?25l", &screen);
    const width = renderer.cell_width * 4 + 20;
    const height = renderer.cell_height + 20;
    var gpu = Gpu.initHeadless(t.allocator, width, height) catch |err| {
        if (c.getenv("VERTEX_TEST_GPU") != null) return err;
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    _ = try damage.prepare(&screen, width, height, renderer.cell_height);
    try gpu.render(&renderer, &screen, &damage);
    const replacement = try Renderer.initFontDirectory(t.allocator, "Vertex Test Proportional", "tests/fonts");
    renderer.deinit();
    renderer = replacement;
    // Populate the new atlas on CPU first: page revision numbers can coincide.
    const pixels = try t.allocator.alloc(u32, width * height);
    defer t.allocator.free(pixels);
    try renderer.draw(&screen, pixels, width, height);
    gpu.invalidateAtlas();
    damage.invalidate();
    _ = try damage.prepare(&screen, width, height, renderer.cell_height);
    try gpu.render(&renderer, &screen, &damage);
    try expectGpuPixels(&gpu, pixels);
}
