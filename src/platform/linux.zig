//! Native Wayland window, keyboard state, and the single-threaded PTY loop.
const std = @import("std");
const c = @import("c");
const vt = @import("../terminal/root.zig");
const Renderer = @import("../renderer/root.zig");
const Gpu = @import("../renderer/Gpu.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");
const common = @import("common.zig");

const Output = struct { app: *App, name: u32, object: *c.wl_output, scale: usize = 1, entered: bool = false };
const Buffer = struct {
    object: *c.wl_buffer,
    pixels: []u32,
    width: usize,
    height: usize,
    busy: bool = false,
    retired: bool = false,
    pending_rows: []bool,
    full_pending: bool = true,

    fn track(self: *Buffer, damage: *const Renderer.Damage) void {
        if (damage.full) self.full_pending = true;
        for (damage.rows, self.pending_rows) |changed, *pending| pending.* = pending.* or changed;
    }

    fn sync(self: *Buffer, pixels: []const u32, cell_height: usize) void {
        std.debug.assert(!self.busy);
        if (self.full_pending) {
            @memcpy(self.pixels, pixels);
        } else for (self.pending_rows, 0..) |changed, row| {
            if (!changed) continue;
            const start = @min(self.height, row * cell_height) * self.width;
            const end = @min(self.height, (row + 1) * cell_height) * self.width;
            @memcpy(self.pixels[start..end], pixels[start..end]);
        }
        self.full_pending = false;
        @memset(self.pending_rows, false);
    }
};

pub fn run(allocator: std.mem.Allocator, command: []const []const u8) !u8 {
    const mode_name = c.getenv("VERTEX_RENDERER");
    const mode = Gpu.Mode.parse(if (mode_name != null) std.mem.span(mode_name) else null) catch {
        std.debug.print("vertex: VERTEX_RENDERER must be auto, gpu, or cpu\n", .{});
        return error.InvalidRenderer;
    };
    var app: App = .{
        .allocator = allocator,
        .renderer = try Renderer.init(allocator),
        .screen = undefined,
        .mode = mode,
        .damage = Renderer.Damage.init(allocator),
    };
    defer app.deinit();
    app.screen = try vt.Screen.init(allocator, 24, 80);
    app.screen_ready = true;
    app.width = 80 * app.renderer.cell_width;
    app.height = 24 * app.renderer.cell_height;
    try app.connect();
    return app.loop(command);
}

const App = struct {
    allocator: std.mem.Allocator,
    renderer: Renderer,
    screen: vt.Screen,
    screen_ready: bool = false,
    mode: Gpu.Mode = .auto,
    gpu: ?Gpu = null,
    backend_started: bool = false,
    damage: ?Renderer.Damage = null,
    pixels: []u32 = &.{},
    parser: vt.Parser = vt.Parser.init(),
    pty: ?Pty = null,
    pty_eof: bool = false,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    wm: ?*c.xdg_wm_base = null,
    surface: ?*c.wl_surface = null,
    xdg_surface: ?*c.xdg_surface = null,
    toplevel: ?*c.xdg_toplevel = null,
    frame: ?*c.wl_callback = null,
    seat: ?*c.wl_seat = null,
    keyboard: ?*c.wl_keyboard = null,
    xkb_context: ?*c.xkb_context = null,
    keymap: ?*c.xkb_keymap = null,
    key_state: ?*c.xkb_state = null,
    compose_table: ?*c.xkb_compose_table = null,
    compose_state: ?*c.xkb_compose_state = null,
    repeat_fd: c_int = -1,
    repeat_rate: i32 = 0,
    repeat_delay: i32 = 0,
    repeat_key: ?u32 = null,
    composed_symbol: u32 = 0,
    composed_text: [96]u8 = undefined,
    composed_length: usize = 0,
    focused: bool = false,
    outputs: std.ArrayList(*Output) = .empty,
    buffers: std.ArrayList(*Buffer) = .empty,
    pending: std.ArrayList(u8) = .empty,
    width: usize = 0,
    height: usize = 0,
    pending_width: usize = 0,
    pending_height: usize = 0,
    scale: usize = 1,
    configured: bool = false,
    size_changed: bool = true,
    closing: bool = false,
    failure: ?anyerror = null,

    fn connect(self: *App) !void {
        self.display = c.wl_display_connect(null) orelse {
            std.debug.print("vertex: cannot connect to Wayland; check WAYLAND_DISPLAY and XDG_RUNTIME_DIR\n", .{});
            return error.WaylandConnectFailed;
        };
        self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbFailed;
        const locale: [*c]const u8 = c.setlocale(c.LC_CTYPE, "") orelse @as([*c]const u8, "C");
        self.compose_table = c.xkb_compose_table_new_from_locale(self.xkb_context, locale, c.XKB_COMPOSE_COMPILE_NO_FLAGS);
        if (self.compose_table) |table| self.compose_state = c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS);
        self.repeat_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
        if (self.repeat_fd < 0) return error.TimerFailed;
        self.registry = c.wl_display_get_registry(self.display) orelse return error.WaylandObjectFailed;
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) return error.WaylandListenerFailed;
        if (c.wl_display_roundtrip(self.display) < 0 or c.wl_display_roundtrip(self.display) < 0) return error.WaylandDisconnected;
        if (self.failure) |failure| return failure;
        if (self.compositor == null or self.shm == null or self.wm == null) return error.RequiredWaylandGlobalMissing;
        self.surface = c.wl_compositor_create_surface(self.compositor) orelse return error.WaylandObjectFailed;
        _ = c.wl_surface_add_listener(self.surface, &surface_listener, self);
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm, self.surface) orelse return error.WaylandObjectFailed;
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);
        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.WaylandObjectFailed;
        _ = c.xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, self);
        c.xdg_toplevel_set_title(self.toplevel, "Vertex");
        c.xdg_toplevel_set_app_id(self.toplevel, "vertex");
        c.xdg_toplevel_set_min_size(self.toplevel, @intCast(self.renderer.cell_width), @intCast(self.renderer.cell_height));
        c.wl_surface_commit(self.surface);
    }

    fn loop(self: *App, command: []const []const u8) !u8 {
        while (!self.closing) {
            if (self.failure) |failure| return failure;
            if (self.configured) {
                try self.applySize();
                if (self.pty == null) self.pty = try Pty.spawn(self.allocator, command, self.screen.rows, self.screen.columns);
                try self.drainPty();
                if (try self.pty.?.pollExit()) |status| {
                    // Reap the child independently of descendants retaining the slave.
                    try self.drainPty();
                    for (self.parser.finish()) |event| if (event) |value| self.screen.handle(value);
                    return status;
                }
                try self.flushInput();
                try self.draw();
            }
            while (c.wl_display_prepare_read(self.display) != 0) {
                if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDisconnected;
            }
            var reading = true;
            defer if (reading) c.wl_display_cancel_read(self.display);
            var display_events: c_short = c.POLLIN;
            if (c.wl_display_flush(self.display) < 0) {
                if (common.errno() != c.EAGAIN) return error.WaylandDisconnected;
                display_events |= c.POLLOUT;
            }
            var fds = [_]c.pollfd{
                .{ .fd = c.wl_display_get_fd(self.display), .events = display_events, .revents = 0 },
                .{ .fd = if (self.pty != null and !self.pty_eof) self.pty.?.master else -1, .events = @as(c_short, c.POLLIN) | (if (self.pending.items.len > 0) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
                .{ .fd = self.repeat_fd, .events = c.POLLIN, .revents = 0 },
            };
            const result = c.poll(&fds, fds.len, 100);
            if (result < 0) {
                if (common.errno() == c.EINTR) continue;
                return error.PollFailed;
            }
            if ((fds[0].revents & c.POLLIN) != 0) {
                reading = false;
                if (c.wl_display_read_events(self.display) < 0) return error.WaylandDisconnected;
            } else {
                c.wl_display_cancel_read(self.display);
                reading = false;
            }
            if ((fds[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) return error.WaylandDisconnected;
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDisconnected;
            if ((fds[2].revents & c.POLLIN) != 0) {
                var repeats: u64 = 0;
                if (c.read(self.repeat_fd, &repeats, @sizeOf(u64)) > 0) {
                    if (self.repeat_key) |key| {
                        for (0..@min(repeats, 32)) |_| _ = try self.sendKey(key, false);
                    }
                }
            }
        }
        return 0;
    }

    fn applySize(self: *App) !void {
        if (!self.size_changed) return;
        if (self.width > 16384 or self.height > 16384) return error.WindowTooLarge;
        const area = std.math.mul(usize, self.width * self.scale, self.height * self.scale) catch return error.WindowTooLarge;
        if (area > 64 * 1024 * 1024) return error.WindowTooLarge;
        const rows = @max(1, self.height / self.renderer.cell_height);
        const columns = @max(1, self.width / self.renderer.cell_width);
        try self.screen.resize(rows, columns);
        if (self.pty) |*pty| try pty.resize(rows, columns);
        try self.renderer.setScale(self.scale);
        c.wl_surface_set_buffer_scale(self.surface, @intCast(self.scale));
        for (self.buffers.items) |buffer| {
            if (buffer.width != self.width * self.scale or buffer.height != self.height * self.scale or buffer.pending_rows.len != self.screen.rows) buffer.retired = true;
        }
        if (self.gpu) |*gpu| gpu.resize(self.width * self.scale, self.height * self.scale) catch |err| try self.disableGpu(err);
        self.size_changed = false;
        self.damage.?.invalidate();
    }

    fn drainPty(self: *App) !void {
        if (self.pty_eof) return;
        var bytes: [16384]u8 = undefined;
        var budget: usize = 256 * 1024;
        while (budget > 0) {
            const count = self.pty.?.read(&bytes) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (count == 0) {
                self.pty_eof = true;
                return;
            }
            self.parser.feed(bytes[0..count], &self.screen);
            budget -= count;
        }
    }

    fn flushInput(self: *App) !void {
        if (self.pty_eof) {
            self.pending.clearRetainingCapacity();
            return;
        }
        while (self.pending.items.len > 0) {
            const count = self.pty.?.write(self.pending.items) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (count == 0) return;
            std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - count], self.pending.items[count..]);
            self.pending.items.len -= count;
        }
    }

    fn disableGpu(self: *App, failure: anyerror) !void {
        if (failure == error.OutOfMemory or self.mode == .gpu) return failure;
        std.debug.print("vertex: GPU rendering unavailable ({s}); using CPU renderer\n", .{@errorName(failure)});
        if (self.frame) |callback| c.wl_callback_destroy(callback);
        self.frame = null;
        if (self.gpu) |*gpu| gpu.deinit();
        self.gpu = null;
        self.damage.?.invalidate();
    }

    fn requestFrame(self: *App) !void {
        self.frame = c.wl_surface_frame(self.surface) orelse return error.WaylandObjectFailed;
        if (c.wl_callback_add_listener(self.frame, &frame_listener, self) != 0) return error.WaylandListenerFailed;
    }

    fn draw(self: *App) !void {
        self.collectBuffers();
        if (self.frame != null) return;
        const width = self.width * self.scale;
        const height = self.height * self.scale;
        const damage = &self.damage.?;
        if (!try damage.prepare(&self.screen, width, height, self.renderer.cell_height * self.scale)) return;
        if (!self.backend_started) {
            self.backend_started = true;
            if (self.mode != .cpu) {
                self.gpu = Gpu.init(self.allocator, self.display.?, self.surface.?, width, height) catch |err| blk: {
                    try self.disableGpu(err);
                    break :blk null;
                };
                if (self.gpu) |*gpu| gpu.syncAtlas(&self.renderer.atlas) catch |err| try self.disableGpu(err);
            }
        }
        if (self.gpu) |*gpu| {
            gpu.render(&self.renderer, &self.screen, damage) catch |err| {
                try self.disableGpu(err);
                return self.draw();
            };
            try self.requestFrame();
            gpu.present(damage.rects.items) catch |err| {
                try self.disableGpu(err);
                return self.draw();
            };
            damage.commit(&self.screen);
            return;
        }
        var available: ?*Buffer = null;
        var active: usize = 0;
        for (self.buffers.items) |buffer| {
            if (!buffer.retired) {
                active += 1;
                if (!buffer.busy) available = buffer;
            }
        }
        if (available == null and active < 2) available = try self.createBuffer();
        const buffer = available orelse return;
        if (self.pixels.len != width * height) {
            const replacement = try self.allocator.alloc(u32, width * height);
            self.allocator.free(self.pixels);
            self.pixels = replacement;
            damage.invalidate();
            _ = try damage.prepare(&self.screen, width, height, self.renderer.cell_height * self.scale);
        }
        if (damage.full) @memset(self.pixels, Renderer.default_background);
        try self.renderer.drawRows(&self.screen, self.pixels, width, height, damage.rows);
        for (self.buffers.items) |item| {
            if (item.retired) continue;
            item.track(damage);
        }
        buffer.sync(self.pixels, self.renderer.cell_height * self.scale);
        try self.requestFrame();
        c.wl_surface_attach(self.surface, buffer.object, 0, 0);
        for (damage.rects.items) |rect| c.wl_surface_damage_buffer(self.surface, rect.x, rect.y, rect.width, rect.height);
        c.wl_surface_commit(self.surface);
        buffer.busy = true;
        damage.commit(&self.screen);
    }

    fn createBuffer(self: *App) !*Buffer {
        const width = self.width * self.scale;
        const height = self.height * self.scale;
        const length = width * height * @sizeOf(u32);
        const fd = c.memfd_create("vertex", c.MFD_CLOEXEC);
        if (fd < 0) return error.SharedMemoryFailed;
        defer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(length)) < 0) return error.SharedMemoryFailed;
        const memory = c.mmap(null, length, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (memory == c.MAP_FAILED) return error.SharedMemoryFailed;
        errdefer _ = c.munmap(memory, length);
        const pool = c.wl_shm_create_pool(self.shm, fd, @intCast(length)) orelse return error.WaylandObjectFailed;
        defer c.wl_shm_pool_destroy(pool);
        const object = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(width * 4), c.WL_SHM_FORMAT_XRGB8888) orelse return error.WaylandObjectFailed;
        errdefer c.wl_buffer_destroy(object);
        const buffer = try self.allocator.create(Buffer);
        errdefer self.allocator.destroy(buffer);
        const pending_rows = try self.allocator.alloc(bool, self.screen.rows);
        errdefer self.allocator.free(pending_rows);
        @memset(pending_rows, true);
        buffer.* = .{ .object = object, .pixels = @as([*]u32, @ptrCast(@alignCast(memory.?)))[0 .. width * height], .width = width, .height = height, .pending_rows = pending_rows };
        _ = c.wl_buffer_add_listener(object, &buffer_listener, buffer);
        try self.buffers.append(self.allocator, buffer);
        return buffer;
    }

    fn collectBuffers(self: *App) void {
        var i: usize = 0;
        while (i < self.buffers.items.len) {
            const buffer = self.buffers.items[i];
            if (buffer.retired and !buffer.busy) {
                destroyBuffer(self.allocator, buffer);
                _ = self.buffers.swapRemove(i);
            } else i += 1;
        }
    }

    fn updateScale(self: *App) void {
        var scale: usize = 1;
        for (self.outputs.items) |output| if (output.entered) {
            scale = @max(scale, output.scale);
        };
        if (scale != self.scale) {
            self.scale = scale;
            self.size_changed = true;
        }
    }

    fn stopRepeat(self: *App) void {
        self.repeat_key = null;
        self.composed_length = 0;
        const timer = std.mem.zeroes(c.itimerspec);
        if (self.repeat_fd >= 0) _ = c.timerfd_settime(self.repeat_fd, 0, &timer, null);
    }

    fn sendKey(self: *App, key: u32, compose: bool) !bool {
        if (!self.focused or self.key_state == null) return false;
        const state = self.key_state.?;
        var symbol = c.xkb_state_key_get_one_sym(state, key);
        var text_buffer: [96]u8 = undefined;
        var text_len = c.xkb_state_key_get_utf8(state, key, &text_buffer, text_buffer.len);
        if (compose) {
            if (self.compose_state) |composer| {
                _ = c.xkb_compose_state_feed(composer, symbol);
                switch (c.xkb_compose_state_get_status(composer)) {
                    c.XKB_COMPOSE_COMPOSING => return false,
                    c.XKB_COMPOSE_CANCELLED => {
                        c.xkb_compose_state_reset(composer);
                        return false;
                    },
                    c.XKB_COMPOSE_COMPOSED => {
                        symbol = c.xkb_compose_state_get_one_sym(composer);
                        text_len = c.xkb_compose_state_get_utf8(composer, &text_buffer, text_buffer.len);
                        c.xkb_compose_state_reset(composer);
                        if (text_len > 0 and text_len < text_buffer.len) {
                            self.composed_symbol = symbol;
                            self.composed_length = @intCast(text_len);
                            @memcpy(self.composed_text[0..self.composed_length], text_buffer[0..self.composed_length]);
                        }
                    },
                    else => {},
                }
            }
        }
        if (!compose and self.composed_length > 0) {
            symbol = self.composed_symbol;
            text_len = @intCast(self.composed_length);
            @memcpy(text_buffer[0..self.composed_length], self.composed_text[0..self.composed_length]);
        }
        if (text_len < 0 or text_len >= text_buffer.len) return false;
        const mods: input.Modifiers = .{
            .shift = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .alt = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .control = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0,
        };
        var encoded: [128]u8 = undefined;
        const bytes = try input.encode(&encoded, symbol, text_buffer[0..@intCast(text_len)], mods);
        if (self.pending.items.len + bytes.len > 65536) return error.InputQueueFull;
        try self.pending.appendSlice(self.allocator, bytes);
        return bytes.len > 0;
    }

    fn deinit(self: *App) void {
        if (self.pty) |*pty| pty.deinit();
        if (self.repeat_fd >= 0) _ = c.close(self.repeat_fd);
        if (self.frame) |object| c.wl_callback_destroy(object);
        if (self.keyboard) |object| releaseKeyboard(object);
        if (self.seat) |object| {
            if (c.wl_seat_get_version(object) >= 5) c.wl_seat_release(object) else c.wl_seat_destroy(object);
        }
        if (self.gpu) |*gpu| gpu.deinit();
        if (self.toplevel) |object| c.xdg_toplevel_destroy(object);
        if (self.xdg_surface) |object| c.xdg_surface_destroy(object);
        if (self.surface) |object| c.wl_surface_destroy(object);
        for (self.buffers.items) |buffer| destroyBuffer(self.allocator, buffer);
        self.buffers.deinit(self.allocator);
        for (self.outputs.items) |output| {
            c.wl_output_destroy(output.object);
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);
        if (self.wm) |object| c.xdg_wm_base_destroy(object);
        if (self.shm) |object| c.wl_shm_destroy(object);
        if (self.compositor) |object| c.wl_compositor_destroy(object);
        if (self.registry) |object| c.wl_registry_destroy(object);
        if (self.display) |display| {
            _ = c.wl_display_flush(display);
            c.wl_display_disconnect(display);
        }
        if (self.compose_state) |state| c.xkb_compose_state_unref(state);
        if (self.compose_table) |table| c.xkb_compose_table_unref(table);
        if (self.key_state) |state| c.xkb_state_unref(state);
        if (self.keymap) |keymap| c.xkb_keymap_unref(keymap);
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        self.pending.deinit(self.allocator);
        if (self.screen_ready) self.screen.deinit();
        self.renderer.deinit();
        if (self.damage) |*damage| damage.deinit();
        self.allocator.free(self.pixels);
    }
};

fn destroyBuffer(allocator: std.mem.Allocator, buffer: *Buffer) void {
    c.wl_buffer_destroy(buffer.object);
    _ = c.munmap(buffer.pixels.ptr, buffer.pixels.len * 4);
    allocator.free(buffer.pending_rows);
    allocator.destroy(buffer);
}

fn appFrom(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}
fn outputFrom(data: ?*anyopaque) *Output {
    return @ptrCast(@alignCast(data.?));
}

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const self = appFrom(data);
    const kind = std.mem.span(interface);
    if (std.mem.eql(u8, kind, "wl_compositor") and self.compositor == null) {
        if (version < 4) {
            self.failure = error.WaylandCompositorTooOld;
            return;
        }
        self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, kind, "wl_shm") and self.shm == null) {
        self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, kind, "xdg_wm_base") and self.wm == null) {
        self.wm = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1));
        if (self.wm != null) _ = c.xdg_wm_base_add_listener(self.wm, &wm_listener, self);
    } else if (std.mem.eql(u8, kind, "wl_seat") and self.seat == null) {
        self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 5)));
        if (self.seat != null) _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
    } else if (std.mem.eql(u8, kind, "wl_output")) {
        const object: *c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 2)) orelse {
            self.failure = error.WaylandObjectFailed;
            return;
        });
        const output = self.allocator.create(Output) catch |err| {
            c.wl_output_destroy(object);
            self.failure = err;
            return;
        };
        output.* = .{ .app = self, .name = name, .object = object };
        self.outputs.append(self.allocator, output) catch |err| {
            c.wl_output_destroy(object);
            self.allocator.destroy(output);
            self.failure = err;
            return;
        };
        _ = c.wl_output_add_listener(object, &output_listener, output);
    }
}

fn registryRemove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    const self = appFrom(data);
    for (self.outputs.items, 0..) |output, i| {
        if (output.name == name) {
            c.wl_output_destroy(output.object);
            self.allocator.destroy(output);
            _ = self.outputs.swapRemove(i);
            self.updateScale();
            break;
        }
    }
}
fn wmPing(_: ?*anyopaque, wm: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(wm, serial);
}
fn surfaceConfigure(data: ?*anyopaque, surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const self = appFrom(data);
    c.xdg_surface_ack_configure(surface, serial);
    if (self.pending_width > 0) self.width = self.pending_width;
    if (self.pending_height > 0) self.height = self.pending_height;
    self.configured = true;
    self.size_changed = true;
}
fn toplevelConfigure(data: ?*anyopaque, _: ?*c.xdg_toplevel, width: i32, height: i32, _: ?*c.wl_array) callconv(.c) void {
    const self = appFrom(data);
    self.pending_width = @intCast(@max(0, width));
    self.pending_height = @intCast(@max(0, height));
}
fn toplevelClose(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.c) void {
    appFrom(data).closing = true;
}
fn frameDone(data: ?*anyopaque, callback: ?*c.wl_callback, _: u32) callconv(.c) void {
    c.wl_callback_destroy(callback);
    appFrom(data).frame = null;
}
fn bufferRelease(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
    const buffer: *Buffer = @ptrCast(@alignCast(data.?));
    buffer.busy = false;
}
fn surfaceEnter(data: ?*anyopaque, _: ?*c.wl_surface, object: ?*c.wl_output) callconv(.c) void {
    const self = appFrom(data);
    for (self.outputs.items) |output| if (output.object == object) {
        output.entered = true;
    };
    self.updateScale();
}
fn surfaceLeave(data: ?*anyopaque, _: ?*c.wl_surface, object: ?*c.wl_output) callconv(.c) void {
    const self = appFrom(data);
    for (self.outputs.items) |output| if (output.object == object) {
        output.entered = false;
    };
    self.updateScale();
}
fn outputGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn outputMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn outputDone(data: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {
    const output = outputFrom(data);
    output.app.updateScale();
}
fn outputScale(data: ?*anyopaque, _: ?*c.wl_output, scale: i32) callconv(.c) void {
    const output = outputFrom(data);
    output.scale = @intCast(std.math.clamp(scale, 1, 8));
    output.app.updateScale();
}

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const self = appFrom(data);
    if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat);
        if (self.keyboard != null) _ = c.wl_keyboard_add_listener(self.keyboard, &keyboard_listener, self);
    } else if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) == 0 and self.keyboard != null) {
        self.stopRepeat();
        self.focused = false;
        releaseKeyboard(self.keyboard.?);
        self.keyboard = null;
    }
}
fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}
fn keyboardKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    defer _ = c.close(fd);
    const self = appFrom(data);
    self.stopRepeat();
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0) {
        self.failure = error.UnsupportedKeymap;
        return;
    }
    const memory = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (memory == c.MAP_FAILED) {
        self.failure = error.KeymapMapFailed;
        return;
    }
    defer _ = c.munmap(memory, size);
    const bytes: [*]const u8 = @ptrCast(memory.?);
    if (bytes[size - 1] != 0) {
        self.failure = error.InvalidKeymap;
        return;
    }
    const keymap = c.xkb_keymap_new_from_string(self.xkb_context, @ptrCast(bytes), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
        self.failure = error.InvalidKeymap;
        return;
    };
    const state = c.xkb_state_new(keymap) orelse {
        c.xkb_keymap_unref(keymap);
        self.failure = error.XkbFailed;
        return;
    };
    if (self.key_state) |old| c.xkb_state_unref(old);
    if (self.keymap) |old| c.xkb_keymap_unref(old);
    self.keymap = keymap;
    self.key_state = state;
}
fn keyboardEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.c) void {
    appFrom(data).focused = true;
}
fn keyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = appFrom(data);
    self.focused = false;
    self.stopRepeat();
    if (self.compose_state) |state| c.xkb_compose_state_reset(state);
}
fn keyboardKey(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: u32, raw_key: u32, state: u32) callconv(.c) void {
    const self = appFrom(data);
    const key = raw_key + 8;
    if (state == c.WL_KEYBOARD_KEY_STATE_RELEASED) {
        if (self.repeat_key == key) self.stopRepeat();
        return;
    }
    const repeatable = self.keymap != null and c.xkb_keymap_key_repeats(self.keymap, key) != 0;
    if (repeatable) self.stopRepeat();
    const emitted = self.sendKey(key, true) catch |err| {
        self.failure = err;
        return;
    };
    if (emitted and repeatable and self.repeat_rate > 0) {
        self.repeat_key = key;
        const interval: i64 = @divTrunc(1_000_000_000, @min(self.repeat_rate, 1000));
        const delay: i64 = @as(i64, @max(1, self.repeat_delay)) * 1_000_000;
        const timer: c.itimerspec = .{
            .it_interval = .{ .tv_sec = @divTrunc(interval, 1_000_000_000), .tv_nsec = @mod(interval, 1_000_000_000) },
            .it_value = .{ .tv_sec = @divTrunc(delay, 1_000_000_000), .tv_nsec = @mod(delay, 1_000_000_000) },
        };
        if (c.timerfd_settime(self.repeat_fd, 0, &timer, null) < 0) self.failure = error.TimerFailed;
    }
}
fn keyboardModifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
    const self = appFrom(data);
    if (self.key_state) |state| _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
}
fn keyboardRepeat(data: ?*anyopaque, _: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    const self = appFrom(data);
    self.stopRepeat();
    self.repeat_rate = @max(0, rate);
    self.repeat_delay = @max(0, delay);
}

const registry_listener: c.wl_registry_listener = .{ .global = registryGlobal, .global_remove = registryRemove };
const wm_listener: c.xdg_wm_base_listener = .{ .ping = wmPing };
const xdg_surface_listener: c.xdg_surface_listener = .{ .configure = surfaceConfigure };
const toplevel_listener: c.xdg_toplevel_listener = blk: {
    var value = std.mem.zeroes(c.xdg_toplevel_listener);
    value.configure = toplevelConfigure;
    value.close = toplevelClose;
    break :blk value;
};
const surface_listener: c.wl_surface_listener = blk: {
    var value = std.mem.zeroes(c.wl_surface_listener);
    value.enter = surfaceEnter;
    value.leave = surfaceLeave;
    break :blk value;
};
const output_listener: c.wl_output_listener = blk: {
    var value = std.mem.zeroes(c.wl_output_listener);
    value.geometry = outputGeometry;
    value.mode = outputMode;
    value.done = outputDone;
    value.scale = outputScale;
    break :blk value;
};
const seat_listener: c.wl_seat_listener = .{ .capabilities = seatCapabilities, .name = seatName };
const keyboard_listener: c.wl_keyboard_listener = blk: {
    var value = std.mem.zeroes(c.wl_keyboard_listener);
    value.keymap = keyboardKeymap;
    value.enter = keyboardEnter;
    value.leave = keyboardLeave;
    value.key = keyboardKey;
    value.modifiers = keyboardModifiers;
    value.repeat_info = keyboardRepeat;
    break :blk value;
};
const frame_listener: c.wl_callback_listener = .{ .done = frameDone };
const buffer_listener: c.wl_buffer_listener = .{ .release = bufferRelease };

fn releaseKeyboard(object: *c.wl_keyboard) void {
    if (c.wl_keyboard_get_version(object) >= 3) c.wl_keyboard_release(object) else c.wl_keyboard_destroy(object);
}

test "keyboard focus loss disarms repeat in the kernel and clears composed input" {
    const timer_fd = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_CLOEXEC | c.TFD_NONBLOCK);
    if (timer_fd < 0) return error.TimerFailed;
    defer _ = c.close(timer_fd);
    const timer: c.itimerspec = .{ .it_interval = .{ .tv_sec = 1, .tv_nsec = 0 }, .it_value = .{ .tv_sec = 1, .tv_nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), c.timerfd_settime(timer_fd, 0, &timer, null));
    var app: App = .{ .allocator = std.testing.allocator, .renderer = undefined, .screen = undefined, .repeat_fd = timer_fd, .repeat_key = 38, .focused = true, .composed_length = 2 };
    keyboardLeave(&app, null, 0, null);
    var remaining: c.itimerspec = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.timerfd_gettime(timer_fd, &remaining));
    try std.testing.expect(!app.focused and app.repeat_key == null and app.composed_length == 0);
    try std.testing.expectEqual(@as(c_long, 0), remaining.it_value.tv_sec);
    try std.testing.expectEqual(@as(c_long, 0), remaining.it_value.tv_nsec);
}

test "alternating CPU buffers catch up every pending row without writing busy memory" {
    const t = std.testing;
    var canonical = [_]u32{ 1, 1, 2, 2, 3, 3, 4, 4, 99, 99 };
    var first_pixels: [10]u32 = undefined;
    var second_pixels: [10]u32 = undefined;
    var first_rows = [_]bool{ true, true, true, true };
    var second_rows = first_rows;
    var first: Buffer = .{ .object = undefined, .pixels = &first_pixels, .width = 2, .height = 5, .pending_rows = &first_rows };
    var second: Buffer = .{ .object = undefined, .pixels = &second_pixels, .width = 2, .height = 5, .pending_rows = &second_rows };
    first.sync(&canonical, 1);
    second.sync(&canonical, 1);
    first.busy = true;
    second.busy = true;
    var damage = Renderer.Damage.init(t.allocator);
    defer damage.deinit();
    damage.rows = try t.allocator.dupe(bool, &.{ true, false, false, false });
    damage.full = false;
    canonical[0] = 10;
    first.track(&damage);
    second.track(&damage);
    try t.expectEqual(@as(u32, 1), first.pixels[0]);
    first.busy = false;
    first.sync(&canonical, 1);
    canonical[4] = 30;
    @memcpy(damage.rows, &[_]bool{ false, false, true, false });
    first.track(&damage);
    second.track(&damage);
    try t.expectEqual(@as(u32, 1), second.pixels[0]);
    second.busy = false;
    second.sync(&canonical, 1);
    try t.expectEqualSlices(u32, &canonical, second.pixels);
    first.sync(&canonical, 1);
    try t.expectEqualSlices(u32, &canonical, first.pixels);
    // A full repaint must also repair pixels below the terminal grid.
    canonical[9] = 100;
    damage.full = true;
    first.track(&damage);
    first.sync(&canonical, 1);
    try t.expectEqual(@as(u32, 100), first.pixels[9]);
}

test "auto GPU failure preserves damage and forced GPU failures propagate" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .renderer = undefined,
        .screen = undefined,
        .damage = Renderer.Damage.init(std.testing.allocator),
    };
    defer app.damage.?.deinit();
    app.damage.?.invalid = false;
    try app.disableGpu(error.EglContextLost);
    try std.testing.expect(app.gpu == null);
    try std.testing.expect(app.damage.?.invalid);
    app.mode = .gpu;
    try std.testing.expectError(error.EglContextLost, app.disableGpu(error.EglContextLost));
    app.mode = .auto;
    try std.testing.expectError(error.OutOfMemory, app.disableGpu(error.OutOfMemory));
}
