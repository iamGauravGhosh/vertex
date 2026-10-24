//! CPU renderer into opaque XRGB8888 Wayland buffers.
const std = @import("std");
const c = @import("c");
const vt = @import("../terminal/root.zig");
const Renderer = @This();

pub const default_foreground: u32 = 0xd8dee9;
pub const default_background: u32 = 0x15171a;
const palette = [_]u32{
    0x2e3440, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
    0x4c566a, 0xd08770, 0xb5d99c, 0xffdf9e, 0x91b5d6, 0xc6a0c9, 0x9dd9e5, 0xffffff,
};

const Glyph = struct { mask: []u8, width: usize, height: usize, left: i32, top: i32 };
allocator: std.mem.Allocator,
library: c.FT_Library,
face: c.FT_Face,
cell_width: usize,
cell_height: usize,
ascent: i32,
scale: usize = 1,
glyphs: std.AutoHashMap(u32, Glyph),

pub fn init(allocator: std.mem.Allocator) !Renderer {
    const config = c.FcInitLoadConfigAndFonts() orelse return error.FontconfigFailed;
    defer c.FcConfigDestroy(config);
    const pattern = c.FcNameParse("monospace") orelse return error.FontconfigFailed;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(config, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);
    var match_result: c.FcResult = undefined;
    const match = c.FcFontMatch(config, pattern, &match_result) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(match);
    var filename: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &filename) != c.FcResultMatch) return error.FontNotFound;
    var library: c.FT_Library = null;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreetypeFailed;
    errdefer _ = c.FT_Done_FreeType(library);
    var face: c.FT_Face = null;
    if (c.FT_New_Face(library, @ptrCast(filename), 0, &face) != 0) return error.FontLoadFailed;
    errdefer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Pixel_Sizes(face, 0, 16) != 0) return error.FontSizeFailed;
    // max_advance can include double-width or fallback glyphs even in a mono
    // family. The normal Latin advance defines this scalar-per-cell grid.
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) != 0) return error.GlyphLoadFailed;
    const metrics = face.*.size.*.metrics;
    return .{
        .allocator = allocator,
        .library = library,
        .face = face,
        .cell_width = @intCast(@max(1, @divTrunc(face.*.glyph.*.advance.x + 63, 64))),
        .cell_height = @intCast(@max(1, @divTrunc(metrics.height + 63, 64))),
        .ascent = @intCast(@divTrunc(metrics.ascender + 63, 64)),
        .glyphs = std.AutoHashMap(u32, Glyph).init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    self.clearGlyphs();
    self.glyphs.deinit();
    _ = c.FT_Done_Face(self.face);
    _ = c.FT_Done_FreeType(self.library);
    self.* = undefined;
}

fn clearGlyphs(self: *Renderer) void {
    var values = self.glyphs.valueIterator();
    while (values.next()) |item| self.allocator.free(item.mask);
    self.glyphs.clearRetainingCapacity();
}

pub fn setScale(self: *Renderer, scale: usize) !void {
    if (scale == self.scale) return;
    if (c.FT_Set_Pixel_Sizes(self.face, 0, @intCast(16 * scale)) != 0) return error.FontSizeFailed;
    self.clearGlyphs();
    self.scale = scale;
}

fn glyph(self: *Renderer, codepoint: u21, style: vt.Style) !Glyph {
    const key = @as(u32, codepoint) | (@as(u32, @intFromBool(style.bold)) << 21) | (@as(u32, @intFromBool(style.italic)) << 22);
    if (self.glyphs.get(key)) |cached| return cached;
    var index = c.FT_Get_Char_Index(self.face, codepoint);
    if (index == 0) index = c.FT_Get_Char_Index(self.face, 0xfffd);
    if (c.FT_Load_Glyph(self.face, index, c.FT_LOAD_DEFAULT) != 0) return error.GlyphLoadFailed;
    const slot = self.face.*.glyph;
    if (style.bold) c.FT_GlyphSlot_Embolden(slot);
    if (style.italic) c.FT_GlyphSlot_Oblique(slot);
    if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return error.GlyphRenderFailed;
    const bitmap = slot.*.bitmap;
    const width: usize = bitmap.width;
    const height: usize = bitmap.rows;
    const mask = try self.allocator.alloc(u8, width * height);
    errdefer self.allocator.free(mask);
    const pitch: usize = @intCast(@abs(bitmap.pitch));
    for (0..height) |y| {
        const row = if (bitmap.pitch < 0) height - y - 1 else y;
        for (0..width) |x| {
            mask[y * width + x] = if (bitmap.pixel_mode == c.FT_PIXEL_MODE_MONO)
                (if ((bitmap.buffer[row * pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8))) != 0) @as(u8, 255) else 0)
            else
                bitmap.buffer[row * pitch + x];
        }
    }
    const result: Glyph = .{ .mask = mask, .width = width, .height = height, .left = slot.*.bitmap_left, .top = slot.*.bitmap_top };
    // Bound cache growth under streams containing arbitrary Unicode scalars.
    if (self.glyphs.count() >= 4096) self.clearGlyphs();
    try self.glyphs.put(key, result);
    return result;
}

pub fn draw(self: *Renderer, screen: *const vt.Screen, pixels: []u32, width: usize, height: usize) !void {
    std.debug.assert(pixels.len == width * height);
    @memset(pixels, default_background);
    const cw = self.cell_width * self.scale;
    const ch = self.cell_height * self.scale;
    const cursor = screen.getCursor();
    for (0..screen.rows) |row| {
        for (screen.getRow(row).?, 0..) |cell, column| {
            const x = column * cw;
            const y = row * ch;
            if (x >= width or y >= height) continue;
            const right = @min(width, x + cw);
            const bottom = @min(height, y + ch);
            var fg = color(cell.style.foreground, default_foreground);
            var bg = color(cell.style.background, default_background);
            if (cell.style.inverse) std.mem.swap(u32, &fg, &bg);
            if (cell.style.faint) fg = blend(fg, bg, 128);
            if (cursor.visible and cursor.row == row and cursor.column == column) std.mem.swap(u32, &fg, &bg);
            for (y..bottom) |py| @memset(pixels[py * width + x .. py * width + right], bg);
            if (cell.style.hidden) continue;
            if (cell.codepoint != ' ') {
                const bitmap = try self.glyph(cell.codepoint, cell.style);
                for (0..bitmap.height) |gy| {
                    const py = @as(i64, @intCast(y)) + self.ascent * @as(i64, @intCast(self.scale)) - bitmap.top + @as(i64, @intCast(gy));
                    if (py < y or py >= bottom) continue;
                    for (0..bitmap.width) |gx| {
                        const px = @as(i64, @intCast(x)) + bitmap.left + @as(i64, @intCast(gx));
                        if (px < x or px >= right) continue;
                        const offset = @as(usize, @intCast(py)) * width + @as(usize, @intCast(px));
                        pixels[offset] = blend(fg, bg, bitmap.mask[gy * bitmap.width + gx]);
                    }
                }
            }
            if (cell.style.underline or cell.style.strikethrough) {
                const baseline: usize = @intCast(@max(0, self.ascent));
                const line = y + @min(ch - 1, (if (cell.style.underline) baseline + 1 else baseline / 2) * self.scale);
                for (line..@min(bottom, line + self.scale)) |py| @memset(pixels[py * width + x .. py * width + right], fg);
                if (cell.style.underline and cell.style.strikethrough) {
                    const strike = y + @min(ch - 1, baseline / 2 * self.scale);
                    for (strike..@min(bottom, strike + self.scale)) |py| @memset(pixels[py * width + x .. py * width + right], fg);
                }
            }
        }
    }
}

pub fn color(value: vt.Color, default: u32) u32 {
    return switch (value) {
        .default => default,
        .rgb => |rgb| (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b,
        .indexed => |index| if (index < 16) palette[index] else if (index >= 232) @as(u32, 8 + (index - 232) * 10) * 0x010101 else cube: {
            const n: u32 = index - 16;
            const levels = [_]u32{ 0, 95, 135, 175, 215, 255 };
            break :cube (levels[n / 36] << 16) | (levels[n / 6 % 6] << 8) | levels[n % 6];
        },
    };
}

fn blend(fg: u32, bg: u32, alpha: u8) u32 {
    var result: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const a = (fg >> shift) & 255;
        const b = (bg >> shift) & 255;
        result |= ((a * alpha + b * (255 - @as(u32, alpha)) + 127) / 255) << shift;
    }
    return result;
}
