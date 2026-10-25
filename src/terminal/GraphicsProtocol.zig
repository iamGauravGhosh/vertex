//! Kitty APC, iTerm2 OSC, and Sixel DCS consumers. No filesystem access.
const std = @import("std");
const G = @import("Graphics.zig");
const Sixel = @import("Sixel.zig");
const Protocol = @This();
pub const Options = struct { images: bool = false, decoder: ?G.Decoder = null };
options: Options = .{},
budget: ?*G.Budget = null,
buffer: std.ArrayList(u8) = .empty,
pending: std.ArrayList(u8) = .empty,
invalid: bool = false,
kind: enum { ignored, kitty, osc, sixel } = .ignored,
kitty_header: Header = .{},
reply_header: Header = .{},
kitty_pending: bool = false,
multipart: bool = false,
multipart_header: [4096]u8 = undefined,
multipart_len: usize = 0,
screen_identity: u64 = 0,
sixel_params: [3]u16 = @splat(0),
colors: Sixel.Palette = Sixel.palette(),
sixel_display: bool = false,
sixel_private: bool = true,
sixel_right: bool = false,

const Header = struct {
    a: u8 = 't',
    t: u8 = 'd',
    o: u8 = 0,
    f: u32 = 32,
    s: u32 = 0,
    v: u32 = 0,
    i: u32 = 0,
    I: u32 = 0,
    p: u32 = 0,
    m: u32 = 0,
    q: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    X: u32 = 0,
    Y: u32 = 0,
    c: u32 = 0,
    r: u32 = 0,
    C: u32 = 0,
    U: u32 = 0,
    P: u32 = 0,
    Q: u32 = 0,
    z: i32 = 0,
    d: u8 = 'a',
    S: u32 = 0,
};
fn header(bytes: []const u8) !Header {
    var result: Header = .{};
    var fields = std.mem.splitScalar(u8, bytes, ',');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        if (field.len < 3 or field[1] != '=') return error.InvalidImage;
        const value = field[2..];
        inline for (@typeInfo(Header).@"struct".field_names, @typeInfo(Header).@"struct".field_types) |name, T| if (field[0] == name[0]) {
            if (T == u8) {
                if (value.len != 1) return error.InvalidImage;
                @field(result, name) = value[0];
            } else @field(result, name) = std.fmt.parseInt(T, value, 10) catch return error.InvalidImage;
        };
    }
    if (result.q > 2 or result.m > 1 or result.C > 1) return error.InvalidImage;
    return result;
}
pub fn deinit(self: *Protocol, allocator: std.mem.Allocator) void {
    self.freeList(allocator, &self.buffer);
    self.freeList(allocator, &self.pending);
    if (self.budget) |budget| {
        budget.refs -= 1;
        if (budget.refs == 0) allocator.destroy(budget);
    }
}
fn freeList(self: *Protocol, allocator: std.mem.Allocator, list: *std.ArrayList(u8)) void {
    if (self.budget) |budget| budget.used -= list.capacity;
    list.deinit(allocator);
    list.* = .empty;
}
fn reserve(self: *Protocol, allocator: std.mem.Allocator, list: *std.ArrayList(u8), count: usize) !void {
    const needed = list.items.len + count;
    if (needed <= list.capacity) return;
    const available = if (self.budget) |budget| G.max_storage - budget.used else G.max_storage;
    if (needed - list.capacity > available) return error.ImageTooLarge;
    const capacity = @min(@max(needed, @max(256, list.capacity * 2)), list.capacity + available);
    const old = list.capacity;
    try list.ensureTotalCapacityPrecise(allocator, capacity);
    if (self.budget) |budget| budget.used += list.capacity - old;
}
pub fn reset(self: *Protocol) void {
    self.buffer.clearRetainingCapacity();
    self.pending.clearRetainingCapacity();
    self.kitty_pending = false;
    self.multipart = false;
    self.kind = .ignored;
    self.invalid = false;
    self.colors = Sixel.palette();
    self.sixel_display = false;
    self.sixel_private = true;
    self.sixel_right = false;
}
pub fn begin(self: *Protocol, kind: @FieldType(Protocol, "kind")) void {
    self.buffer.clearRetainingCapacity();
    self.invalid = false;
    self.kind = if (self.options.images) kind else .ignored;
    if (kind == .kitty and !self.kitty_pending) self.reply_header = .{};
}
pub fn byte(self: *Protocol, allocator: std.mem.Allocator, byte_: u8) !void {
    if (self.kind == .ignored or self.invalid) return;
    const limit: usize = if (self.kind == .sixel) G.max_transfer else (G.max_transfer + 2) / 3 * 4 + 4096;
    if (self.buffer.items.len >= limit) {
        self.invalid = true;
        self.buffer.clearRetainingCapacity();
        return;
    }
    self.reserve(allocator, &self.buffer, 1) catch |err| {
        if (err == error.OutOfMemory) return err;
        self.invalid = true;
        return;
    };
    self.buffer.appendAssumeCapacity(byte_);
    if (self.kind == .kitty and self.buffer.items.len == 1 and byte_ != 'G') {
        self.kind = .ignored;
        self.buffer.clearRetainingCapacity();
    }
    if (self.kind == .osc and self.buffer.items.len == 5 and !std.mem.eql(u8, self.buffer.items, "1337;")) {
        self.kind = .ignored;
        self.buffer.clearRetainingCapacity();
    }
}
pub fn end(self: *Protocol, session: anytype, success: bool) !void {
    defer {
        self.buffer.clearRetainingCapacity();
        if (self.buffer.capacity > 65536) self.freeList(session.allocator, &self.buffer);
        if (!self.kitty_pending and !self.multipart and self.pending.capacity > 65536) self.freeList(session.allocator, &self.pending);
    }
    if (!success or self.invalid) {
        self.pending.clearRetainingCapacity();
        self.kitty_pending = false;
        self.multipart = false;
        return;
    }
    if (self.kind == .ignored) return;
    if (self.screen_identity != session.screen.identity) {
        self.pending.clearRetainingCapacity();
        self.kitty_pending = false;
        self.multipart = false;
        self.screen_identity = session.screen.identity;
    }
    switch (self.kind) {
        .kitty => self.kitty(session) catch |err| {
            self.pending.clearRetainingCapacity();
            self.kitty_pending = false;
            if (err == error.OutOfMemory) return err;
            const bytes = self.buffer.items;
            const end_header = std.mem.indexOfScalar(u8, bytes, ';') orelse bytes.len;
            const h = if (self.reply_header.i != 0 or self.reply_header.I != 0) self.reply_header else if (bytes.len != 0 and bytes[0] == 'G') header(bytes[1..end_header]) catch return else return;
            try response(session, h, if (err == error.UnsupportedImage) "ENOTSUP:unsupported graphics command" else if (err == error.ImageNotFound) "ENOENT:image not found" else "EINVAL:invalid or oversized image", false);
        },
        .osc => self.iterm(session) catch |err| {
            self.pending.clearRetainingCapacity();
            self.multipart = false;
            if (err == error.OutOfMemory) return err;
        },
        .sixel => self.sixel(session) catch |err| {
            if (err == error.OutOfMemory) return err;
        },
        .ignored => {},
    }
}
fn base64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(bytes) catch return error.InvalidImage;
    if (n > G.max_transfer) return error.ImageTooLarge;
    const result = try allocator.alloc(u8, n);
    errdefer allocator.free(result);
    decoder.decode(result, bytes) catch return error.InvalidImage;
    return result;
}
fn append(self: *Protocol, allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (self.pending.items.len + bytes.len > G.max_transfer) return error.ImageTooLarge;
    try self.reserve(allocator, &self.pending, bytes.len);
    self.pending.appendSliceAssumeCapacity(bytes);
}
fn response(session: anytype, h: Header, message: []const u8, success: bool) !void {
    if (h.q == 2 or (h.q == 1 and success) or (h.i == 0 and h.I == 0)) return;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writer.print("\x1b_Gi={d}", .{h.i});
    if (h.I != 0) try writer.print(",I={d}", .{h.I});
    if (h.p != 0) try writer.print(",p={d}", .{h.p});
    try writer.print(";{s}\x1b\\", .{message});
    try session.reply(writer.buffered());
}
fn decoded(self: *Protocol, allocator: std.mem.Allocator, h: Header, bytes: []const u8) !G.Decoded {
    var inflated: ?[]u8 = null;
    defer if (inflated) |data| allocator.free(data);
    const input = if (h.o == 'z') blk: {
        var reader = std.Io.Reader.fixed(bytes);
        var decompressor = std.compress.flate.Decompress.init(&reader, .zlib, &.{});
        inflated = decompressor.reader.allocRemaining(allocator, .limited(G.max_bitmap)) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidImage;
        if (decompressor.container_metadata.zlib.adler != std.hash.Adler32.hash(inflated.?)) return error.InvalidImage;
        break :blk inflated.?;
    } else if (h.o == 0) bytes else return error.UnsupportedImage;
    if (h.f == 100) {
        const decode = self.options.decoder orelse return error.UnsupportedImage;
        if (!std.mem.startsWith(u8, input, "\x89PNG\r\n\x1a\n")) return error.InvalidImage;
        if (h.o == 'z' and (h.S == 0 or h.S != input.len)) return error.InvalidImage;
        return decode(allocator, input);
    }
    if (h.f != 24 and h.f != 32) return error.UnsupportedImage;
    const n = try G.byteSize(h.s, h.v);
    const channels: usize = if (h.f == 24) 3 else 4;
    if (input.len != n / 4 * channels) return error.InvalidImage;
    const pixels = try allocator.alloc(u8, n);
    for (0..n / 4) |i| {
        @memcpy(pixels[i * 4 ..][0..3], input[i * channels ..][0..3]);
        pixels[i * 4 + 3] = if (channels == 4) input[i * channels + 3] else 255;
    }
    return .{ .width = h.s, .height = h.v, .pixels = pixels };
}
fn kitty(self: *Protocol, session: anytype) !void {
    const bytes = self.buffer.items;
    if (bytes.len == 0 or bytes[0] != 'G') return;
    const sep = std.mem.indexOfScalar(u8, bytes, ';') orelse bytes.len;
    if (sep > 4096) return error.InvalidImage;
    var h = try header(bytes[1..sep]);
    if (self.multipart) {
        self.multipart = false;
        self.pending.clearRetainingCapacity();
    }
    if (!self.kitty_pending) self.reply_header = h;
    if (h.t != 'd' or h.U != 0 or h.P != 0 or h.Q != 0) return error.UnsupportedImage;
    if (h.a == 'd') {
        self.delete(session, h);
        return;
    }
    if (h.a == 'p') {
        const asset = session.screen.graphics.get(h.i, h.I) orelse return error.ImageNotFound;
        h.i = asset.id;
        try place(session, h, asset.bitmap, .kitty);
        try response(session, h, "OK", true);
        return;
    }
    if (h.a != 't' and h.a != 'T' and h.a != 'q') return error.UnsupportedImage;
    const data = try base64(session.allocator, if (sep < bytes.len) bytes[sep + 1 ..] else "");
    defer session.allocator.free(data);
    if (!self.kitty_pending) {
        self.pending.clearRetainingCapacity();
        self.kitty_header = h;
    }
    try self.append(session.allocator, data);
    self.kitty_pending = h.m == 1;
    if (self.kitty_pending) return;
    h = self.kitty_header;
    defer self.pending.clearRetainingCapacity();
    const d = try self.decoded(session.allocator, h, self.pending.items);
    var owns = true;
    defer if (owns) session.allocator.free(d.pixels);
    const bitmap = try session.screen.graphics.bitmap(d);
    owns = false;
    defer bitmap.release();
    if (h.a != 'q') {
        var placement = if (h.a == 'T') try makePlacement(session, h, bitmap, .kitty) else null;
        if (placement) |p| try session.screen.graphics.preparePlacement(p);
        if (h.i == 0 and h.I == 0) {
            if (placement) |*p| {
                p.id = 0;
                try publishPlacement(session, h, p.*);
            }
            return;
        }
        const id = try session.screen.graphics.put(h.i, h.I, bitmap);
        h.i = id;
        if (placement) |*p| {
            p.image_id = id;
            try publishPlacement(session, h, p.*);
        }
    }
    if (self.reply_header.i != 0 or self.reply_header.I != 0) try response(session, h, "OK", true);
}
fn delete(self: *Protocol, session: anytype, h: Header) void {
    _ = self;
    const graphics = &session.screen.graphics;
    const selector = std.ascii.toLower(h.d);
    const data = std.ascii.isUpper(h.d);
    if (selector == 'a') {
        graphics.delete(0, 0, data);
    } else if (selector == 'i' or selector == 'n') {
        if (graphics.get(h.i, h.I)) |asset| graphics.delete(asset.id, h.p, data);
    } else {
        var i: usize = 0;
        while (i < graphics.placements.items.len) {
            const p = graphics.placements.items[i];
            const left = p.column;
            const top = p.row;
            const right = left + @as(i32, @intCast((p.width + p.cell_width - 1) / p.cell_width));
            const bottom = top + @as(i32, @intCast((p.height + p.cell_height - 1) / p.cell_height));
            const x: i64 = if (selector == 'c') @intCast(session.screen.cursor.column) else @as(i64, h.x) - 1;
            const y: i64 = if (selector == 'c') @intCast(session.screen.cursor.row) else @as(i64, h.y) - 1;
            const hit = switch (selector) {
                'p', 'c' => x >= left and x < right and y >= top and y < bottom,
                'q' => x >= left and x < right and y >= top and y < bottom and p.z == h.z,
                'x' => x >= left and x < right,
                'y' => y >= top and y < bottom,
                'z' => p.z == h.z,
                'r' => p.image_id >= h.x and p.image_id <= h.y,
                else => false,
            };
            if (hit) {
                p.bitmap.release();
                _ = graphics.placements.orderedRemove(i);
                if (data) {
                    var j: usize = 0;
                    while (j < graphics.assets.items.len) {
                        if (graphics.assets.items[j].id == p.image_id) {
                            graphics.assets.items[j].bitmap.release();
                            _ = graphics.assets.orderedRemove(j);
                        } else j += 1;
                    }
                }
            } else i += 1;
        }
    }
    session.screen.invalidateAll();
}
fn place(session: anytype, h: Header, bitmap: *G.Bitmap, protocol: @FieldType(G.Placement, "protocol")) !void {
    try publishPlacement(session, h, try makePlacement(session, h, bitmap, protocol));
}
fn makePlacement(session: anytype, h: Header, bitmap: *G.Bitmap, protocol: @FieldType(G.Placement, "protocol")) !G.Placement {
    const screen = &session.screen;
    const cw = @max(1, session.geometry.cell_width);
    const ch = @max(1, session.geometry.cell_height);
    if (h.x >= bitmap.width or h.y >= bitmap.height or h.X >= cw or h.Y >= ch) return error.InvalidImage;
    const sw = if (h.w == 0) bitmap.width - h.x else @min(h.w, bitmap.width - h.x);
    const sh = if (h.h == 0) bitmap.height - h.y else @min(h.h, bitmap.height - h.y);
    var width: usize = if (h.c == 0) sw else @as(usize, h.c) * cw;
    var height: usize = if (h.r == 0) sh else @as(usize, h.r) * ch;
    if (h.c != 0 and h.r == 0) height = @max(1, width * sh / sw);
    if (h.r != 0 and h.c == 0) width = @max(1, height * sw / sh);
    if (width > 1 << 24 or height > 1 << 24) return error.ImageTooLarge;
    const box_width = width;
    const box_height = height;
    if (h.c != 0 and h.r != 0) {
        if (width * sh <= height * sw) height = @max(1, width * sh / sw) else width = @max(1, height * sw / sh);
    }
    var p: G.Placement = .{ .bitmap = bitmap, .image_id = h.i, .id = h.p, .protocol = protocol, .row = @intCast(screen.cursor.row), .column = @intCast(screen.cursor.column), .x = @intCast(h.X), .y = @intCast(h.Y), .width = width, .height = height, .source_x = h.x, .source_y = h.y, .source_width = sw, .source_height = sh, .cell_width = cw, .cell_height = ch, .clip_bottom = @intCast(height), .clip_right = @intCast(width), .z = h.z };
    if (protocol == .sixel and session.graphics.sixel_display) {
        p.row = 0;
        p.column = 0;
    }
    if (h.c != 0 and h.r != 0) {
        p.x += @intCast((box_width - width) / 2);
        p.y += @intCast((box_height - height) / 2);
    }
    return p;
}
fn publishPlacement(session: anytype, h: Header, placement: G.Placement) !void {
    var p = placement;
    const screen = &session.screen;
    const cw = p.cell_width;
    const ch = p.cell_height;
    try screen.graphics.preparePlacement(p);
    if (h.C == 0 and !(p.protocol == .sixel and session.graphics.sixel_display)) {
        const rows = if (h.r != 0) h.r else (p.height + h.Y + ch - 1) / ch;
        const remaining = screen.scroll_bottom -| screen.cursor.row;
        const move = @min(rows, screen.rows + remaining);
        for (0..move) |_| {
            if (screen.cursor.row == screen.scroll_bottom - 1 and (!screen.left_right_mode or (screen.cursor.column >= screen.scroll_left and screen.cursor.column < screen.scroll_right))) p.row -= 1;
            try screen.apply(.{ .esc = .{ .intermediates = "", .final = 'D' } });
        }
        if (p.protocol != .sixel or session.graphics.sixel_right) screen.cursor.column = @min(screen.columns - 1, screen.cursor.column + (if (h.c != 0) h.c else (p.width + h.X + cw - 1) / cw));
        screen.wrap_pending = false;
    }
    try screen.graphics.place(p);
    screen.graphics.clip(screen.rows, screen.columns);
    screen.invalidateAll();
}
fn sixel(self: *Protocol, session: anytype) !void {
    var colors = if (self.sixel_private) Sixel.palette() else self.colors;
    const d = try Sixel.decode(session.allocator, self.buffer.items, self.sixel_params, &colors);
    var owns = true;
    defer if (owns) session.allocator.free(d.pixels);
    const bitmap = try session.screen.graphics.bitmap(d);
    owns = false;
    defer bitmap.release();
    try place(session, .{ .a = 'T', .z = 0 }, bitmap, .sixel);
    if (!self.sixel_private) self.colors = colors;
}
fn dimension(value: []const u8, cell: usize, total: usize) !usize {
    if (std.mem.eql(u8, value, "auto")) return 0;
    if (std.mem.endsWith(u8, value, "px")) return std.fmt.parseInt(usize, value[0 .. value.len - 2], 10) catch return error.InvalidImage;
    if (std.mem.endsWith(u8, value, "%")) {
        const n = std.fmt.parseInt(usize, value[0 .. value.len - 1], 10) catch return error.InvalidImage;
        if (n > 100) return error.InvalidImage;
        return @max(1, total * n / 100);
    }
    const n = std.fmt.parseInt(usize, value, 10) catch return error.InvalidImage;
    return std.math.mul(usize, n, cell) catch return error.InvalidImage;
}
fn iterm(self: *Protocol, session: anytype) !void {
    const bytes = self.buffer.items;
    if (!std.mem.startsWith(u8, bytes, "1337;")) return;
    const command = bytes[5..];
    if (self.kitty_pending) {
        self.kitty_pending = false;
        self.pending.clearRetainingCapacity();
    }
    if (std.mem.startsWith(u8, command, "MultipartFile=")) {
        self.multipart = false;
        self.pending.clearRetainingCapacity();
        const args = command[14..];
        if (args.len > self.multipart_header.len) return error.InvalidImage;
        @memcpy(self.multipart_header[0..args.len], args);
        self.multipart_len = args.len;
        self.multipart = true;
        return;
    }
    if (std.mem.startsWith(u8, command, "FilePart=")) {
        if (!self.multipart) return;
        // FilePart is a slice of the base64 stream, possibly split mid-quartet.
        const part = command[9..];
        if (self.pending.items.len + part.len > (G.max_transfer + 2) / 3 * 4) return error.ImageTooLarge;
        try self.reserve(session.allocator, &self.pending, part.len);
        self.pending.appendSliceAssumeCapacity(part);
        return;
    }
    var args: []const u8 = undefined;
    var payload: []const u8 = undefined;
    if (std.mem.eql(u8, command, "FileEnd")) {
        if (!self.multipart) return;
        args = self.multipart_header[0..self.multipart_len];
        payload = self.pending.items;
    } else if (std.mem.startsWith(u8, command, "File=")) {
        const colon = std.mem.indexOfScalar(u8, command, ':') orelse return error.InvalidImage;
        args = command[5..colon];
        payload = command[colon + 1 ..];
    } else return;
    defer {
        self.multipart = false;
        self.pending.clearRetainingCapacity();
    }
    if (args.len > 4096) return error.InvalidImage;
    var inline_: bool = false;
    var aspect = true;
    var width: usize = 0;
    var height: usize = 0;
    const cw = @max(1, session.geometry.cell_width);
    const ch = @max(1, session.geometry.cell_height);
    var fields = std.mem.splitScalar(u8, args, ';');
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..equal];
        const value = field[equal + 1 ..];
        if (std.mem.eql(u8, key, "inline")) inline_ = std.mem.eql(u8, value, "1") else if (std.mem.eql(u8, key, "preserveAspectRatio")) aspect = !std.mem.eql(u8, value, "0") else if (std.mem.eql(u8, key, "width")) width = try dimension(value, cw, screenWidth(session, cw)) else if (std.mem.eql(u8, key, "height")) height = try dimension(value, ch, session.screen.rows * ch);
    }
    if (!inline_) return;
    if (width > 1 << 24 or height > 1 << 24) return error.ImageTooLarge;
    const decode = self.options.decoder orelse return error.UnsupportedImage;
    const data = try base64(session.allocator, payload);
    defer session.allocator.free(data);
    const d = try decode(session.allocator, data);
    var owns = true;
    defer if (owns) session.allocator.free(d.pixels);
    const bitmap = try session.screen.graphics.bitmap(d);
    owns = false;
    defer bitmap.release();
    if (width == 0 and height == 0) width = @min(d.width, screenWidth(session, cw));
    if (width == 0) width = @max(1, height * d.width / d.height);
    if (height == 0) height = @max(1, width * d.height / d.width);
    if (width > 1 << 24 or height > 1 << 24) return error.ImageTooLarge;
    if (aspect) {
        if (width * d.height <= height * d.width) height = @max(1, width * d.height / d.width) else width = @max(1, height * d.width / d.height);
    }
    const p: G.Placement = .{ .bitmap = bitmap, .protocol = .iterm, .row = @intCast(session.screen.cursor.row), .column = @intCast(session.screen.cursor.column), .width = width, .height = height, .source_width = d.width, .source_height = d.height, .cell_width = cw, .cell_height = ch, .clip_bottom = @intCast(height), .clip_right = @intCast(width), .z = 0 };
    try publishPlacement(session, .{}, p);
    session.screen.cursor.column = 0;
    session.screen.invalidateAll();
}
fn screenWidth(session: anytype, cw: usize) usize {
    return session.screen.columns * cw;
}
