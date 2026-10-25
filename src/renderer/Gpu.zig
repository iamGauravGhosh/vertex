//! EGL/GLES3 presentation with a retained framebuffer and alpha-mask atlas textures.
const std = @import("std");
const c = @import("c");
const Renderer = @import("root.zig");
const Atlas = Renderer.Atlas;
const Gpu = @This();
const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32, r: f32, g: f32, b: f32, a: f32 };
const SwapDamage = *const fn (c.EGLDisplay, c.EGLSurface, [*c]const c.EGLint, c.EGLint) callconv(.c) c.EGLBoolean;
const ImageTexture = struct { texture: c.GLuint = 0, identity: u64 = 0, bytes: usize = 0, used: u64 = 0 };

pub const Mode = enum {
    auto,
    gpu,
    cpu,
    pub fn parse(value: ?[]const u8) !Mode {
        const name = value orelse return .auto;
        inline for (.{ "auto", "gpu", "cpu" }) |candidate| if (std.mem.eql(u8, name, candidate)) return @field(Mode, candidate);
        return error.InvalidRenderer;
    }
};
allocator: std.mem.Allocator,
display: c.EGLDisplay = null,
context: c.EGLContext = null,
surface: c.EGLSurface = null,
native: ?*c.wl_egl_window = null,
width: usize = 0,
height: usize = 0,
program: c.GLuint = 0,
vao: c.GLuint = 0,
vbo: c.GLuint = 0,
fbo: c.GLuint = 0,
color_texture: c.GLuint = 0,
textures: [Atlas.page_count]c.GLuint = @splat(0),
texture_ready: [Atlas.page_count]bool = @splat(false),
atlas_revisions: [Atlas.page_count]u64 = @splat(std.math.maxInt(u64)),
vertices: std.ArrayList(Vertex) = .empty,
masked: bool = false,
page: usize = 0,
viewport_uniform: c.GLint = -1,
masked_uniform: c.GLint = -1,
swap_damage: ?SwapDamage = null,
damage_rects: std.ArrayList(c.EGLint) = .empty,
images: [8]ImageTexture = @splat(.{}),
image_clock: u64 = 0,

pub fn init(allocator: std.mem.Allocator, display: *c.wl_display, surface: *c.wl_surface, width: usize, height: usize) !Gpu {
    return create(allocator, display, surface, width, height);
}

/// Surfaceless Mesa pbuffer for real shader/readback tests without a compositor.
pub fn initHeadless(allocator: std.mem.Allocator, width: usize, height: usize) !Gpu {
    return create(allocator, null, null, width, height);
}

fn create(allocator: std.mem.Allocator, wayland: ?*c.wl_display, surface: ?*c.wl_surface, width: usize, height: usize) !Gpu {
    var self: Gpu = .{ .allocator = allocator };
    errdefer self.deinit();
    self.display = c.eglGetPlatformDisplay(if (wayland != null) c.EGL_PLATFORM_WAYLAND_KHR else c.EGL_PLATFORM_SURFACELESS_MESA, wayland, null);
    if (self.display == null or c.eglInitialize(self.display, null, null) == c.EGL_FALSE) return error.EglInitializeFailed;
    if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == c.EGL_FALSE) return error.EglBindFailed;
    const attributes = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    if (surface != null) c.EGL_WINDOW_BIT else c.EGL_PBUFFER_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_DEPTH_SIZE,      0,
        c.EGL_STENCIL_SIZE,    0,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var count: c.EGLint = 0;
    if (c.eglChooseConfig(self.display, &attributes, &config, 1, &count) == c.EGL_FALSE or count == 0) return error.EglConfigFailed;
    self.context = c.eglCreateContext(self.display, config, null, &[_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 3, c.EGL_NONE });
    if (self.context == null) return error.EglContextFailed;
    if (surface) |wl_surface| {
        self.native = c.wl_egl_window_create(wl_surface, @intCast(width), @intCast(height)) orelse return error.EglWindowFailed;
        self.surface = c.eglCreatePlatformWindowSurface(self.display, config, self.native, null);
    } else {
        self.surface = c.eglCreatePbufferSurface(self.display, config, &[_]c.EGLint{ c.EGL_WIDTH, @intCast(width), c.EGL_HEIGHT, @intCast(height), c.EGL_NONE });
    }
    if (self.surface == null) return error.EglSurfaceFailed;
    try self.makeCurrent();
    // Wayland frame callbacks provide pacing; avoid an additional swap-interval wait.
    _ = c.eglSwapInterval(self.display, 0);
    const extensions_ptr = c.eglQueryString(self.display, c.EGL_EXTENSIONS);
    const extensions = if (extensions_ptr != null) std.mem.span(extensions_ptr) else "";
    if (hasExtension(extensions, "EGL_KHR_swap_buffers_with_damage")) {
        self.swap_damage = @ptrCast(c.eglGetProcAddress("eglSwapBuffersWithDamageKHR"));
    } else if (hasExtension(extensions, "EGL_EXT_swap_buffers_with_damage")) {
        self.swap_damage = @ptrCast(c.eglGetProcAddress("eglSwapBuffersWithDamageEXT"));
    }
    try self.initGl();
    try self.resize(width, height);
    return self;
}

fn hasExtension(extensions: []const u8, name: []const u8) bool {
    var tokens = std.mem.tokenizeScalar(u8, extensions, ' ');
    while (tokens.next()) |token| if (std.mem.eql(u8, token, name)) return true;
    return false;
}

fn makeCurrent(self: *Gpu) !void {
    if (c.eglMakeCurrent(self.display, self.surface, self.surface, self.context) == c.EGL_FALSE) return error.EglContextLost;
}

fn shader(kind: c.GLenum, source: [:0]const u8) !c.GLuint {
    const object = c.glCreateShader(kind);
    if (object == 0) return error.ShaderCreateFailed;
    errdefer c.glDeleteShader(object);
    const pointer: [*c]const c.GLchar = source.ptr;
    c.glShaderSource(object, 1, &pointer, null);
    c.glCompileShader(object);
    var status: c.GLint = 0;
    c.glGetShaderiv(object, c.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log: [2048]u8 = undefined;
        var length: c.GLsizei = 0;
        c.glGetShaderInfoLog(object, log.len, &length, &log);
        std.debug.print("vertex: GPU shader: {s}\n", .{log[0..@intCast(@max(0, length))]});
        return error.ShaderCompileFailed;
    }
    return object;
}

fn initGl(self: *Gpu) !void {
    const vs = try shader(c.GL_VERTEX_SHADER,
        \\#version 300 es
        \\layout(location=0) in vec2 position;
        \\layout(location=1) in vec2 texcoord;
        \\layout(location=2) in vec4 color;
        \\uniform vec2 viewport;
        \\out vec2 uv;
        \\out vec4 rgba;
        \\void main() {
        \\  gl_Position = vec4(position.x / viewport.x * 2.0 - 1.0, 1.0 - position.y / viewport.y * 2.0, 0, 1);
        \\  uv = texcoord; rgba = color;
        \\}
    );
    defer c.glDeleteShader(vs);
    const fs = try shader(c.GL_FRAGMENT_SHADER,
        \\#version 300 es
        \\precision highp float;
        \\uniform sampler2D atlas;
        \\uniform bool masked;
        \\in vec2 uv;
        \\in vec4 rgba;
        \\out vec4 output_color;
        \\void main() { output_color = masked ? texture(atlas, uv) * rgba : rgba; }
    );
    defer c.glDeleteShader(fs);
    self.program = c.glCreateProgram();
    c.glAttachShader(self.program, vs);
    c.glAttachShader(self.program, fs);
    c.glLinkProgram(self.program);
    var status: c.GLint = 0;
    c.glGetProgramiv(self.program, c.GL_LINK_STATUS, &status);
    if (status == 0) return error.ShaderLinkFailed;
    self.viewport_uniform = c.glGetUniformLocation(self.program, "viewport");
    self.masked_uniform = c.glGetUniformLocation(self.program, "masked");
    c.glGenVertexArrays(1, &self.vao);
    c.glBindVertexArray(self.vao);
    c.glGenBuffers(1, &self.vbo);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glEnableVertexAttribArray(0);
    c.glEnableVertexAttribArray(1);
    c.glEnableVertexAttribArray(2);
    c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), null);
    c.glVertexAttribPointer(1, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(2 * @sizeOf(f32)));
    c.glVertexAttribPointer(2, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(4 * @sizeOf(f32)));
    c.glGenTextures(Atlas.page_count, &self.textures);
    c.glGenTextures(1, &self.color_texture);
    c.glBindTexture(c.GL_TEXTURE_2D, self.color_texture);
    textureParameters();
    c.glGenFramebuffers(1, &self.fbo);
    c.glEnable(c.GL_BLEND);
    c.glBlendFuncSeparate(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA, c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glDisable(c.GL_DITHER);
    c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
    try checkGl();
}

fn textureParameters() void {
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
}
fn checkGl() !void {
    if (c.glGetError() != c.GL_NO_ERROR) return error.GpuRenderingFailed;
}

pub fn resize(self: *Gpu, width: usize, height: usize) !void {
    if (width == self.width and height == self.height) return;
    try self.makeCurrent();
    var maximum: c.GLint = 0;
    c.glGetIntegerv(c.GL_MAX_TEXTURE_SIZE, &maximum);
    if (width == 0 or height == 0 or width > maximum or height > maximum) return error.GpuSurfaceTooLarge;
    if (self.native) |native| c.wl_egl_window_resize(native, @intCast(width), @intCast(height), 0, 0);
    c.glBindTexture(c.GL_TEXTURE_2D, self.color_texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, @intCast(width), @intCast(height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
    c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.color_texture, 0);
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return error.GpuFramebufferFailed;
    self.width = width;
    self.height = height;
    c.glViewport(0, 0, @intCast(width), @intCast(height));
    try checkGl();
}

pub fn render(self: *Gpu, renderer: *Renderer, screen: *const @import("../terminal/root.zig").Screen, damage: *const Renderer.Damage) !void {
    try self.makeCurrent();
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
    c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
    if (damage.full) try self.fill(.{ .x = 0, .y = 0, .width = @intCast(self.width), .height = @intCast(self.height) }, renderer.background());
    try renderer.paint(screen, damage.rows, self);
    try checkGl();
}

pub fn present(self: *Gpu, rects: []const Renderer.Damage.Rect) !void {
    // Always supply a complete backbuffer; swap-with-damage does not preserve it.
    c.glBindFramebuffer(c.GL_READ_FRAMEBUFFER, self.fbo);
    c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
    c.glBlitFramebuffer(0, 0, @intCast(self.width), @intCast(self.height), 0, 0, @intCast(self.width), @intCast(self.height), c.GL_COLOR_BUFFER_BIT, c.GL_NEAREST);
    try checkGl();
    var result: c.EGLBoolean = undefined;
    if (self.swap_damage) |swap| {
        self.damage_rects.clearRetainingCapacity();
        for (rects) |r| try self.damage_rects.appendSlice(self.allocator, &.{ r.x, @as(i32, @intCast(self.height)) - r.y - r.height, r.width, r.height });
        result = swap(self.display, self.surface, self.damage_rects.items.ptr, @intCast(rects.len));
    } else result = c.eglSwapBuffers(self.display, self.surface);
    if (result == c.EGL_FALSE) return error.EglSwapFailed;
}

pub fn flush(self: *Gpu) !void {
    if (self.vertices.items.len == 0) return;
    c.glUseProgram(self.program);
    c.glUniform2f(self.viewport_uniform, @floatFromInt(self.width), @floatFromInt(self.height));
    c.glUniform1i(self.masked_uniform, @intFromBool(self.masked));
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, self.textures[self.page]);
    c.glBindVertexArray(self.vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(self.vertices.items.len * @sizeOf(Vertex)), self.vertices.items.ptr, c.GL_STREAM_DRAW);
    if (self.masked) c.glEnable(c.GL_BLEND) else c.glDisable(c.GL_BLEND);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(self.vertices.items.len));
    self.vertices.clearRetainingCapacity();
    try checkGl();
}

fn quad(self: *Gpu, rect: Renderer.Rect, uv: [4]f32, rgb: u32, masked: bool, page: usize) !void {
    if (rect.width <= 0 or rect.height <= 0) return;
    if (self.masked != masked or self.page != page or self.vertices.items.len >= 6 * 1024) try self.flush();
    self.masked = masked;
    self.page = page;
    const x: f32 = @floatFromInt(rect.x);
    const y: f32 = @floatFromInt(rect.y);
    const right: f32 = @floatFromInt(rect.x + rect.width);
    const bottom: f32 = @floatFromInt(rect.y + rect.height);
    const r = @as(f32, @floatFromInt((rgb >> 16) & 255)) / 255;
    const g = @as(f32, @floatFromInt((rgb >> 8) & 255)) / 255;
    const b = @as(f32, @floatFromInt(rgb & 255)) / 255;
    const alpha = @as(f32, @floatFromInt(rgb >> 24)) / 255;
    const a: Vertex = .{ .x = x, .y = y, .u = uv[0], .v = uv[1], .r = r, .g = g, .b = b, .a = alpha };
    const tr: Vertex = .{ .x = right, .y = y, .u = uv[2], .v = uv[1], .r = r, .g = g, .b = b, .a = alpha };
    const br: Vertex = .{ .x = right, .y = bottom, .u = uv[2], .v = uv[3], .r = r, .g = g, .b = b, .a = alpha };
    const bl: Vertex = .{ .x = x, .y = bottom, .u = uv[0], .v = uv[3], .r = r, .g = g, .b = b, .a = alpha };
    try self.vertices.appendSlice(self.allocator, &.{ a, tr, br, a, br, bl });
}
fn bounds(self: *Gpu) Renderer.Rect {
    return .{ .x = 0, .y = 0, .width = @intCast(self.width), .height = @intCast(self.height) };
}
pub fn fill(self: *Gpu, rect: Renderer.Rect, rgb: u32) !void {
    try self.quad(Renderer.intersect(rect, self.bounds()), .{ 0, 0, 0, 0 }, rgb, false, 0);
}
pub fn mask(self: *Gpu, atlas: *Atlas, region: Atlas.Region, x: i32, y: i32, clip: Renderer.Rect, rgb: u32) !void {
    if (self.atlas_revisions[region.page] != atlas.pages[region.page].revision) {
        try self.flush();
        try self.syncPage(atlas, region.page);
    }
    const r = Renderer.intersect(Renderer.intersect(.{ .x = x, .y = y, .width = @intCast(region.width), .height = @intCast(region.height) }, clip), self.bounds());
    const ax = @as(f32, @floatFromInt(@as(i32, @intCast(region.x)) + r.x - x));
    const ay = @as(f32, @floatFromInt(@as(i32, @intCast(region.y)) + r.y - y));
    try self.quad(r, .{ ax / Atlas.size, ay / Atlas.size, (ax + @as(f32, @floatFromInt(r.width))) / Atlas.size, (ay + @as(f32, @floatFromInt(r.height))) / Atlas.size }, if (region.color) 0xffffffff else rgb, true, region.page);
}
pub fn upload(self: *Gpu, atlas: *Atlas, region: Atlas.Region) !void {
    // A CPU painter may have populated this page since our last draw. A partial
    // upload is sufficient only when this insertion is the sole unseen change.
    if (!self.texture_ready[region.page] or self.atlas_revisions[region.page] != atlas.pages[region.page].revision -% 1) {
        return self.syncPage(atlas, region.page);
    }
    c.glBindTexture(c.GL_TEXTURE_2D, self.textures[region.page]);
    c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, Atlas.size);
    c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, @intCast(region.x), @intCast(region.y), @intCast(region.width), @intCast(region.height), c.GL_RGBA, c.GL_UNSIGNED_BYTE, atlas.pages[region.page].pixels.ptr + (region.y * Atlas.size + region.x) * 4);
    c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
    self.atlas_revisions[region.page] = atlas.pages[region.page].revision;
    try checkGl();
}

pub fn image(self: *Gpu, value: Renderer.Image) !void {
    try self.flush();
    self.image_clock +%= 1;
    var index: ?usize = null;
    for (self.images, 0..) |slot, i| if (slot.identity == value.bitmap.identity) {
        index = i;
        break;
    };
    if (index == null) {
        var victim: usize = 0;
        var total: usize = 0;
        for (self.images, 0..) |slot, i| {
            total += slot.bytes;
            if (slot.used < self.images[victim].used) victim = i;
        }
        // Both the number of textures and total GPU image storage are bounded.
        while (total + value.bitmap.pixels.len > 64 * 1024 * 1024) {
            const old = &self.images[victim];
            total -= old.bytes;
            if (old.texture != 0) c.glDeleteTextures(1, &old.texture);
            old.* = .{};
            victim = 0;
            var found = false;
            for (self.images, 0..) |slot, i| if (slot.bytes != 0 and (!found or slot.used < self.images[victim].used)) {
                victim = i;
                found = true;
            };
        }
        // Prefer an empty slot after budget eviction.
        for (self.images, 0..) |slot, i| if (slot.texture == 0) {
            victim = i;
            break;
        };
        const slot = &self.images[victim];
        if (slot.texture == 0) c.glGenTextures(1, &slot.texture);
        c.glBindTexture(c.GL_TEXTURE_2D, slot.texture);
        textureParameters();
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, @intCast(value.bitmap.width), @intCast(value.bitmap.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, value.bitmap.pixels.ptr);
        slot.identity = value.bitmap.identity;
        slot.bytes = value.bitmap.pixels.len;
        index = victim;
    }
    const slot = &self.images[index.?];
    slot.used = self.image_clock;
    const r = Renderer.intersect(Renderer.intersect(value.destination, value.clip), self.bounds());
    if (r.width <= 0 or r.height <= 0) return;
    const d = value.destination;
    const s = value.source;
    const bw: f32 = @floatFromInt(value.bitmap.width);
    const bh: f32 = @floatFromInt(value.bitmap.height);
    const sw: f32 = @floatFromInt(s.width);
    const sh: f32 = @floatFromInt(s.height);
    const dw: f32 = @floatFromInt(d.width);
    const dh: f32 = @floatFromInt(d.height);
    const l = (@as(f32, @floatFromInt(s.x)) + @as(f32, @floatFromInt(r.x - d.x)) * sw / dw) / bw;
    const t = (@as(f32, @floatFromInt(s.y)) + @as(f32, @floatFromInt(r.y - d.y)) * sh / dh) / bh;
    const right = (@as(f32, @floatFromInt(s.x)) + @as(f32, @floatFromInt(r.x + r.width - d.x)) * sw / dw) / bw;
    const bottom = (@as(f32, @floatFromInt(s.y)) + @as(f32, @floatFromInt(r.y + r.height - d.y)) * sh / dh) / bh;
    try self.quad(r, .{ l, t, right, bottom }, 0xffffffff, true, 0);
    // Image quads use their own texture, rather than a glyph atlas page.
    c.glEnable(c.GL_BLEND);
    c.glUseProgram(self.program);
    c.glUniform2f(self.viewport_uniform, @floatFromInt(self.width), @floatFromInt(self.height));
    c.glUniform1i(self.masked_uniform, 1);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, slot.texture);
    c.glBindVertexArray(self.vao);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
    c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(self.vertices.items.len * @sizeOf(Vertex)), self.vertices.items.ptr, c.GL_STREAM_DRAW);
    c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(self.vertices.items.len));
    self.vertices.clearRetainingCapacity();
    try checkGl();
}

/// A new renderer can reuse atlas revision numbers; its textures must be uploaded.
pub fn invalidateAtlas(self: *Gpu) void {
    self.texture_ready = @splat(false);
    self.atlas_revisions = @splat(std.math.maxInt(u64));
}
/// Upload existing CPU pages when initializing or switching to a GPU context.
pub fn syncAtlas(self: *Gpu, atlas: *Atlas) !void {
    for (&atlas.pages, 0..) |*page, i| {
        if (page.pixels.len == 0) continue;
        try self.syncPage(atlas, i);
    }
    try checkGl();
}

fn syncPage(self: *Gpu, atlas: *Atlas, index: usize) !void {
    c.glBindTexture(c.GL_TEXTURE_2D, self.textures[index]);
    textureParameters();
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, Atlas.size, Atlas.size, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, atlas.pages[index].pixels.ptr);
    self.texture_ready[index] = true;
    self.atlas_revisions[index] = atlas.pages[index].revision;
    try checkGl();
}

pub fn readPixels(self: *Gpu, rgba: []u8) !void {
    std.debug.assert(rgba.len == self.width * self.height * 4);
    try self.makeCurrent();
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
    c.glReadPixels(0, 0, @intCast(self.width), @intCast(self.height), c.GL_RGBA, c.GL_UNSIGNED_BYTE, rgba.ptr);
    try checkGl();
}

pub fn deinit(self: *Gpu) void {
    if (self.context != null and self.surface != null and c.eglMakeCurrent(self.display, self.surface, self.surface, self.context) != c.EGL_FALSE) {
        c.glDeleteFramebuffers(1, &self.fbo);
        c.glDeleteTextures(1, &self.color_texture);
        c.glDeleteTextures(Atlas.page_count, &self.textures);
        for (&self.images) |*slot| if (slot.texture != 0) {
            c.glDeleteTextures(1, &slot.texture);
        };
        c.glDeleteBuffers(1, &self.vbo);
        c.glDeleteVertexArrays(1, &self.vao);
        if (self.program != 0) c.glDeleteProgram(self.program);
        _ = c.eglMakeCurrent(self.display, null, null, null);
    }
    if (self.surface != null) _ = c.eglDestroySurface(self.display, self.surface);
    if (self.native) |native| c.wl_egl_window_destroy(native);
    if (self.context != null) _ = c.eglDestroyContext(self.display, self.context);
    if (self.display != null) _ = c.eglTerminate(self.display);
    self.vertices.deinit(self.allocator);
    self.damage_rects.deinit(self.allocator);
}

test "renderer mode parsing is explicit and extension matching uses whole tokens" {
    try std.testing.expectEqual(Mode.auto, try Mode.parse(null));
    try std.testing.expectEqual(Mode.gpu, try Mode.parse("gpu"));
    try std.testing.expectEqual(Mode.cpu, try Mode.parse("cpu"));
    try std.testing.expectError(error.InvalidRenderer, Mode.parse("unknown"));
    try std.testing.expect(!hasExtension("EGL_KHR_swap_buffers_with_damage_extra", "EGL_KHR_swap_buffers_with_damage"));
}
