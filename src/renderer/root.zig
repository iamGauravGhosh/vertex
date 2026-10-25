//! Shared shaping, atlas rasterization, and CPU reference drawing.
const std = @import("std");
const c = @import("c");
const vt = @import("../terminal/root.zig");
pub const Atlas = @import("Atlas.zig");
pub const Damage = @import("Damage.zig");
pub const Symbols = @import("Symbols.zig");
const Renderer = @This();

const Colors = @import("../terminal/Colors.zig");
pub const default_foreground = Colors.foreground;
pub const default_background = Colors.background;
pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Image = struct { bitmap: *const vt.Graphics.Bitmap, destination: Rect, source: Rect, clip: Rect };
pub const PositionedGlyph = struct {
    id: u32,
    face: usize = 0,
    column: usize,
    end: usize,
    /// Logical source span remains unchanged when ink borrows an adjacent space.
    paint_end: ?usize = null,
    procedural: bool = false,
    /// Fitted bitmap top-left, in 26.6 pixels relative to the row.
    x: i64,
    y: i64,
    width: usize = 0,
    height: usize = 0,
    style: vt.Style,
};
const Face = struct { face: c.FT_Face, font: *c.hb_font_t, index: usize, variant: u2 = 0 };
pub const FontOptions = struct { family: []const u8 = "monospace", size: f64 = 12, directory: ?[:0]const u8 = null };
const Row = struct {
    fingerprint: u64 = 0,
    source: u64 = 0,
    columns: usize = 0,
    bidi: bool = false,
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
style_sets: [3]*c.FcFontSet,
point_size: f64,
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
hover: ?vt.Links.Range = null,
levels_scratch: std.ArrayList(c.FriBidiLevel) = .empty,
scripts_scratch: std.ArrayList(c.hb_script_t) = .empty,
font_cache: std.AutoHashMapUnmanaged(u32, usize) = .empty,
raster_scratch: std.ArrayList(u8) = .empty,
bidi_chars: std.ArrayList(c.FriBidiChar) = .empty,
bidi_columns: std.ArrayList(usize) = .empty,
bidi_types: std.ArrayList(c.FriBidiCharType) = .empty,
bidi_brackets: std.ArrayList(c.FriBidiBracketType) = .empty,
bidi_levels: std.ArrayList(c.FriBidiLevel) = .empty,
bidi_map: std.ArrayList(c.FriBidiStrIndex) = .empty,
bidi_seen: std.ArrayList(bool) = .empty,

pub fn init(allocator: std.mem.Allocator) !Renderer {
    return initFont(allocator, "monospace");
}

/// Launch settings are injected so explicit font initializers stay deterministic.
pub fn initConfigured(allocator: std.mem.Allocator, name: ?[:0]const u8) !Renderer {
    return initFont(allocator, if (name) |value| (if (value.len != 0) value else "monospace") else "monospace");
}

/// An explicit Fontconfig pattern also permits deterministic font tests.
pub fn initFont(allocator: std.mem.Allocator, name: [:0]const u8) !Renderer {
    return initFontDirectory(allocator, name, null);
}

/// Additional application fonts make rendering tests independent of installed fonts.
pub fn initFontDirectory(allocator: std.mem.Allocator, name: [:0]const u8, directory: ?[:0]const u8) !Renderer {
    return initWithOptions(allocator, .{ .family = name, .directory = directory });
}

pub fn initWithOptions(allocator: std.mem.Allocator, options: FontOptions) !Renderer {
    if (!std.math.isFinite(options.size) or options.size < 4 or options.size > 128) return error.FontSizeFailed;
    const name = try allocator.dupeSentinel(u8, if (options.family.len == 0) "monospace" else options.family, 0);
    defer allocator.free(name);
    const config = c.FcInitLoadConfigAndFonts() orelse return error.FontconfigFailed;
    defer c.FcConfigDestroy(config);
    if (options.directory) |path| if (c.FcConfigAppFontAddDir(config, @ptrCast(path)) == 0) return error.FontNotFound;
    const pattern = c.FcNameParse(name.ptr) orelse return error.FontconfigFailed;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(config, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);
    var result: c.FcResult = undefined;
    const fallbacks = c.FcFontSort(config, pattern, c.FcTrue, null, &result) orelse return error.FontNotFound;
    errdefer c.FcFontSetDestroy(fallbacks);
    var style_sets: [3]*c.FcFontSet = undefined;
    var style_count: usize = 0;
    errdefer for (style_sets[0..style_count]) |set| c.FcFontSetDestroy(set);
    for (&style_sets, 1..) |*set, variant| {
        const styled = c.FcPatternDuplicate(pattern) orelse return error.OutOfMemory;
        defer c.FcPatternDestroy(styled);
        _ = c.FcPatternDel(styled, c.FC_WEIGHT);
        _ = c.FcPatternDel(styled, c.FC_SLANT);
        _ = c.FcPatternAddInteger(styled, c.FC_WEIGHT, if (variant & 1 != 0) c.FC_WEIGHT_BOLD else c.FC_WEIGHT_REGULAR);
        _ = c.FcPatternAddInteger(styled, c.FC_SLANT, if (variant & 2 != 0) c.FC_SLANT_ITALIC else c.FC_SLANT_ROMAN);
        set.* = c.FcFontSort(config, styled, c.FcTrue, null, &result) orelse return error.FontNotFound;
        style_count += 1;
    }
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
    try sizeFace(face, options.size, 1);
    const m = face.*.size.*.metrics;
    const advance = if (c.FT_Get_Char_Index(face, 'M') != 0 and c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0 and face.*.glyph.*.advance.x > 0) face.*.glyph.*.advance.x else m.max_advance;
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
        .style_sets = style_sets,
        .point_size = options.size,
        .buffer = buffer,
        .cell_width = @intCast(@max(1, @divTrunc(advance + 63, 64))),
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
    self.levels_scratch.deinit(self.allocator);
    self.scripts_scratch.deinit(self.allocator);
    self.font_cache.deinit(self.allocator);
    self.raster_scratch.deinit(self.allocator);
    self.bidi_chars.deinit(self.allocator);
    self.bidi_columns.deinit(self.allocator);
    self.bidi_types.deinit(self.allocator);
    self.bidi_brackets.deinit(self.allocator);
    self.bidi_levels.deinit(self.allocator);
    self.bidi_map.deinit(self.allocator);
    self.bidi_seen.deinit(self.allocator);
    self.atlas.deinit();
    self.metrics.deinit();
    c.hb_buffer_destroy(self.buffer);
    for (self.faces.items) |face| {
        c.hb_font_destroy(face.font);
        _ = c.FT_Done_Face(face.face);
    }
    self.faces.deinit(self.allocator);
    c.FcFontSetDestroy(self.fallbacks);
    for (self.style_sets) |set| c.FcFontSetDestroy(set);
    c.hb_font_destroy(self.font);
    _ = c.FT_Done_Face(self.face);
    _ = c.FT_Done_FreeType(self.library);
    self.* = undefined;
}

pub fn setScale(self: *Renderer, scale: usize) !void {
    if (scale == self.scale) return;
    if (scale == 0 or scale > 1024) return error.FontSizeFailed;
    try sizeFace(self.face, self.point_size, scale);
    c.hb_ft_font_changed(self.font);
    for (self.faces.items) |face| {
        try sizeFace(face.face, self.point_size, scale);
        c.hb_ft_font_changed(face.font);
    }
    self.atlas.clear();
    self.metrics.clearRetainingCapacity();
    for (self.rows) |*row| row.valid = false;
    self.scale = scale;
}

fn pixelSize(self: *const Renderer) usize {
    return @intFromFloat(@round(self.point_size * 96.0 / 72.0 * @as(f64, @floatFromInt(self.scale))));
}

fn sizeFace(face: c.FT_Face, points: f64, scale: usize) !void {
    const pixels: usize = @intFromFloat(@round(points * 96.0 / 72.0 * @as(f64, @floatFromInt(scale))));
    if (c.FT_Set_Char_Size(face, 0, @intFromFloat(@round(points * 64)), @intCast(96 * scale), @intCast(96 * scale)) == 0) return;
    if (face.*.num_fixed_sizes == 0) return error.FontSizeFailed;
    var best: c_int = 0;
    for (0..@intCast(face.*.num_fixed_sizes)) |i| {
        if (@abs(@as(i64, face.*.available_sizes[i].y_ppem) - @as(i64, @intCast(pixels * 64))) < @abs(@as(i64, face.*.available_sizes[@intCast(best)].y_ppem) - @as(i64, @intCast(pixels * 64)))) best = @intCast(i);
    }
    if (c.FT_Select_Size(face, best) != 0) return error.FontSizeFailed;
}
fn ignorable(cp: u21) bool {
    return vt.Unicode.isFormat(cp) or cp == 0x200c or cp == 0x200d or
        (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0xe0020 and cp <= 0xe007f) or
        (cp >= 0xe0100 and cp <= 0xe01ef);
}
fn supports(face: c.FT_Face, cluster: []const u21) bool {
    for (cluster) |cp| {
        if (ignorable(cp)) continue;
        if (c.FT_Get_Char_Index(face, cp) == 0) return false;
    }
    return true;
}
fn faceFor(self: *Renderer, cluster: []const u21, style: vt.Style) !usize {
    const variant: u2 = @as(u2, @intFromBool(style.bold)) | (@as(u2, @intFromBool(style.italic)) << 1);
    if (cluster.len != 1) return self.findFace(cluster, variant);
    const key = @as(u32, cluster[0]) | (@as(u32, variant) << 21);
    if (self.font_cache.get(key)) |face| return face;
    const face = try self.findFace(cluster, variant);
    if (self.font_cache.count() >= 4096) self.font_cache.clearRetainingCapacity();
    try self.font_cache.put(self.allocator, key, face);
    return face;
}
fn findFace(self: *Renderer, cluster: []const u21, variant: u2) !usize {
    var emoji = false;
    var text = false;
    for (cluster) |cp| {
        if (cp == 0xfe0e) text = true;
        if (cp == 0xfe0f or vt.Unicode.isEmojiPresentation(cp)) emoji = true;
    }
    emoji = emoji and !text;
    const set = if (variant == 0) self.fallbacks else self.style_sets[variant - 1];
    // Always follow Fontconfig order, independent of faces loaded by earlier rows.
    for (0..(if (emoji) @as(usize, 2) else 1)) |pass| {
        const prefer_color = emoji and pass == 0;
        if (variant == 0 and !prefer_color and supports(self.face, cluster)) return 0;
        for (0..@intCast(set.nfont)) |i| {
            const pattern = set.fonts[i];
            var charset: ?*c.FcCharSet = null;
            if (c.FcPatternGetCharSet(pattern, c.FC_CHARSET, 0, &charset) != c.FcResultMatch) continue;
            var supported = true;
            for (cluster) |cp| {
                if (ignorable(cp)) continue;
                if (c.FcCharSetHasChar(charset, cp) == 0) {
                    supported = false;
                    break;
                }
            }
            if (!supported) continue;
            if (prefer_color) {
                var is_color: c.FcBool = 0;
                if (c.FcPatternGetBool(pattern, c.FC_COLOR, 0, &is_color) != c.FcResultMatch or is_color == 0) continue;
            }
            for (self.faces.items, 0..) |face, j| if (face.index == i and face.variant == variant and supports(face.face, cluster)) return j + 1;
            var filename: [*c]c.FcChar8 = null;
            var index: c_int = 0;
            if (c.FcPatternGetString(pattern, c.FC_FILE, 0, &filename) != c.FcResultMatch) continue;
            _ = c.FcPatternGetInteger(pattern, c.FC_INDEX, 0, &index);
            var face: c.FT_Face = null;
            if (c.FT_New_Face(self.library, @ptrCast(filename), index, &face) != 0) continue;
            errdefer _ = c.FT_Done_Face(face);
            sizeFace(face, self.point_size, self.scale) catch {
                _ = c.FT_Done_Face(face);
                continue;
            };
            if (!supports(face, cluster)) {
                _ = c.FT_Done_Face(face);
                continue;
            }
            const font = c.hb_ft_font_create_referenced(face) orelse return error.OutOfMemory;
            errdefer c.hb_font_destroy(font);
            try self.faces.append(self.allocator, .{ .face = face, .font = font, .index = i, .variant = variant });
            return self.faces.items.len;
        }
    }
    // Resolve a visible replacement through the same style-aware fallback order.
    if (!(cluster.len == 1 and cluster[0] == 0xfffd)) return self.findFace(&.{0xfffd}, variant);
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
    const chars = &self.bidi_chars;
    chars.clearRetainingCapacity();
    const columns = &self.bidi_columns;
    columns.clearRetainingCapacity();
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
    try self.bidi_types.resize(self.allocator, chars.items.len);
    const types = self.bidi_types.items;
    try self.bidi_brackets.resize(self.allocator, chars.items.len);
    const brackets = self.bidi_brackets.items;
    try self.bidi_levels.resize(self.allocator, chars.items.len);
    const levels = self.bidi_levels.items;
    try self.bidi_map.resize(self.allocator, chars.items.len);
    const map = self.bidi_map.items;
    for (map, 0..) |*entry, i| entry.* = @intCast(i);
    c.fribidi_get_bidi_types(chars.items.ptr, @intCast(chars.items.len), types.ptr);
    c.fribidi_get_bracket_types(chars.items.ptr, @intCast(chars.items.len), types.ptr, brackets.ptr);
    var direction: c.FriBidiParType = c.FRIBIDI_PAR_ON;
    if (c.fribidi_get_par_embedding_levels_ex(types.ptr, brackets.ptr, @intCast(chars.items.len), &direction, levels.ptr) == 0) return error.OutOfMemory;
    if (c.fribidi_reorder_line(0, types.ptr, @intCast(line_end - line_start), @intCast(line_start), direction, levels.ptr, null, map.ptr) == 0) return error.OutOfMemory;
    try self.bidi_seen.resize(self.allocator, screen.columns);
    const seen = self.bidi_seen.items;
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
    var fingerprint = screen.row_generations[index];
    if (self.bidi) {
        var hash = std.hash.Wyhash.init(0);
        const bounds = paragraph(screen, index);
        hash.update(std.mem.sliceAsBytes(screen.row_generations[bounds.first..bounds.last]));
        std.hash.autoHash(&hash, bounds.first);
        std.hash.autoHash(&hash, bounds.last);
        fingerprint = hash.final();
    }
    if (row.valid and row.source == screen.identity and row.columns == screen.columns and row.bidi == self.bidi and row.fingerprint == fingerprint) return row.glyphs.items;
    row.valid = false;
    row.glyphs.clearRetainingCapacity();
    try row.visual.resize(self.allocator, cells.len);
    for (row.visual.items, 0..) |*col, i| col.* = i;
    try self.levels_scratch.resize(self.allocator, cells.len);
    const levels = self.levels_scratch.items;
    try self.scripts_scratch.resize(self.allocator, cells.len);
    const scripts = self.scripts_scratch.items;
    // Classify once in reverse, then inherit previous script in one forward pass.
    var following: c.hb_script_t = c.HB_SCRIPT_LATIN;
    var reverse = cells.len;
    while (reverse > 0) {
        reverse -= 1;
        const script = c.hb_unicode_script(c.hb_unicode_funcs_get_default(), cells[reverse].codepoint);
        const common = script == c.HB_SCRIPT_COMMON or script == c.HB_SCRIPT_INHERITED or script == c.HB_SCRIPT_UNKNOWN;
        if (!common) following = script;
        scripts[reverse] = if (common) following else script;
    }
    var previous: c.hb_script_t = c.HB_SCRIPT_UNKNOWN;
    for (cells, 0..) |cell, i| {
        const script = c.hb_unicode_script(c.hb_unicode_funcs_get_default(), cell.codepoint);
        const common = script == c.HB_SCRIPT_COMMON or script == c.HB_SCRIPT_INHERITED or script == c.HB_SCRIPT_UNKNOWN;
        if (common and previous != c.HB_SCRIPT_UNKNOWN) scripts[i] = previous;
        if (cell.width != 0) previous = scripts[i];
    }
    @memset(levels, 0);
    if (self.bidi) try self.resolveBidi(screen, index, levels, row.visual.items);
    var start: usize = 0;
    while (start < cells.len) {
        if (cells[start].width == 0) {
            start += 1;
            continue;
        }
        if (Symbols.supports(cells[start].codepoint) and screen.getGrapheme(index, start).?.len == 1) {
            try row.glyphs.append(self.allocator, .{
                .id = cells[start].codepoint,
                .column = start,
                .end = start + cells[start].width,
                .procedural = true,
                .x = @intCast(row.visual.items[start] * self.cell_width * self.scale * 64),
                .y = 0,
                .width = self.cell_width * self.scale,
                .height = self.cell_height * self.scale,
                .style = cells[start].style,
            });
            start += cells[start].width;
            continue;
        }
        const script = scripts[start];
        const face_index = try self.faceFor(screen.getGrapheme(index, start).?, cells[start].style);
        const selected = self.fontFace(face_index);
        const rtl = @mod(levels[start], 2) == 1;
        var end = start + cells[start].width;
        while (end < cells.len) {
            if (cells[end].width == 0) {
                end += 1;
                continue;
            }
            if (Symbols.supports(cells[end].codepoint) or privateUse(cells[start].codepoint) or privateUse(cells[end].codepoint) or !std.meta.eql(cells[end].style, cells[start].style) or scripts[end] != script or @mod(levels[end], 2) != @mod(levels[start], 2) or try self.faceFor(screen.getGrapheme(index, end).?, cells[end].style) != face_index) break;
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
                const replacement: u32 = if (c.FT_Get_Char_Index(selected.face, cp) == 0 and vt.Unicode.scalarWidth(cp) != 0 and !ignorable(cp)) 0xfffd else cp;
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
            const first_glyph = row.glyphs.items.len;
            const numerator: i64 = if (selected.face.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0) @intCast(self.pixelSize()) else 1;
            const denominator: i64 = if (numerator != 1) @max(1, selected.face.*.size.*.metrics.y_ppem) else 1;
            for (i..next) |j| {
                try row.glyphs.append(self.allocator, .{
                    .id = infos[j].codepoint,
                    .face = face_index,
                    .column = column,
                    .end = @max(column + cells[column].width, cluster_end),
                    .x = pen + @divTrunc(@as(i64, positions[j].x_offset) * numerator, denominator),
                    .y = -@divTrunc(@as(i64, positions[j].y_offset) * numerator, denominator),
                    .style = cells[start].style,
                });
                pen += @divTrunc(@as(i64, positions[j].x_advance) * numerator, denominator);
            }
            const icon = privateUse(cells[column].codepoint);
            const logical_end = row.glyphs.items[first_glyph].end;
            var paint_end = logical_end;
            if (icon and try self.iconWantsSpace(row.glyphs.items[first_glyph..]) and logical_end == column + 1 and logical_end < cells.len and
                cells[logical_end].codepoint == ' ' and cells[logical_end].width == 1 and
                screen.getGrapheme(index, logical_end).?.len == 1 and
                std.meta.eql(cells[column].style, cells[logical_end].style) and cells[column].link == cells[logical_end].link and
                row.visual.items[logical_end] == visual + 1)
            {
                paint_end += 1;
            }
            for (row.glyphs.items[first_glyph..]) |*glyph| glyph.paint_end = paint_end;
            try self.fitCluster(row.glyphs.items[first_glyph..], visual, pen, icon);
            i = next;
        }
        start = end;
    }
    row.fingerprint = fingerprint;
    row.source = screen.identity;
    row.columns = screen.columns;
    row.bidi = self.bidi;
    row.valid = true;
    self.shaped_rows += 1;
    return row.glyphs.items;
}
pub fn visualColumn(self: *Renderer, screen: *const vt.Screen, row: usize, column: usize) !usize {
    if (!self.bidi) return column;
    _ = try self.shapeRow(screen, row);
    return self.visualCached(screen, row, column);
}
pub fn logicalColumn(self: *Renderer, screen: *const vt.Screen, row: usize, visual: usize) !usize {
    if (!self.bidi) return visual;
    _ = try self.shapeRow(screen, row);
    for (0..screen.columns) |column| if (self.visualCached(screen, row, column) == visual) return column;
    return visual;
}
fn visualCached(self: *const Renderer, screen: *const vt.Screen, row: usize, column: usize) usize {
    const head = if (screen.getCell(row, column).?.width == 0 and column > 0) column - 1 else column;
    return self.rows[row].visual.items[head] + column - head;
}

fn privateUse(cp: u21) bool {
    return (cp >= 0xe000 and cp <= 0xf8ff) or (cp >= 0xf0000 and cp <= 0xffffd) or (cp >= 0x100000 and cp <= 0x10fffd);
}

fn glyphKey(g: PositionedGlyph) u64 {
    return (@as(u64, @intFromBool(g.procedural)) << 63) | (@as(u64, @intCast(g.face)) << 40) | @as(u64, g.id) | (@as(u64, @intFromBool(g.style.bold)) << 32) | (@as(u64, @intFromBool(g.style.italic)) << 33);
}

fn glyphMetrics(self: *Renderer, g: PositionedGlyph) !Metrics {
    const key = glyphKey(g);
    if (self.metrics.get(key)) |m| return m;
    const m = try self.load(g.face, g.id, g.style);
    if (self.metrics.count() >= 4096) self.metrics.clearRetainingCapacity();
    try self.metrics.put(key, m);
    return m;
}

/// Borrow space only when the ink would otherwise be compressed horizontally.
fn iconWantsSpace(self: *Renderer, glyphs: []const PositionedGlyph) !bool {
    var left: i64 = std.math.maxInt(i64);
    var right: i64 = std.math.minInt(i64);
    var top: i64 = std.math.maxInt(i64);
    var bottom: i64 = std.math.minInt(i64);
    for (glyphs) |g| {
        const m = try self.glyphMetrics(g);
        if (m.width == 0 or m.height == 0) continue;
        const x = @divFloor(g.x, 64) + m.left;
        const y = @divFloor(g.y, 64) - m.top;
        left = @min(left, x);
        right = @max(right, x + @as(i64, @intCast(m.width)));
        top = @min(top, y);
        bottom = @max(bottom, y + @as(i64, @intCast(m.height)));
    }
    if (left == std.math.maxInt(i64)) return false;
    const cw: i64 = @intCast(self.cell_width * self.scale);
    const ch: i64 = @intCast(self.cell_height * self.scale);
    return right - left > cw and (right - left) * ch > cw * (bottom - top);
}

/// Transform a complete HB cluster together, retaining mark and ligature geometry.
/// Raster bounds include bearings and synthetic styles, not just advance widths.
fn fitCluster(self: *Renderer, glyphs: []PositionedGlyph, visual: usize, advance: i64, icon: bool) !void {
    var left: i64 = std.math.maxInt(i64);
    var right: i64 = std.math.minInt(i64);
    var top: i64 = std.math.maxInt(i64);
    var bottom: i64 = std.math.minInt(i64);
    for (glyphs) |*g| {
        const m = try self.glyphMetrics(g.*);
        g.x = @divFloor(g.x, 64) + m.left;
        g.y = @divFloor(g.y, 64) - m.top;
        g.width = m.width;
        g.height = m.height;
        if (m.width == 0 or m.height == 0) continue;
        left = @min(left, g.x);
        right = @max(right, g.x + @as(i64, @intCast(m.width)));
        top = @min(top, g.y);
        bottom = @max(bottom, g.y + @as(i64, @intCast(m.height)));
    }
    if (left == std.math.maxInt(i64)) return;
    const first = glyphs[0];
    const width: i64 = @intCast(((first.paint_end orelse first.end) - first.column) * self.cell_width * self.scale);
    const height: i64 = @intCast(self.cell_height * self.scale);
    if (!icon) {
        left = @min(0, left);
        right = @max(@as(i64, @intCast((@abs(advance) + 63) / 64)), right);
    }
    var numerator: i64 = 1;
    var denominator: i64 = 1;
    if (right - left > width) {
        numerator = width;
        denominator = right - left;
    }
    if ((bottom - top) * numerator > height * denominator) {
        numerator = height;
        denominator = bottom - top;
    }
    const proportional = self.fontFace(first.face).face.*.face_flags & c.FT_FACE_FLAG_FIXED_WIDTH == 0;
    const padding_x = if (icon or proportional or numerator != denominator) @divFloor(width - @divFloor((right - left) * numerator, denominator), 2) else 0;
    const origin_x: i64 = @as(i64, @intCast(visual * self.cell_width * self.scale)) + padding_x;
    const ascent: i64 = self.ascent * @as(i64, @intCast(self.scale));
    const origin_y: i64 = if (icon) @divFloor(height - @divFloor((bottom - top) * numerator, denominator), 2) else std.math.clamp(ascent, -@divFloor(top * numerator, denominator), height - @divFloor(bottom * numerator, denominator));
    for (glyphs) |*g| {
        const x = @divFloor((g.x - left) * numerator, denominator);
        const y = @divFloor((g.y - (if (icon) top else @as(i64, 0))) * numerator, denominator);
        // Map shared edges consistently, including adjacent glyphs in one cluster.
        g.width = if (g.width == 0) 0 else @intCast(@max(1, @divFloor((g.x + @as(i64, @intCast(g.width)) - left) * numerator, denominator) - x));
        g.height = if (g.height == 0) 0 else @intCast(@max(1, @divFloor((g.y + @as(i64, @intCast(g.height)) - (if (icon) top else @as(i64, 0))) * numerator, denominator) - y));
        g.x = (origin_x + x) * 64;
        g.y = (origin_y + y) * 64;
    }
}

fn load(self: *Renderer, face_index: usize, id: u32, style: vt.Style) !Metrics {
    const face = self.fontFace(face_index).face;
    if (c.FT_Load_Glyph(face, id, c.FT_LOAD_DEFAULT | c.FT_LOAD_COLOR | c.FT_LOAD_NO_SVG) != 0) {
        if (c.FT_Load_Glyph(face, id, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_SVG) != 0) return error.GlyphLoadFailed;
    }
    const slot = face.*.glyph;
    if (style.bold and face.*.style_flags & c.FT_STYLE_FLAG_BOLD == 0 and slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) c.FT_GlyphSlot_Embolden(slot);
    if (style.italic and face.*.style_flags & c.FT_STYLE_FLAG_ITALIC == 0 and slot.*.format != c.FT_GLYPH_FORMAT_BITMAP) c.FT_GlyphSlot_Oblique(slot);
    if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) {
        // Unsupported color formats may still have a usable monochrome outline.
        if (c.FT_Load_Glyph(face, id, c.FT_LOAD_DEFAULT | c.FT_LOAD_NO_SVG) != 0 or c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) {
            if (c.FT_Load_Char(face, 0xfffd, c.FT_LOAD_RENDER | c.FT_LOAD_NO_SVG) != 0) return .{ .width = 0, .height = 0, .left = 0, .top = 0 };
        }
    }
    const numerator: usize = if (face.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0) self.pixelSize() else 1;
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
        try self.paintImages(screen, row, 0, painter);
        const cells = screen.getRow(row).?;
        const glyphs = try self.shapeRow(screen, row);
        var background_col: usize = 0;
        while (background_col < cells.len) {
            const rgb = colors(cells[background_col].style, cursor.visible and cursor.shape == .block and cursor.row == row and cursor.column == background_col);
            const x = self.visualCached(screen, row, background_col);
            var end = background_col + 1;
            while (end < cells.len) : (end += 1) {
                const next = colors(cells[end].style, cursor.visible and cursor.shape == .block and cursor.row == row and cursor.column == end);
                if (next.bg != rgb.bg or self.visualCached(screen, row, end) != x + end - background_col) break;
            }
            if (rgb.bg != default_background) try painter.fill(.{ .x = @intCast(x * cw), .y = y, .width = @intCast((end - background_col) * cw), .height = @intCast(ch) }, rgb.bg);
            background_col = end;
        }
        try self.paintImages(screen, row, 1, painter);
        for (glyphs) |g| {
            if (g.style.hidden) continue;
            const key = glyphKey(g);
            var loaded = false;
            var ty: usize = 0;
            while (ty < g.height) : (ty += Atlas.tile_size) {
                var tx: usize = 0;
                while (tx < g.width) : (tx += Atlas.tile_size) {
                    const tile_key: Atlas.Key = .{ .glyph = key, .width = @intCast(g.width), .height = @intCast(g.height), .x = @intCast(tx), .y = @intCast(ty) };
                    const region = self.atlas.get(tile_key) orelse blk: {
                        if (!loaded and !g.procedural) {
                            _ = try self.load(g.face, g.id, g.style);
                            loaded = true;
                        }
                        const bitmap = self.fontFace(g.face).face.*.glyph.*.bitmap;
                        const tw: usize = @min(Atlas.tile_size, g.width - tx);
                        const th: usize = @min(Atlas.tile_size, g.height - ty);
                        // Only a bounded tile scratch buffer, including for very large glyphs.
                        const is_color = !g.procedural and bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA;
                        const channels: usize = if (is_color) 4 else 1;
                        try self.raster_scratch.resize(self.allocator, tw * th * channels);
                        const scratch = self.raster_scratch.items;
                        for (0..th) |by| {
                            for (0..tw) |bx| {
                                const texel: [4]u8 = if (g.procedural) @splat(Symbols.alpha(@intCast(g.id), tx + bx, ty + by, g.width, g.height)) else try rasterPixel(bitmap, tx + bx, ty + by, g.width, g.height);
                                if (is_color) {
                                    const target = scratch[(by * tw + bx) * 4 ..][0..4];
                                    target.* = texel;
                                    continue;
                                }
                                scratch[by * tw + bx] = texel[3];
                            }
                        }
                        try painter.flush();
                        const region = if (is_color) try self.atlas.insertColor(tile_key, tw, th, scratch, tw * 4) else try self.atlas.insert(tile_key, tw, th, scratch, tw);
                        try painter.upload(&self.atlas, region);
                        break :blk region;
                    };
                    const dx: i32 = @intCast(@divFloor(g.x, 64) + @as(i64, @intCast(tx)));
                    const dy: i32 = @intCast(y + @divFloor(g.y, 64) + @as(i64, @intCast(ty)));
                    // Per-cell clips preserve cursor colors even inside a single ligature.
                    for (g.column..g.paint_end orelse g.end) |col| {
                        const rgb = colors(g.style, cursor.visible and cursor.shape == .block and cursor.row == row and cursor.column == col);
                        try painter.mask(&self.atlas, region, dx, dy, .{ .x = @intCast(self.visualCached(screen, row, col) * cw), .y = y, .width = @intCast(cw), .height = @intCast(ch) }, rgb.fg);
                    }
                }
            }
        }
        for (cells, 0..) |cell, col| {
            if (cell.style.hidden) continue;
            const rgb = colors(cell.style, cursor.visible and cursor.shape == .block and cursor.row == row and cursor.column == col);
            const x: i32 = @intCast(self.visualCached(screen, row, col) * cw);
            const baseline: usize = @intCast(@max(0, self.ascent));
            const hovered = if (self.hover) |range| row * screen.columns + col >= range.first and row * screen.columns + col < range.end else false;
            if (cell.style.underline or hovered) {
                const line = @min(ch - 1, (baseline + 1) * self.scale);
                try painter.fill(.{ .x = x, .y = y + @as(i32, @intCast(line)), .width = @intCast(cw), .height = @intCast(@min(self.scale, ch - line)) }, rgb.fg);
            }
            if (cell.style.strikethrough) {
                const line = @min(ch - 1, baseline / 2 * self.scale);
                try painter.fill(.{ .x = x, .y = y + @as(i32, @intCast(line)), .width = @intCast(cw), .height = @intCast(@min(self.scale, ch - line)) }, rgb.fg);
            }
        }
        try self.paintImages(screen, row, 2, painter);
        if (cursor.visible and cursor.shape != .block and cursor.row == row) {
            const x: i32 = @intCast(self.visualCached(screen, row, cursor.column) * cw);
            const rgb = colors(cells[cursor.column].style, false);
            const thickness = @min(2 * self.scale, if (cursor.shape == .bar) cw else ch);
            try painter.fill(.{ .x = x, .y = y + @as(i32, @intCast(if (cursor.shape == .underline) ch - thickness else 0)), .width = @intCast(if (cursor.shape == .bar) thickness else cw), .height = @intCast(if (cursor.shape == .underline) thickness else ch) }, rgb.fg);
        }
    }
    try painter.flush();
}

fn bitmapPixel(bitmap: c.FT_Bitmap, x: usize, y: usize) ![4]u8 {
    const pitch: usize = @intCast(@abs(bitmap.pitch));
    const row = (if (bitmap.pitch < 0) bitmap.rows - 1 - y else y) * pitch;
    if (bitmap.pixel_mode == c.FT_PIXEL_MODE_BGRA) {
        const pixel = bitmap.buffer[row + x * 4 ..][0..4];
        return .{ pixel[2], pixel[1], pixel[0], pixel[3] };
    }
    const alpha = switch (bitmap.pixel_mode) {
        c.FT_PIXEL_MODE_MONO => @as(u8, if (bitmap.buffer[row + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0) 255 else 0),
        c.FT_PIXEL_MODE_GRAY => bitmap.buffer[row + x],
        else => return error.UnsupportedGlyphBitmap,
    };
    return @splat(alpha);
}

/// Area coverage retains thin strokes when wide icons shrink into a single cell.
/// Sampling premultiplied channels also preserves color-glyph transparency.
fn rasterPixel(bitmap: c.FT_Bitmap, x: usize, y: usize, width: usize, height: usize) ![4]u8 {
    if (width == bitmap.width and height == bitmap.rows) return bitmapPixel(bitmap, x, y);
    const x0 = x * bitmap.width;
    const x1 = (x + 1) * bitmap.width;
    const y0 = y * bitmap.rows;
    const y1 = (y + 1) * bitmap.rows;
    var sums: [4]u64 = @splat(0);
    for (y0 / height..(y1 + height - 1) / height) |sy| {
        const wy = @min(y1, (sy + 1) * height) - @max(y0, sy * height);
        for (x0 / width..(x1 + width - 1) / width) |sx| {
            const wx = @min(x1, (sx + 1) * width) - @max(x0, sx * width);
            const pixel = try bitmapPixel(bitmap, sx, sy);
            for (&sums, pixel) |*sum, channel| sum.* += @as(u64, channel) * wx * wy;
        }
    }
    const area = @as(u64, bitmap.width) * bitmap.rows;
    var pixel: [4]u8 = undefined;
    for (&pixel, sums) |*channel, sum| channel.* = @intCast((sum + area / 2) / area);
    return pixel;
}

fn paintImages(self: *Renderer, screen: *const vt.Screen, row: usize, layer: u2, painter: anytype) !void {
    const cw = self.cell_width * self.scale;
    const ch = self.cell_height * self.scale;
    for (screen.graphics.placements.items) |p| {
        const actual: u2 = if (p.z < -1073741824) 0 else if (p.z < 0) 1 else 2;
        if (actual != layer) continue;
        const x: i32 = @intCast(@as(i64, p.column) * @as(i64, @intCast(cw)) + @divFloor(@as(i64, p.x) * @as(i64, @intCast(cw)), @as(i64, @intCast(p.cell_width))));
        const y: i32 = @intCast(@as(i64, p.row) * @as(i64, @intCast(ch)) + @divFloor(@as(i64, p.y) * @as(i64, @intCast(ch)), @as(i64, @intCast(p.cell_height))));
        const width: i32 = @intCast(@max(1, p.width * cw / p.cell_width));
        const height: i32 = @intCast(@max(1, p.height * ch / p.cell_height));
        const clip_left: i32 = @intCast(@divFloor(@as(i64, p.clip_left) * width, @as(i64, @intCast(p.width))));
        const clip_top: i32 = @intCast(@divFloor(@as(i64, p.clip_top) * height, @as(i64, @intCast(p.height))));
        const clip_right: i32 = @intCast(@divFloor(@as(i64, p.clip_right) * width, @as(i64, @intCast(p.width))));
        const clip_bottom: i32 = @intCast(@divFloor(@as(i64, p.clip_bottom) * height, @as(i64, @intCast(p.height))));
        const clip = intersect(.{ .x = x + clip_left, .y = y + clip_top, .width = clip_right - clip_left, .height = clip_bottom - clip_top }, .{ .x = 0, .y = @intCast(row * ch), .width = @intCast(painter.width), .height = @intCast(ch) });
        if (clip.width <= 0 or clip.height <= 0) continue;
        try painter.image(.{ .bitmap = p.bitmap, .destination = .{ .x = x, .y = y, .width = width, .height = height }, .source = .{ .x = @intCast(p.source_x), .y = @intCast(p.source_y), .width = @intCast(p.source_width), .height = @intCast(p.source_height) }, .clip = clip });
    }
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
    pub fn image(self: *Cpu, value: Image) !void {
        const r = intersect(intersect(value.destination, value.clip), self.bounds());
        if (r.width <= 0 or r.height <= 0) return;
        for (@as(usize, @intCast(r.y))..@intCast(r.y + r.height)) |py| for (@as(usize, @intCast(r.x))..@intCast(r.x + r.width)) |px| {
            const sx: usize = @intCast(@as(i64, value.source.x) + @divTrunc((2 * (@as(i64, @intCast(px)) - value.destination.x) + 1) * value.source.width, 2 * @as(i64, value.destination.width)));
            const sy: usize = @intCast(@as(i64, value.source.y) + @divTrunc((2 * (@as(i64, @intCast(py)) - value.destination.y) + 1) * value.source.height, 2 * @as(i64, value.destination.height)));
            const rgba = value.bitmap.pixels[(sy * value.bitmap.width + sx) * 4 ..][0..4];
            const at = py * self.width + px;
            var output: u32 = 0;
            inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
                const v = @as(u32, rgba[channel]) + (((self.pixels[at] >> shift) & 255) * (255 - @as(u32, rgba[3])) + 127) / 255;
                output |= @as(u32, @min(255, v)) << shift;
            }
            self.pixels[at] = output;
        };
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
        .indexed => |index| Colors.indexed(index),
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
