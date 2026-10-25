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
    face: usize = 0,
    column: usize,
    end: usize,
    x: i64,
    y: i64,
    style: vt.Style,
};
const Face = struct { face: c.FT_Face, font: *c.hb_font_t, index: usize };
const Row = struct {
    fingerprint: u64 = 0,
    visual: std.ArrayList(usize) = .empty,
    cells: std.ArrayList(vt.Cell) = .empty,
    glyphs: std.ArrayList(PositionedGlyph) = .empty,
    valid: bool = false,
};
const Metrics = struct { width: usize, height: usize, left: i32, top: i32 };
allocator: std.mem.Allocator,
library: c.FT_Library,
face: c.FT_Face,
font: *c.hb_font_t,
fallbacks: *c.FcFontSet,
faces: std.ArrayList(Face) = .empty,
bidi: bool = false,
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
    return initFontDirectory(allocator, name, null);
}

/// Additional application fonts make rendering tests independent of installed fonts.
pub fn initFontDirectory(allocator: std.mem.Allocator, name: [:0]const u8, directory: ?[:0]const u8) !Renderer {
    const config = c.FcInitLoadConfigAndFonts() orelse return error.FontconfigFailed;
    defer c.FcConfigDestroy(config);
    if (directory) |path| if (c.FcConfigAppFontAddDir(config, @ptrCast(path)) == 0) return error.FontNotFound;
    const pattern = c.FcNameParse(name.ptr) orelse return error.FontconfigFailed;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(config, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);
    var result: c.FcResult = undefined;
    const fallbacks = c.FcFontSort(config, pattern, c.FcTrue, null, &result) orelse return error.FontNotFound;
    errdefer c.FcFontSetDestroy(fallbacks);
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
        .fallbacks = fallbacks,
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
        row.visual.deinit(self.allocator);
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
    for (self.faces.items) |face| {
        c.hb_font_destroy(face.font);
        _ = c.FT_Done_Face(face.face);
    }
    self.faces.deinit(self.allocator);
    c.FcFontSetDestroy(self.fallbacks);
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
    for (self.faces.items) |face| {
        try sizeFace(face.face, 16 * scale);
        c.hb_ft_font_changed(face.font);
    }
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

fn sizeFace(face: c.FT_Face, pixels: usize) !void {
    if (c.FT_Set_Pixel_Sizes(face, 0, @intCast(pixels)) == 0) return;
    if (face.*.num_fixed_sizes == 0) return error.FontSizeFailed;
    var best: c_int = 0;
    for (0..@intCast(face.*.num_fixed_sizes)) |i| {
        if (@abs(@as(i64, face.*.available_sizes[i].y_ppem) - @as(i64, @intCast(pixels * 64))) < @abs(@as(i64, face.*.available_sizes[@intCast(best)].y_ppem) - @as(i64, @intCast(pixels * 64)))) best = @intCast(i);
    }
    if (c.FT_Select_Size(face, best) != 0) return error.FontSizeFailed;
}
fn supports(face: c.FT_Face, cluster: []const u21) bool {
    for (cluster) |cp| {
        if (cp == 0x200d or cp == 0x200c or (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xe0020 and cp <= 0xe007f)) continue;
        if (c.FT_Get_Char_Index(face, cp) == 0) return false;
    }
    return true;
}
fn faceFor(self: *Renderer, cluster: []const u21) !usize {
    var emoji = false;
    for (cluster) |cp| if (cp == 0xfe0f or cp >= 0x1f000) {
        emoji = true;
    };
    if (!emoji and supports(self.face, cluster)) return 0;
    for (self.faces.items, 0..) |face, i| if (supports(face.face, cluster) and (!emoji or face.face.*.face_flags & c.FT_FACE_FLAG_COLOR != 0)) return i + 1;
    for (0..@intCast(self.fallbacks.nfont)) |i| {
        const pattern = self.fallbacks.fonts[i];
        var charset: ?*c.FcCharSet = null;
        if (c.FcPatternGetCharSet(pattern, c.FC_CHARSET, 0, &charset) != c.FcResultMatch) continue;
        var supported = true;
        for (cluster) |cp| {
            if (cp == 0x200d or cp == 0x200c or (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xe0020 and cp <= 0xe007f)) continue;
            if (c.FcCharSetHasChar(charset, cp) == 0) {
                supported = false;
                break;
            }
        }
        if (!supported) continue;
        if (emoji) {
            var is_color: c.FcBool = 0;
            if (c.FcPatternGetBool(pattern, c.FC_COLOR, 0, &is_color) != c.FcResultMatch or is_color == 0) continue;
        }
        for (self.faces.items, 0..) |face, j| if (face.index == i) return j + 1;
        var filename: [*c]c.FcChar8 = null;
        var index: c_int = 0;
        if (c.FcPatternGetString(pattern, c.FC_FILE, 0, &filename) != c.FcResultMatch) continue;
        _ = c.FcPatternGetInteger(pattern, c.FC_INDEX, 0, &index);
        var face: c.FT_Face = null;
        if (c.FT_New_Face(self.library, @ptrCast(filename), index, &face) != 0) continue;
        errdefer _ = c.FT_Done_Face(face);
        sizeFace(face, 16 * self.scale) catch {
            _ = c.FT_Done_Face(face);
            continue;
        };
        const font = c.hb_ft_font_create_referenced(face) orelse return error.OutOfMemory;
        errdefer c.hb_font_destroy(font);
        try self.faces.append(self.allocator, .{ .face = face, .font = font, .index = i });
        return self.faces.items.len;
    }
    // A monochrome glyph is preferable to a replacement when no color face exists.
    if (supports(self.face, cluster)) return 0;
    for (self.faces.items, 0..) |face, i| if (supports(face.face, cluster)) return i + 1;
    if (emoji) {
        // Retry Fontconfig without the color preference.
        const plain = try self.allocator.dupe(u21, cluster);
        defer self.allocator.free(plain);
        for (plain) |*cp| if (cp.* == 0xfe0f) {
            cp.* = 0xfe0e;
        };
        // The general search below does not apply a color requirement.
        for (0..@intCast(self.fallbacks.nfont)) |i| {
            var charset: ?*c.FcCharSet = null;
            if (c.FcPatternGetCharSet(self.fallbacks.fonts[i], c.FC_CHARSET, 0, &charset) != c.FcResultMatch) continue;
            var ok = true;
            for (plain) |cp| if (cp != 0xfe0e and cp != 0x200d and c.FcCharSetHasChar(charset, cp) == 0) {
                ok = false;
                break;
            };
            if (!ok) continue;
            var filename: [*c]c.FcChar8 = null;
            var index: c_int = 0;
            _ = c.FcPatternGetInteger(self.fallbacks.fonts[i], c.FC_INDEX, 0, &index);
            if (c.FcPatternGetString(self.fallbacks.fonts[i], c.FC_FILE, 0, &filename) != c.FcResultMatch) continue;
            var face: c.FT_Face = null;
            if (c.FT_New_Face(self.library, @ptrCast(filename), index, &face) != 0) continue;
            errdefer _ = c.FT_Done_Face(face);
            sizeFace(face, 16 * self.scale) catch {
                _ = c.FT_Done_Face(face);
                continue;
            };
            const font = c.hb_ft_font_create_referenced(face) orelse return error.OutOfMemory;
            errdefer c.hb_font_destroy(font);
            try self.faces.append(self.allocator, .{ .face = face, .font = font, .index = i });
            return self.faces.items.len;
        }
    }
    return 0;
}
fn fontFace(self: *Renderer, index: usize) Face {
    return if (index == 0) .{ .face = self.face, .font = self.font, .index = 0 } else self.faces.items[index - 1];
}
const Paragraph = struct { first: usize, last: usize };
fn paragraph(screen: *const vt.Screen, row: usize) Paragraph {
    var first = row;
    while (first > 0 and screen.soft_wrapped[first - 1]) first -= 1;
    var last = row + 1;
    while (last < screen.rows and screen.soft_wrapped[last - 1]) last += 1;
    return .{ .first = first, .last = last };
}
fn resolveBidi(self: *Renderer, screen: *const vt.Screen, row: usize, output_levels: []c.FriBidiLevel, visual: []usize) !void {
    const bounds = paragraph(screen, row);
    var chars: std.ArrayList(c.FriBidiChar) = .empty;
    defer chars.deinit(self.allocator);
    var columns: std.ArrayList(usize) = .empty;
    defer columns.deinit(self.allocator);
    var line_start: usize = 0;
    var line_end: usize = 0;
    for (bounds.first..bounds.last) |r| {
        if (r == row) line_start = chars.items.len;
        for (screen.getRow(r).?, 0..) |cell, col| {
            if (cell.width == 0) continue;
            for (screen.getGrapheme(r, col).?) |cp| {
                try chars.append(self.allocator, cp);
                try columns.append(self.allocator, col);
            }
        }
        if (r == row) line_end = chars.items.len;
    }
    if (chars.items.len == 0) return;
    const types = try self.allocator.alloc(c.FriBidiCharType, chars.items.len);
    defer self.allocator.free(types);
    const brackets = try self.allocator.alloc(c.FriBidiBracketType, chars.items.len);
    defer self.allocator.free(brackets);
    const levels = try self.allocator.alloc(c.FriBidiLevel, chars.items.len);
    defer self.allocator.free(levels);
    const map = try self.allocator.alloc(c.FriBidiStrIndex, chars.items.len);
    defer self.allocator.free(map);
    for (map, 0..) |*entry, i| entry.* = @intCast(i);
    c.fribidi_get_bidi_types(chars.items.ptr, @intCast(chars.items.len), types.ptr);
    c.fribidi_get_bracket_types(chars.items.ptr, @intCast(chars.items.len), types.ptr, brackets.ptr);
    var direction: c.FriBidiParType = c.FRIBIDI_PAR_ON;
    if (c.fribidi_get_par_embedding_levels_ex(types.ptr, brackets.ptr, @intCast(chars.items.len), &direction, levels.ptr) == 0) return error.OutOfMemory;
    if (c.fribidi_reorder_line(0, types.ptr, @intCast(line_end - line_start), @intCast(line_start), direction, levels.ptr, null, map.ptr) == 0) return error.OutOfMemory;
    const seen = try self.allocator.alloc(bool, screen.columns);
    defer self.allocator.free(seen);
    @memset(seen, false);
    var next: usize = 0;
    for (map[line_start..line_end]) |logical| {
        const scalar: usize = @intCast(logical);
        const col = columns.items[scalar];
        if (seen[col]) continue;
        seen[col] = true;
        visual[col] = next;
        const cell = screen.getCell(row, col).?;
        output_levels[col] = levels[scalar];
        if (cell.width == 2) {
            visual[col + 1] = next + 1;
            output_levels[col + 1] = levels[scalar];
        }
        next += cell.width;
    }
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
    var hash = std.hash.Wyhash.init(0);
    const bounds: Paragraph = if (self.bidi) paragraph(screen, index) else .{ .first = index, .last = index + 1 };
    for (screen.cells[bounds.first * screen.columns .. bounds.last * screen.columns]) |cell| {
        std.hash.autoHash(&hash, cell.codepoint);
        std.hash.autoHash(&hash, cell.width);
        std.hash.autoHash(&hash, cell.style);
        hash.update(std.mem.sliceAsBytes(cell.grapheme));
    }
    std.hash.autoHash(&hash, self.bidi);
    std.hash.autoHash(&hash, bounds.first);
    std.hash.autoHash(&hash, bounds.last);
    std.hash.autoHash(&hash, index);
    const fingerprint = hash.final();
    if (row.valid and row.fingerprint == fingerprint) return row.glyphs.items;
    row.valid = false;
    row.glyphs.clearRetainingCapacity();
    try row.visual.resize(self.allocator, cells.len);
    for (row.visual.items, 0..) |*col, i| col.* = i;
    const levels = try self.allocator.alloc(c.FriBidiLevel, cells.len);
    defer self.allocator.free(levels);
    @memset(levels, 0);
    if (self.bidi) try self.resolveBidi(screen, index, levels, row.visual.items);
    var start: usize = 0;
    var previous: c.hb_script_t = c.HB_SCRIPT_UNKNOWN;
    while (start < cells.len) {
        if (cells[start].width == 0) {
            start += 1;
            continue;
        }
        const script = scriptAt(cells, start, previous);
        previous = script;
        const face_index = try self.faceFor(screen.getGrapheme(index, start).?);
        const selected = self.fontFace(face_index);
        const rtl = @mod(levels[start], 2) == 1;
        var end = start + cells[start].width;
        while (end < cells.len) {
            if (cells[end].width == 0) {
                end += 1;
                continue;
            }
            if (!std.meta.eql(cells[end].style, cells[start].style) or scriptAt(cells, end, script) != script or @mod(levels[end], 2) != @mod(levels[start], 2) or try self.faceFor(screen.getGrapheme(index, end).?) != face_index) break;
            end += cells[end].width;
        }
        c.hb_buffer_reset(self.buffer);
        c.hb_buffer_set_content_type(self.buffer, c.HB_BUFFER_CONTENT_TYPE_UNICODE);
        c.hb_buffer_set_direction(self.buffer, if (rtl) c.HB_DIRECTION_RTL else c.HB_DIRECTION_LTR);
        c.hb_buffer_set_script(self.buffer, script);
        c.hb_buffer_set_language(self.buffer, c.hb_language_from_string("und", -1));
        c.hb_buffer_set_cluster_level(self.buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
        for (start..end) |column| {
            if (cells[column].width == 0) continue;
            for (screen.getGrapheme(index, column).?) |cp| {
                const replacement: u32 = if (c.FT_Get_Char_Index(selected.face, cp) == 0 and vt.Unicode.scalarWidth(cp) != 0 and !(cp >= 0x200b and cp <= 0x200f) and !(cp >= 0x202a and cp <= 0x202e) and !(cp >= 0x2060 and cp <= 0x206f)) 0xfffd else cp;
                c.hb_buffer_add(self.buffer, replacement, @intCast(column));
            }
        }
        c.hb_shape(selected.font, self.buffer, null, 0);
        if (c.hb_buffer_allocation_successful(self.buffer) == 0) return error.OutOfMemory;
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(self.buffer, &count);
        var i: usize = 0;
        while (i < count) {
            const column: usize = infos[i].cluster;
            var next = i + 1;
            while (next < count and infos[next].cluster == column) : (next += 1) {}
            const cluster_end: usize = if (rtl) (if (i == 0) end else infos[i - 1].cluster) else if (next < count) infos[next].cluster else end;
            var visual = row.visual.items[column];
            for (column..@max(column + cells[column].width, cluster_end)) |col| visual = @min(visual, row.visual.items[col]);
            var pen: i64 = 0;
            const numerator: i64 = if (selected.face.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0) @intCast(16 * self.scale) else 1;
            const denominator: i64 = if (numerator != 1) @max(1, selected.face.*.size.*.metrics.y_ppem) else 1;
            for (i..next) |j| {
                try row.glyphs.append(self.allocator, .{
                    .id = infos[j].codepoint,
                    .face = face_index,
                    .column = column,
                    .end = @max(column + cells[column].width, cluster_end),
                    .x = @as(i64, @intCast(visual * self.cell_width * self.scale)) * 64 + pen + @divTrunc(@as(i64, positions[j].x_offset) * numerator, denominator),
                    .y = -@divTrunc(@as(i64, positions[j].y_offset) * numerator, denominator),
                    .style = cells[start].style,
                });
                pen += @divTrunc(@as(i64, positions[j].x_advance) * numerator, denominator);
            }
            i = next;
        }
        start = end;
    }
    row.fingerprint = fingerprint;
    row.valid = true;
    self.shaped_rows += 1;
    return row.glyphs.items;
}
pub fn visualColumn(self: *Renderer, screen: *const vt.Screen, row: usize, column: usize) !usize {
    _ = try self.shapeRow(screen, row);
    return self.visualCached(screen, row, column);
}
fn visualCached(self: *const Renderer, screen: *const vt.Screen, row: usize, column: usize) usize {
    const head = if (screen.getCell(row, column).?.width == 0 and column > 0) column - 1 else column;
    return self.rows[row].visual.items[head] + column - head;
}

fn load(self: *Renderer, face_index: usize, id: u32, style: vt.Style) !Metrics {
    const face = self.fontFace(face_index).face;
    if (c.FT_Load_Glyph(face, id, c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR | c.FT_LOAD_NO_SVG) != 0) {
        if (c.FT_Load_Glyph(face, id, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_SVG) != 0) return error.GlyphLoadFailed;
    }
    const slot = face.*.glyph;
    if (style.bold and slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) c.FT_GlyphSlot_Embolden(slot);
    if (style.italic and slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) c.FT_GlyphSlot_Oblique(slot);
    if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) {
        // Unsupported color formats may still have a usable monochrome outline.
        if (c.FT_Load_Glyph(face, id, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_SVG) != 0 or c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) {
            if (c.FT_Load_Char(face, 0xfffd, c.FT_LOAD_RENDER | c.FT_LOAD_NO_SVG) != 0) return .{ .width = 0, .height = 0, .left = 0, .top = 0 };
        }
    }
    const numerator: usize = if (face.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0) 16 * self.scale else 1;
    const denominator: usize = if (numerator != 1) @max(1, face.*.size.*.metrics.y_ppem) else 1;
    return .{ .width = (slot.*.bitmap.width * numerator + denominator - 1) / denominator, .height = (slot.*.bitmap.rows * numerator + denominator - 1) / denominator, .left = @intCast(@divTrunc(@as(i64, slot.*.bitmap_left) * @as(i64, @intCast(numerator)), @as(i64, @intCast(denominator)))), .top = @intCast(@divTrunc(@as(i64, slot.*.bitmap_top) * @as(i64, @intCast(numerator)), @as(i64, @intCast(denominator)))) };
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
        const glyphs = try self.shapeRow(screen, row);
        for (cells, 0..) |cell, col| {
            const rgb = colors(cell.style, cursor.visible and cursor.row == row and cursor.column == col);
            const x: i32 = @intCast(self.visualCached(screen, row, col) * cw);
            try painter.fill(.{ .x = x, .y = y, .width = @intCast(cw), .height = @intCast(ch) }, rgb.bg);
        }
        for (glyphs) |g| {
            if (g.style.hidden) continue;
            const key = (@as(u64, @intCast(g.face)) << 40) | @as(u64, g.id) | (@as(u64, @intFromBool(g.style.bold)) << 32) | (@as(u64, @intFromBool(g.style.italic)) << 33);
            var loaded = false;
            const m = self.metrics.get(key) orelse blk: {
                const m = try self.load(g.face, g.id, g.style);
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
                            _ = try self.load(g.face, g.id, g.style);
                            loaded = true;
                        }
                        const bitmap = self.fontFace(g.face).face.*.glyph.*.bitmap;
                        const tw: usize = @min(Atlas.tile_size, m.width - tx);
                        const th: usize = @min(Atlas.tile_size, m.height - ty);
                        // Only a bounded tile scratch buffer, including for very large glyphs.
                        const is_color = bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA;
                        const channels: usize = if (is_color) 4 else 1;
                        const scratch = try self.allocator.alloc(u8, tw * th * channels);
                        defer self.allocator.free(scratch);
                        const pitch: usize = @intCast(@abs(bitmap.pitch));
                        for (0..th) |by| {
                            const original_y = (ty + by) * bitmap.rows / m.height;
                            const sy = if (bitmap.pitch < 0) bitmap.rows - 1 - original_y else original_y;
                            for (0..tw) |bx| {
                                const sx = (tx + bx) * bitmap.width / m.width;
                                if (is_color) {
                                    const source = bitmap.buffer[sy * pitch + sx * 4 ..][0..4];
                                    const target = scratch[(by * tw + bx) * 4 ..][0..4];
                                    target.* = .{ source[2], source[1], source[0], source[3] };
                                    continue;
                                }
                                scratch[by * tw + bx] = switch (bitmap.pixel_mode) {
                                    c.FT_PIXEL_MODE_MONO => if ((bitmap.buffer[sy * pitch + sx / 8] & (@as(u8, 0x80) >> @intCast(sx % 8))) != 0) 255 else 0,
                                    c.FT_PIXEL_MODE_GRAY => bitmap.buffer[sy * pitch + sx],
                                    else => return error.UnsupportedGlyphBitmap,
                                };
                            }
                        }
                        try painter.flush();
                        const region = if (is_color) try self.atlas.insertColor(tile_key, tw, th, scratch, tw * 4) else try self.atlas.insert(tile_key, tw, th, scratch, tw);
                        try painter.upload(&self.atlas, region);
                        break :blk region;
                    };
                    const dx: i32 = @intCast(@divFloor(g.x, 64) + m.left + @as(i64, @intCast(tx)));
                    const dy: i32 = @intCast(y + self.ascent * @as(i32, @intCast(self.scale)) - m.top + @divFloor(g.y, 64) + @as(i64, @intCast(ty)));
                    // Per-cell clips preserve cursor colors even inside a single ligature.
                    for (g.column..g.end) |col| {
                        const rgb = colors(g.style, cursor.visible and cursor.row == row and cursor.column == col);
                        try painter.mask(&self.atlas, region, dx, dy, .{ .x = @intCast(self.visualCached(screen, row, col) * cw), .y = y, .width = @intCast(cw), .height = @intCast(ch) }, rgb.fg);
                    }
                }
            }
        }
        for (cells, 0..) |cell, col| {
            if (cell.style.hidden) continue;
            const rgb = colors(cell.style, cursor.visible and cursor.row == row and cursor.column == col);
            const x: i32 = @intCast(self.visualCached(screen, row, col) * cw);
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
                const texel = atlas.pages[region.page].pixels[(ay * Atlas.size + ax) * 4 ..][0..4];
                if (region.color) {
                    const background = self.pixels[offset];
                    var output: u32 = 0;
                    inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
                        const value = @as(u32, texel[channel]) + (((background >> shift) & 255) * (255 - @as(u32, texel[3])) + 127) / 255;
                        output |= @as(u32, @min(255, value)) << shift;
                    }
                    self.pixels[offset] = output;
                } else self.pixels[offset] = blend(rgb, self.pixels[offset], texel[3]);
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
