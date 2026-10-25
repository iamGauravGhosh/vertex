//! Shared shaping, atlas rasterization, and CPU reference drawing.
const std = @import("std");
const c = @import("c");
const vt = @import("../terminal/root.zig");
pub const Atlas = @import("Atlas.zig");
pub const Damage = @import("Damage.zig");
const Renderer = @This();

pub const default_foreground: u32 = 0xd8dee9;
pub const default_background: u32 = 0x15171a;
const palette = [_]u32{
    0x2e3440, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
    0x4c566a, 0xd08770, 0xb5d99c, 0xffdf9e, 0x91b5d6, 0xc6a0c9, 0x9dd9e5, 0xffffff,
};
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const PositionedGlyph = struct {
    id: u32,
    column: usize,
    end: usize,
    x: i64,
    y: i64,
    style: vt.Style,
};
const Row = struct {
    cells: std.ArrayList(vt.Cell) = .empty,
    glyphs: std.ArrayList(PositionedGlyph) = .empty,
    valid: bool = false,
};
const Metrics = struct { width: usize, height: usize, left: i32, top: i32 };
allocator: std.mem.Allocator,
library: c.FT_Library,
face: c.FT_Face,
font: *c.hb_font_t,
buffer: *c.hb_buffer_t,
cell_width: usize,
cell_height: usize,
ascent: i32,
scale: usize = 1,
atlas: Atlas,
metrics: std.AutoHashMap(u64, Metrics),
rows: []Row = &.{},
shaped_rows: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Renderer {
    return initFont(allocator, "monospace");
}

/// An explicit Fontconfig pattern also permits deterministic font tests.
pub fn initFont(allocator: std.mem.Allocator, name: [:0]const u8) !Renderer {
    const config = c.FcInitLoadConfigAndFonts() orelse return error.FontconfigFailed;
    defer c.FcConfigDestroy(config);
    const pattern = c.FcNameParse(name.ptr) orelse return error.FontconfigFailed;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(config, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);
    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(config, pattern, &result) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(match);
    var filename: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &filename) != c.FcResultMatch) return error.FontNotFound;
    var library: c.FT_Library = null;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreetypeFailed;
    errdefer _ = c.FT_Done_FreeType(library);
    var face: c.FT_Face = null;
    var face_index: c_int = 0;
    _ = c.FcPatternGetInteger(match, c.FC_INDEX, 0, &face_index);
    if (c.FT_New_Face(library, @ptrCast(filename), face_index, &face) != 0) return error.FontLoadFailed;
    errdefer _ = c.FT_Done_Face(face);
    if (c.FT_Set_Pixel_Sizes(face, 0, 16) != 0) return error.FontSizeFailed;
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) != 0) return error.GlyphLoadFailed;
    const m = face.*.size.*.metrics;
    const font = c.hb_ft_font_create_referenced(face) orelse return error.OutOfMemory;
    errdefer c.hb_font_destroy(font);
    const buffer = c.hb_buffer_create() orelse return error.OutOfMemory;
    errdefer c.hb_buffer_destroy(buffer);
    if (c.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
    return .{
        .allocator = allocator,
        .library = library,
        .face = face,
        .font = font,
        .buffer = buffer,
        .cell_width = @intCast(@max(1, @divTrunc(face.*.glyph.*.advance.x + 63, 64))),
        .cell_height = @intCast(@max(1, @divTrunc(m.height + 63, 64))),
        .ascent = @intCast(@divTrunc(m.ascender + 63, 64)),
        .atlas = Atlas.init(allocator),
        .metrics = std.AutoHashMap(u64, Metrics).init(allocator),
    };
}

fn clearRows(self: *Renderer) void {
    for (self.rows) |*row| {
        row.cells.deinit(self.allocator);
        row.glyphs.deinit(self.allocator);
    }
    self.allocator.free(self.rows);
    self.rows = &.{};
}

pub fn deinit(self: *Renderer) void {
    self.clearRows();
    self.atlas.deinit();
    self.metrics.deinit();
    c.hb_buffer_destroy(self.buffer);
    c.hb_font_destroy(self.font);
    _ = c.FT_Done_Face(self.face);
    _ = c.FT_Done_FreeType(self.library);
    self.* = undefined;
}

pub fn setScale(self: *Renderer, scale: usize) !void {
    if (scale == self.scale) return;
    if (scale == 0 or scale > 1024) return error.FontSizeFailed;
    if (c.FT_Set_Pixel_Sizes(self.face, 0, @intCast(16 * scale)) != 0) return error.FontSizeFailed;
    c.hb_ft_font_changed(self.font);
    self.atlas.clear();
    self.metrics.clearRetainingCapacity();
    for (self.rows) |*row| row.valid = false;
    self.scale = scale;
}

fn scriptAt(cells: []const vt.Cell, at: usize, previous: c.hb_script_t) c.hb_script_t {
    const unicode = c.hb_unicode_funcs_get_default();
    const script = c.hb_unicode_script(unicode, cells[at].codepoint);
    if (script != c.HB_SCRIPT_COMMON and script != c.HB_SCRIPT_INHERITED and script != c.HB_SCRIPT_UNKNOWN) return script;
    if (previous != c.HB_SCRIPT_UNKNOWN) return previous;
    for (cells[at + 1 ..]) |cell| {
        const next = c.hb_unicode_script(unicode, cell.codepoint);
        if (next != c.HB_SCRIPT_COMMON and next != c.HB_SCRIPT_INHERITED and next != c.HB_SCRIPT_UNKNOWN) return next;
    }
    return c.HB_SCRIPT_LATIN;
}

pub fn shapeRow(self: *Renderer, screen: *const vt.Screen, index: usize) ![]const PositionedGlyph {
    if (self.rows.len != screen.rows) {
        const replacement = try self.allocator.alloc(Row, screen.rows);
        @memset(replacement, .{});
        self.clearRows();
        self.rows = replacement;
    }
    const row = &self.rows[index];
    const cells = screen.getRow(index).?;
    if (row.valid and row.cells.items.len == cells.len) {
        var equal = true;
        for (cells, row.cells.items) |a, b| if (!std.meta.eql(a, b)) {
            equal = false;
            break;
        };
        if (equal) return row.glyphs.items;
    }
    row.valid = false;
    row.glyphs.clearRetainingCapacity();
    var start: usize = 0;
    var previous: c.hb_script_t = c.HB_SCRIPT_UNKNOWN;
    while (start < cells.len) {
        const script = scriptAt(cells, start, previous);
        previous = script;
        var end = start + 1;
        while (end < cells.len and std.meta.eql(cells[end].style, cells[start].style) and scriptAt(cells, end, script) == script) : (end += 1) {}
        c.hb_buffer_reset(self.buffer);
        c.hb_buffer_set_content_type(self.buffer, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
        c.hb_buffer_set_direction(self.buffer, c.HB_DIRECTION_LTR);
        c.hb_buffer_set_script(self.buffer, script);
        c.hb_buffer_set_language(self.buffer, c.hb_language_from_string("und", -1));
        c.hb_buffer_set_cluster_level(self.buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
        for (cells[start..end], start..) |cell, column| {
            const cp: u32 = if (c.FT_Get_Char_Index(self.face, cell.codepoint) == 0) 0xfffd else cell.codepoint;
            c.hb_buffer_add(self.buffer, cp, @intCast(column));
        }
        c.hb_shape(self.font, self.buffer, null, 0);
        if (c.hb_buffer_allocation_successful(self.buffer) == 0) return error.OutOfMemory;
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(self.buffer, &count);
        var i: usize = 0;
        while (i < count) {
            const column: usize = infos[i].cluster;
            var next = i + 1;
            while (next < count and infos[next].cluster == column) : (next += 1) {}
            const cluster_end: usize = if (next < count) infos[next].cluster else end;
            var pen: i64 = 0;
            for (i..next) |j| {
                try row.glyphs.append(self.allocator, .{
                    .id = infos[j].codepoint,
                    .column = column,
                    .end = cluster_end,
                    .x = @as(i64, @intCast(column * self.cell_width * self.scale)) * 64 + pen + positions[j].x_offset,
                    .y = -@as(i64, positions[j].y_offset),
                    .style = cells[start].style,
                });
                pen += positions[j].x_advance;
            }
            i = next;
        }
        start = end;
    }
    try row.cells.resize(self.allocator, cells.len);
    @memcpy(row.cells.items, cells);
    row.valid = true;
    self.shaped_rows += 1;
    return row.glyphs.items;
}

fn load(self: *Renderer, id: u32, style: vt.Style) !Metrics {
    if (c.FT_Load_Glyph(self.face, id, c.FT_LOAD_DEFAULT) != 0) return error.GlyphLoadFailed;
    const slot = self.face.*.glyph;
    if (style.bold) c.FT_GlyphSlot_Embolden(slot);
    if (style.italic) c.FT_GlyphSlot_Oblique(slot);
    if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return error.GlyphRenderFailed;
    return .{ .width = slot.*.bitmap.width, .height = slot.*.bitmap.rows, .left = slot.*.bitmap_left, .top = slot.*.bitmap_top };
}

pub fn colors(style: vt.Style, cursor: bool) struct { fg: u32, bg: u32 } {
    var fg = color(style.foreground, default_foreground);
    var bg = color(style.background, default_background);
    if (style.inverse) std.mem.swap(u32, &fg, &bg);
    if (style.faint) fg = blend(fg, bg, 128);
    if (cursor) std.mem.swap(u32, &fg, &bg);
    return .{ .fg = fg, .bg = bg };
}

/// Shared draw traversal; painters provide fill, mask, upload, and flush.
pub fn paint(self: *Renderer, screen: *const vt.Screen, dirty: []const bool, painter: anytype) !void {
    const cw = self.cell_width * self.scale;
    const ch = self.cell_height * self.scale;
    const cursor = screen.getCursor();
    for (dirty, 0..) |changed, row| {
        if (!changed) continue;
        const y: i32 = @intCast(row * ch);
        try painter.fill(.{ .x = 0, .y = y, .width = @intCast(painter.width), .height = @intCast(ch) }, default_background);
        const cells = screen.getRow(row).?;
        for (cells, 0..) |cell, col| {
            const rgb = colors(cell.style, cursor.visible and cursor.row == row and cursor.column == col);
            const x: i32 = @intCast(col * cw);
            try painter.fill(.{ .x = x, .y = y, .width = @intCast(cw), .height = @intCast(ch) }, rgb.bg);
        }
        const glyphs = try self.shapeRow(screen, row);
        for (glyphs) |g| {
            if (g.style.hidden) continue;
            const key = @as(u64, g.id) | (@as(u64, @intFromBool(g.style.bold)) << 32) | (@as(u64, @intFromBool(g.style.italic)) << 33);
            var loaded = false;
            const m = self.metrics.get(key) orelse blk: {
                const m = try self.load(g.id, g.style);
                loaded = true;
                if (self.metrics.count() >= 4096) self.metrics.clearRetainingCapacity();
                try self.metrics.put(key, m);
                break :blk m;
            };
            var ty: usize = 0;
            while (ty < m.height) : (ty += Atlas.tile_size) {
                var tx: usize = 0;
                while (tx < m.width) : (tx += Atlas.tile_size) {
                    const tile_key: Atlas.Key = .{ .glyph = key, .x = @intCast(tx), .y = @intCast(ty) };
                    const region = self.atlas.get(tile_key) orelse blk: {
                        if (!loaded) {
                            _ = try self.load(g.id, g.style);
                            loaded = true;
                        }
                        const bitmap = self.face.*.glyph.*.bitmap;
                        const tw: usize = @min(Atlas.tile_size, m.width - tx);
                        const th: usize = @min(Atlas.tile_size, m.height - ty);
                        // Only a bounded tile scratch buffer, including for very large glyphs.
                        const scratch = try self.allocator.alloc(u8, tw * th);
                        defer self.allocator.free(scratch);
                        const pitch: usize = @intCast(@abs(bitmap.pitch));
                        for (0..th) |by| {
                            const sy = if (bitmap.pitch < 0) m.height - 1 - (ty + by) else ty + by;
                            for (0..tw) |bx| {
                                const sx = tx + bx;
                                scratch[by * tw + bx] = switch (bitmap.pixel_mode) {
                                    c.FT_PIXEL_MODE_MONO => if ((bitmap.buffer[sy * pitch + sx / 8] & (@as(u8, 0x80) >> @intCast(sx % 8))) != 0) 255 else 0,
                                    c.FT_PIXEL_MODE_GRAY => bitmap.buffer[sy * pitch + sx],
                                    else => return error.UnsupportedGlyphBitmap,
                                };
                            }
                        }
                        try painter.flush();
                        const region = try self.atlas.insert(tile_key, tw, th, scratch, tw);
                        try painter.upload(&self.atlas, region);
                        break :blk region;
                    };
                    const dx: i32 = @intCast(@divFloor(g.x, 64) + m.left + @as(i64, @intCast(tx)));
                    const dy: i32 = @intCast(y + self.ascent * @as(i32, @intCast(self.scale)) - m.top + @divFloor(g.y, 64) + @as(i64, @intCast(ty)));
                    // Per-cell clips preserve cursor colors even inside a single ligature.
                    for (g.column..g.end) |col| {
                        const rgb = colors(g.style, cursor.visible and cursor.row == row and cursor.column == col);
                        try painter.mask(&self.atlas, region, dx, dy, .{ .x = @intCast(col * cw), .y = y, .width = @intCast(cw), .height = @intCast(ch) }, rgb.fg);
                    }
                }
            }
        }
        for (cells, 0..) |cell, col| {
            if (cell.style.hidden) continue;
            const rgb = colors(cell.style, cursor.visible and cursor.row == row and cursor.column == col);
            const x: i32 = @intCast(col * cw);
            const baseline: usize = @intCast(@max(0, self.ascent));
            if (cell.style.underline) {
                const line = @min(ch - 1, (baseline + 1) * self.scale);
                try painter.fill(.{ .x = x, .y = y + @as(i32, @intCast(line)), .width = @intCast(cw), .height = @intCast(@min(self.scale, ch - line)) }, rgb.fg);
            }
            if (cell.style.strikethrough) {
                const line = @min(ch - 1, baseline / 2 * self.scale);
                try painter.fill(.{ .x = x, .y = y + @as(i32, @intCast(line)), .width = @intCast(cw), .height = @intCast(@min(self.scale, ch - line)) }, rgb.fg);
            }
        }
    }
    try painter.flush();
}

pub fn drawRows(self: *Renderer, screen: *const vt.Screen, pixels: []u32, width: usize, height: usize, dirty: []const bool) !void {
    std.debug.assert(pixels.len == width * height);
    var painter: Cpu = .{ .pixels = pixels, .width = width, .height = height };
    try self.paint(screen, dirty, &painter);
}

pub fn draw(self: *Renderer, screen: *const vt.Screen, pixels: []u32, width: usize, height: usize) !void {
    @memset(pixels, default_background);
    const dirty = try self.allocator.alloc(bool, screen.rows);
    defer self.allocator.free(dirty);
    @memset(dirty, true);
    try self.drawRows(screen, pixels, width, height, dirty);
}

pub fn intersect(a: Rect, b: Rect) Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return .{ .x = x, .y = y, .width = @max(0, @min(a.x + a.width, b.x + b.width) - x), .height = @max(0, @min(a.y + a.height, b.y + b.height) - y) };
}

pub const Cpu = struct {
    pixels: []u32,
    width: usize,
    height: usize,
    pub fn flush(_: *Cpu) !void {}
    pub fn upload(_: *Cpu, _: *Atlas, _: Atlas.Region) !void {}
    fn bounds(self: *Cpu) Rect {
        return .{ .x = 0, .y = 0, .width = @intCast(self.width), .height = @intCast(self.height) };
    }
    pub fn fill(self: *Cpu, rect: Rect, rgb: u32) !void {
        const r = intersect(rect, self.bounds());
        if (r.width == 0 or r.height == 0) return;
        for (@intCast(r.y)..@intCast(r.y + r.height)) |y| @memset(self.pixels[y * self.width + @as(usize, @intCast(r.x)) ..][0..@intCast(r.width)], rgb);
    }
    pub fn mask(self: *Cpu, atlas: *Atlas, region: Atlas.Region, x: i32, y: i32, clip: Rect, rgb: u32) !void {
        const r = intersect(intersect(.{ .x = x, .y = y, .width = @intCast(region.width), .height = @intCast(region.height) }, clip), self.bounds());
        if (r.width == 0 or r.height == 0) return;
        for (@as(usize, @intCast(r.y))..@intCast(r.y + r.height)) |py| {
            for (@as(usize, @intCast(r.x))..@intCast(r.x + r.width)) |px| {
                const ax = region.x + @as(usize, @intCast(@as(i64, @intCast(px)) - x));
                const ay = region.y + @as(usize, @intCast(@as(i64, @intCast(py)) - y));
                const offset = py * self.width + px;
                self.pixels[offset] = blend(rgb, self.pixels[offset], atlas.pages[region.page].pixels[ay * Atlas.size + ax]);
            }
        }
    }
};

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

test {
    _ = Atlas;
    _ = Damage;
}
