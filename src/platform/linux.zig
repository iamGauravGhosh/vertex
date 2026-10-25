//! Native Wayland window, keyboard state, and the single-threaded PTY loop.
const std = @import("std");
const c = @import("c");
const vt = @import("../terminal/root.zig");
const Renderer = @import("../renderer/root.zig");
const Gpu = @import("../renderer/Gpu.zig");
const Pty = @import("Pty.zig");
const input = @import("input.zig");
const common = @import("common.zig");
const Clipboard = @import("Clipboard.zig");
const Ime = @import("Ime.zig");
const Desktop = @import("Desktop.zig");
const ImageDecoder = @import("ImageDecoder.zig");

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
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    const mode_name = c.getenv("VERTEX_RENDERER");
    const mode = Gpu.Mode.parse(if (mode_name != null) std.mem.span(mode_name) else null) catch {
        std.debug.print("vertex: VERTEX_RENDERER must be auto, gpu, or cpu\n", .{});
        return error.InvalidRenderer;
    };
    var app: App = .{
        .allocator = allocator,
        .clipboard = .{ .allocator = allocator },
        .ime = .{ .allocator = allocator },
        .renderer = try Renderer.init(allocator),
        .screen = undefined,
        .session = undefined,
        .mode = mode,
        .damage = Renderer.Damage.init(allocator),
    };
    defer app.deinit();
    app.session = try vt.Session.initWithOptions(allocator, 24, 80, .{ .images = true, .decoder = ImageDecoder.decode });
    app.screen = app.session.activeScreen();
    app.screen_ready = true;
    const bidi = c.getenv("VERTEX_BIDI");
    if (bidi != null) {
        const value = std.mem.span(bidi);
        if (!std.mem.eql(u8, value, "off") and !std.mem.eql(u8, value, "auto")) return error.InvalidBidi;
        app.renderer.bidi = std.mem.eql(u8, value, "auto");
    }
    app.width = 80 * app.renderer.cell_width;
    app.height = 24 * app.renderer.cell_height;
    try app.connect();
    return app.loop(command);
}

const App = struct {
    allocator: std.mem.Allocator,
    renderer: Renderer,
    screen: *vt.Screen,
    session: vt.Session = undefined,
    screen_ready: bool = false,
    mode: Gpu.Mode = .auto,
    gpu: ?Gpu = null,
    backend_started: bool = false,
    damage: ?Renderer.Damage = null,
    pixels: []u32 = &.{},
    parser: vt.Parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming, .apc_mode = .streaming }),
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
    clipboard: Clipboard = .{ .allocator = std.heap.page_allocator },
    ime: Ime = .{ .allocator = std.heap.page_allocator },
    pointer: ?*c.wl_pointer = null,
    pointer_inside: bool = false,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_buttons: u8 = 0,
    pointer_last: ?[2]usize = null,
    link_click: bool = false,
    desktop: Desktop = .{},
    open_uri: *const fn (*App, []const u8) anyerror!void = openUri,
    axes: [2]f64 = @splat(0),
    axis_values: [2]f64 = @splat(0),
    axis_discrete: [2]i32 = @splat(0),
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
    pressed: [256]?vt.Input.Key = @splat(null),
    physical_down: [256]bool = @splat(false),
    composed_text: [96]u8 = undefined,
    composed_length: usize = 0,
    focused: bool = false,
    outputs: std.ArrayList(*Output) = .empty,
    buffers: std.ArrayList(*Buffer) = .empty,
    pending: std.ArrayList(u8) = .empty,
    pending_offset: usize = 0,
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
        self.clipboard.setup(self.seat);
        self.ime.surface = self.surface;
        self.ime.setup(self.seat);
        c.wl_surface_commit(self.surface);
    }

    fn loop(self: *App, command: []const []const u8) !u8 {
        while (!self.closing) {
            self.desktop.poll();
            if (self.failure) |failure| return failure;
            if (self.clipboard.failure) |failure| return failure;
            if (self.ime.failure) |failure| return failure;
            if (self.ime.changed) {
                self.screen.invalidateAll();
                self.ime.changed = false;
            }
            const cursor = self.screen.getCursor();
            if (self.ime.preedit.len == 0) self.ime.cursor(@intCast((try self.renderer.visualColumn(self.screen, cursor.row, cursor.column)) * self.renderer.cell_width), @intCast(cursor.row * self.renderer.cell_height), @intCast(self.renderer.cell_width), @intCast(self.renderer.cell_height));
            if (self.ime.committed.items.len != 0) {
                if (self.session.getModes().kitty & 8 != 0) {
                    const encoded = try self.allocator.alloc(u8, self.ime.committed.items.len * 12 + 32);
                    defer self.allocator.free(encoded);
                    try self.queue(try vt.Input.encodeKey(encoded, .{ .code = 0, .text = self.ime.committed.items }, self.session.getModes()));
                } else try self.queue(self.ime.committed.items);
                self.ime.committed.clearRetainingCapacity();
            }
            if (self.configured) {
                try self.applySize();
                if (self.pty == null) {
                    self.pty = try Pty.spawnPixels(self.allocator, command, self.screen.rows, self.screen.columns, self.session.geometry.width, self.session.geometry.height);
                }
                try self.flushInput();
                try self.drainPty();
                if (try self.pty.?.pollExit()) |status| {
                    // Reap the child independently of descendants retaining the slave.
                    try self.drainPty();
                    for (self.parser.finish()) |event| if (event) |value| self.session.handle(value);
                    return status;
                }
                try self.flushInput();
                self.clipboard.focused = self.focused;
                try self.clipboard.publish();
                self.clipboard.pump();
                try self.updateHover();
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
                .{ .fd = self.clipboard.fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = -1, .events = c.POLLOUT, .revents = 0 },
                .{ .fd = -1, .events = c.POLLOUT, .revents = 0 },
                .{ .fd = -1, .events = c.POLLOUT, .revents = 0 },
                .{ .fd = -1, .events = c.POLLOUT, .revents = 0 },
            };
            for (self.clipboard.transfers, 0..) |slot, i| if (slot) |transfer| {
                fds[4 + i].fd = transfer.fd;
            };
            var timeout: c_int = 100;
            if (self.session.sync_deadline_ms) |deadline| timeout = @intCast(std.math.clamp(deadline - common.milliseconds(), 0, timeout));
            const result = c.poll(&fds, fds.len, timeout);
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
            if ((fds[3].revents & (c.POLLIN | c.POLLHUP | c.POLLERR)) != 0) {
                const received = self.clipboard.read() catch |err| blk: {
                    if (err == error.OutOfMemory) return err;
                    std.debug.print("vertex: paste ignored ({s})\n", .{@errorName(err)});
                    break :blk null;
                };
                if (received) |text| {
                    defer self.allocator.free(text);
                    const transaction = try vt.Input.paste(self.allocator, text, self.session.modes.bracketed_paste);
                    defer self.allocator.free(transaction);
                    self.queue(transaction) catch |err| {
                        if (err != error.InputQueueFull) return err;
                        std.debug.print("vertex: paste ignored (input queue full)\n", .{});
                    };
                }
            }
            if ((fds[2].revents & c.POLLIN) != 0) {
                var repeats: u64 = 0;
                if (c.read(self.repeat_fd, &repeats, @sizeOf(u64)) > 0) {
                    if (self.repeat_key) |key| {
                        for (0..@min(repeats, 32)) |_| _ = try self.sendKey(key, .repeat);
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
        try self.session.resize(rows, columns);
        try self.renderer.setScale(self.scale);
        self.session.geometry = .{ .width = self.width * self.scale, .height = self.height * self.scale, .cell_width = self.renderer.cell_width * self.scale, .cell_height = self.renderer.cell_height * self.scale };
        if (self.pty) |*pty| try pty.resizePixels(rows, columns, self.session.geometry.width, self.session.geometry.height);
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
        var bytes: [4096]u8 = undefined;
        var budget: usize = 256 * 1024;
        const deadline = common.nanoseconds() + 2_000_000;
        while (budget > 0) {
            const count = self.pty.?.read(bytes[0..@min(bytes.len, budget)]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (count == 0) {
                self.pty_eof = true;
                return;
            }
            _ = self.session.presentationHeld(common.milliseconds());
            self.parser.feed(bytes[0..count], &self.session);
            if (self.session.takeError()) |err| return err;
            try self.queue(self.session.replies.items);
            self.session.replies.clearRetainingCapacity();
            if (self.session.takeClipboard()) |text| self.clipboard.set(text);
            try self.flushInput();
            budget -= count;
            if (common.nanoseconds() >= deadline) return;
        }
    }

    fn flushInput(self: *App) !void {
        if (self.pty_eof) {
            self.pending.clearRetainingCapacity();
            self.pending_offset = 0;
            return;
        }
        while (self.pending_offset < self.pending.items.len) {
            const count = self.pty.?.write(self.pending.items[self.pending_offset..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (count == 0) return;
            self.pending_offset += count;
        }
        self.pending.clearRetainingCapacity();
        self.pending_offset = 0;
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
        if (self.frame != null or self.session.presentationHeld(common.milliseconds())) return;
        if (self.renderer.bidi) {
            for (self.screen.getDamageRows()) |dirty| if (dirty) {
                self.screen.invalidateAll();
                break;
            };
        }
        var overlay: ?vt.Screen = null;
        defer if (overlay) |*screen| screen.deinit();
        var displayed = self.screen;
        if (self.ime.preedit.len != 0) {
            overlay = try self.screen.resized(self.screen.rows, self.screen.columns);
            displayed = &overlay.?;
            displayed.wrap_pending = self.screen.wrap_pending;
            displayed.style.underline = true;
            var iterator = (try std.unicode.Utf8View.init(self.ime.preedit)).iterator();
            var caret = displayed.cursor;
            const begin: usize = @intCast(@max(0, self.ime.cursor_begin));
            const end: usize = @intCast(@max(0, self.ime.cursor_end));
            while (iterator.nextCodepoint()) |cp| {
                const offset = iterator.i - (std.unicode.utf8CodepointSequenceLength(cp) catch unreachable);
                if (offset == begin) caret = displayed.cursor;
                displayed.style.inverse = offset >= @min(begin, end) and offset < @max(begin, end);
                if (cp >= 32 and !(cp >= 127 and cp <= 159)) try displayed.apply(.{ .print = cp });
            }
            if (begin >= self.ime.preedit.len) caret = displayed.cursor;
            displayed.cursor = caret;
            if (self.ime.cursor_begin < 0) displayed.cursor.visible = false;
            @memcpy(displayed.damage_rows, self.screen.getDamageRows());
            const point = displayed.cursor;
            self.ime.cursor(@intCast((try self.renderer.visualColumn(displayed, point.row, point.column)) * self.renderer.cell_width), @intCast(point.row * self.renderer.cell_height), @intCast(self.renderer.cell_width), @intCast(self.renderer.cell_height));
        }
        const width = self.width * self.scale;
        const height = self.height * self.scale;
        const damage = &self.damage.?;
        if (!try damage.prepare(displayed, width, height, self.renderer.cell_height * self.scale)) return;
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
            gpu.render(&self.renderer, displayed, damage) catch |err| {
                try self.disableGpu(err);
                return self.draw();
            };
            try self.requestFrame();
            gpu.present(damage.rects.items) catch |err| {
                try self.disableGpu(err);
                return self.draw();
            };
            damage.commit(displayed);
            if (overlay != null) self.screen.clearDamage();
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
            _ = try damage.prepare(displayed, width, height, self.renderer.cell_height * self.scale);
        }
        if (damage.full) @memset(self.pixels, Renderer.default_background);
        try self.renderer.drawRows(displayed, self.pixels, width, height, damage.rows);
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
        damage.commit(displayed);
        if (overlay != null) self.screen.clearDamage();
    }

    fn openUri(self: *App, uri: []const u8) !void {
        try self.desktop.open(self.allocator, uri);
    }
    fn linkAtPointer(self: *App) !?vt.Links.Match {
        if (!self.pointer_inside or !self.screen_ready or self.pointer_x < 0 or self.pointer_y < 0) return null;
        const col: usize = @intFromFloat(@floor(self.pointer_x / @as(f64, @floatFromInt(self.renderer.cell_width))));
        const row: usize = @intFromFloat(@floor(self.pointer_y / @as(f64, @floatFromInt(self.renderer.cell_height))));
        if (row >= self.screen.rows or col >= self.screen.columns) return null;
        const logical = try self.renderer.logicalColumn(self.screen, row, col);
        return vt.Links.find(self.allocator, self.screen, row, logical);
    }
    fn updateHover(self: *App) !void {
        const match = try self.linkAtPointer();
        defer if (match) |value| self.allocator.free(value.uri);
        const next = if (match) |value| value.range else null;
        if (std.meta.eql(next, self.renderer.hover)) return;
        if (self.renderer.hover) |old| self.damageLink(old);
        self.renderer.hover = next;
        if (next) |range| self.damageLink(range);
    }
    fn damageLink(self: *App, range: vt.Links.Range) void {
        const first = @min(self.screen.rows, range.first / self.screen.columns);
        const end = @min(self.screen.rows, (range.end + self.screen.columns - 1) / self.screen.columns);
        for (first..end) |row| self.screen.damage_rows[row] = true;
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

    fn sendKey(self: *App, key: u32, action: vt.Input.Action) !bool {
        if (!self.focused or self.key_state == null) return false;
        if (action == .release and (key >= self.pressed.len or self.pressed[key] == null)) return false;
        const state = self.key_state.?;
        var symbol = c.xkb_state_key_get_one_sym(state, key);
        var text_buffer: [96]u8 = undefined;
        var text_len = c.xkb_state_key_get_utf8(state, key, &text_buffer, text_buffer.len);
        if (action == .press) {
            if (if (!self.ime.enabled) self.compose_state else null) |composer| {
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
        if (action == .repeat and self.composed_length > 0) {
            symbol = self.composed_symbol;
            text_len = @intCast(self.composed_length);
            @memcpy(text_buffer[0..self.composed_length], self.composed_text[0..self.composed_length]);
        }
        if (text_len < 0 or text_len >= text_buffer.len) return false;
        const mods = self.modifiers();
        if (action == .press and mods.shift and ((mods.control and (symbol == 'v' or symbol == 'V')) or symbol == c.XKB_KEY_Insert)) {
            try self.clipboard.request(symbol == c.XKB_KEY_Insert);
            return false;
        }
        var unshifted: [*c]const c.xkb_keysym_t = null;
        const layout = c.xkb_state_key_get_layout(state, key);
        const count = c.xkb_keymap_key_get_syms_by_level(self.keymap, key, layout, 0, &unshifted);
        var code = input.code(if (count > 0) unshifted[0] else symbol);
        if (self.composed_length > 0 or (symbol >= c.XKB_KEY_KP_Space and symbol <= c.XKB_KEY_KP_Equal)) code = input.code(symbol);
        if (code == 0 and text_len == 0) return false;
        // Correct modifier-key events even though the Wayland modifier update
        // may arrive immediately after the key event.
        var adjusted = mods;
        if (action == .press and code == 57358) adjusted.caps_lock = !mods.caps_lock;
        if (action == .press and code == 57360) adjusted.num_lock = !mods.num_lock;
        if (code >= 57441 and code <= 57452) {
            const active = if (action != .release) true else self.otherModifierHeld(key, code);
            switch (code) {
                57441, 57447 => adjusted.shift = active,
                57442, 57448 => adjusted.control = active,
                57443, 57449 => adjusted.alt = active,
                57444, 57450 => adjusted.super = active,
                57445, 57451 => adjusted.hyper = active,
                57446, 57452 => adjusted.meta = active,
                else => {},
            }
        }
        var encoded: [2048]u8 = undefined;
        var event: vt.Input.Key = .{ .code = code, .shifted = input.code(symbol), .base = input.baseKey(self.keymap.?, key), .text = text_buffer[0..@intCast(text_len)], .modifiers = adjusted, .action = action };
        if (action == .release) {
            const original = self.pressed[key].?;
            event.code = original.code;
            event.shifted = original.shifted;
            event.base = original.base;
            event.text = "";
            self.pressed[key] = null;
        }
        const bytes = try input.encodeKey(&encoded, event, self.session.getModes());
        if (action == .press and bytes.len != 0 and key < self.pressed.len) {
            event.text = "";
            self.pressed[key] = event;
        }
        try self.queue(bytes);
        return bytes.len > 0;
    }

    fn otherModifierHeld(self: *const App, key: u32, code: u21) bool {
        const pair: u21 = if (code <= 57446) code + 6 else code - 6;
        for (self.physical_down, 0..) |down, index| {
            if (!down or index == key) continue;
            const symbol = c.xkb_state_key_get_one_sym(self.key_state, @intCast(index));
            const other = input.code(symbol);
            if (other == code or other == pair) return true;
        }
        return false;
    }
    fn queue(self: *App, bytes: []const u8) !void {
        if (self.pending_offset != 0) {
            std.mem.copyForwards(u8, self.pending.items[0 .. self.pending.items.len - self.pending_offset], self.pending.items[self.pending_offset..]);
            self.pending.items.len -= self.pending_offset;
            self.pending_offset = 0;
        }
        if (self.pending.items.len + bytes.len > vt.Input.max_paste_bytes + 65536) return error.InputQueueFull;
        try self.pending.appendSlice(self.allocator, bytes);
    }
    fn modifiers(self: *const App) input.Modifiers {
        const state = self.key_state orelse return .{};
        return .{
            .shift = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .alt = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_ALT, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .control = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .super = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_LOGO, c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .hyper = c.xkb_state_mod_name_is_active(state, "Hyper", c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .meta = c.xkb_state_mod_name_is_active(state, "Meta", c.XKB_STATE_MODS_EFFECTIVE) > 0,
            .caps_lock = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_CAPS, c.XKB_STATE_MODS_LOCKED) > 0,
            .num_lock = c.xkb_state_mod_name_is_active(state, c.XKB_MOD_NAME_NUM, c.XKB_STATE_MODS_LOCKED) > 0,
        };
    }
    fn deinit(self: *App) void {
        if (self.pty) |*pty| pty.deinit();
        if (self.repeat_fd >= 0) _ = c.close(self.repeat_fd);
        if (self.frame) |object| c.wl_callback_destroy(object);
        self.clipboard.deinit();
        self.ime.deinit();
        if (self.pointer) |object| releasePointer(object);
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
        if (self.screen_ready) self.session.deinit();
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
    } else if (std.mem.eql(u8, kind, "wl_data_device_manager") and self.clipboard.manager == null) {
        self.clipboard.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_data_device_manager_interface, @min(version, 3)));
    } else if (std.mem.eql(u8, kind, "zwp_primary_selection_device_manager_v1") and self.clipboard.primary_manager == null) {
        self.clipboard.primary_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_primary_selection_device_manager_v1_interface, 1));
    } else if (std.mem.eql(u8, kind, "zwp_text_input_manager_v3") and self.ime.manager == null) {
        self.ime.manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_text_input_manager_v3_interface, 1));
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
    if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0 and self.pointer == null) {
        self.pointer = c.wl_seat_get_pointer(seat);
        if (self.pointer) |pointer| _ = c.wl_pointer_add_listener(pointer, &pointer_listener, self);
    } else if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) == 0 and self.pointer != null) {
        releasePointer(self.pointer.?);
        self.pointer = null;
        self.pointer_inside = false;
        self.pointer_buttons = 0;
    }
    if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat);
        if (self.keyboard != null) _ = c.wl_keyboard_add_listener(self.keyboard, &keyboard_listener, self);
    } else if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) == 0 and self.keyboard != null) {
        keyboardLeave(self, self.keyboard, 0, null);
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
    const self = appFrom(data);
    self.focused = true;
    if (self.screen_ready and self.session.modes.focus) self.queue("\x1b[I") catch |err| {
        self.failure = err;
    };
}
fn keyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = appFrom(data);
    if (self.screen_ready and self.session.modes.focus) self.queue("\x1b[O") catch |err| {
        self.failure = err;
    };
    self.focused = false;
    self.clipboard.focused = false;
    self.clipboard.serial = null;
    self.clipboard.cancel();
    self.pressed = @splat(null);
    self.physical_down = @splat(false);
    self.ime.clear();
    self.stopRepeat();
    if (self.compose_state) |state| c.xkb_compose_state_reset(state);
}
fn keyboardKey(data: ?*anyopaque, _: ?*c.wl_keyboard, serial: u32, _: u32, raw_key: u32, state: u32) callconv(.c) void {
    const self = appFrom(data);
    if (state == c.WL_KEYBOARD_KEY_STATE_PRESSED) self.clipboard.serial = serial;
    const key = raw_key + 8;
    if (key < self.physical_down.len) self.physical_down[key] = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
    if (state == c.WL_KEYBOARD_KEY_STATE_RELEASED) {
        _ = self.sendKey(key, .release) catch |err| {
            self.failure = err;
        };
        if (self.repeat_key == key) self.stopRepeat();
        return;
    }
    const repeatable = self.keymap != null and c.xkb_keymap_key_repeats(self.keymap, key) != 0;
    if (repeatable) self.stopRepeat();
    const emitted = self.sendKey(key, .press) catch |err| {
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

fn releasePointer(object: *c.wl_pointer) void {
    if (c.wl_pointer_get_version(object) >= 3) c.wl_pointer_release(object) else c.wl_pointer_destroy(object);
}
fn sendPointer(self: *App, kind: @FieldType(vt.Input.Pointer, "kind"), button: u8) void {
    if (!self.pointer_inside or !self.screen_ready) return;
    if (self.link_click and kind == .motion) return;
    const x: usize = @intFromFloat(@max(0, self.pointer_x));
    const y: usize = @intFromFloat(@max(0, self.pointer_y));
    const col = @min(self.screen.columns - 1, x / self.renderer.cell_width);
    const row = @min(self.screen.rows - 1, y / self.renderer.cell_height);
    const mode = self.session.getModes();
    const location = [2]usize{ if (mode.mouse_pixels) x else col, if (mode.mouse_pixels) y else row };
    if (kind == .motion and self.pointer_last != null and std.mem.eql(usize, &location, &self.pointer_last.?)) return;
    self.pointer_last = location;
    var buffer: [128]u8 = undefined;
    const bytes = vt.Input.encodePointer(&buffer, .{ .kind = kind, .button = button, .column = col, .row = row, .x = x, .y = y, .modifiers = self.modifiers() }, mode) catch |err| {
        self.failure = err;
        return;
    };
    self.queue(bytes) catch |err| {
        self.failure = err;
    };
}
fn pointerEnter(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    const self = appFrom(data);
    self.pointer_inside = true;
    self.pointer_last = null;
    self.pointer_x = @as(f64, @floatFromInt(x)) / 256;
    self.pointer_y = @as(f64, @floatFromInt(y)) / 256;
}
fn pointerLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = appFrom(data);
    self.pointer_inside = false;
    self.pointer_buttons = 0;
    self.link_click = false;
    self.pointer_last = null;
    self.axes = @splat(0);
}
fn pointerMotion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, x: c.wl_fixed_t, y: c.wl_fixed_t) callconv(.c) void {
    const self = appFrom(data);
    self.pointer_x = @as(f64, @floatFromInt(x)) / 256;
    self.pointer_y = @as(f64, @floatFromInt(y)) / 256;
    const button: u8 = if (self.pointer_buttons & 1 != 0) 0 else if (self.pointer_buttons & 2 != 0) 1 else if (self.pointer_buttons & 4 != 0) 2 else 3;
    sendPointer(self, .motion, button);
}
fn pointerButton(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    const self = appFrom(data);
    const number: u8 = switch (button) {
        0x110 => 0,
        0x112 => 1,
        0x111 => 2,
        else => return,
    };
    const pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
    if (pressed) self.clipboard.serial = serial;
    const bit = @as(u8, 1) << @intCast(number);
    if (pressed) self.pointer_buttons |= bit else self.pointer_buttons &= ~bit;
    if (number == 0) {
        if (!pressed and self.link_click) {
            self.link_click = false;
            return;
        }
        if (pressed and self.modifiers().control) {
            const match = self.linkAtPointer() catch null;
            if (match) |value| {
                defer self.allocator.free(value.uri);
                self.link_click = true;
                self.open_uri(self, value.uri) catch |err| std.debug.print("vertex: cannot open link ({s})\n", .{@errorName(err)});
                return;
            }
        }
    }
    if (number == 1 and pressed and (self.session.modes.mouse_tracking == 0 or self.modifiers().shift)) {
        self.clipboard.request(true) catch |err| {
            self.failure = err;
        };
    } else sendPointer(self, if (pressed) .press else .release, number);
}
fn pointerAxis(data: ?*anyopaque, pointer: ?*c.wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    const self = appFrom(data);
    if (axis > 1) return;
    self.axis_values[axis] += @as(f64, @floatFromInt(value)) / 2560;
    if (c.wl_pointer_get_version(pointer) < 5) pointerFrame(data, pointer);
}
fn pointerFrame(data: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {
    const self = appFrom(data);
    for (0..2) |axis| {
        self.axes[axis] += if (self.axis_discrete[axis] != 0) @as(f64, @floatFromInt(self.axis_discrete[axis])) else self.axis_values[axis];
        const steps: i32 = @intFromFloat(std.math.clamp(@trunc(self.axes[axis]), -128, 128));
        self.axes[axis] -= @as(f64, @floatFromInt(steps));
        for (0..@intCast(@abs(steps))) |_| sendPointer(self, .wheel, if (axis == 0) (if (steps < 0) 64 else 65) else (if (steps < 0) 66 else 67));
    }
    self.axis_values = @splat(0);
    self.axis_discrete = @splat(0);
}
fn pointerAxisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
fn pointerAxisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn pointerAxisDiscrete(data: ?*anyopaque, _: ?*c.wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    if (axis < 2) appFrom(data).axis_discrete[axis] += discrete;
}
const pointer_listener: c.wl_pointer_listener = blk: {
    var value = std.mem.zeroes(c.wl_pointer_listener);
    value.enter = pointerEnter;
    value.leave = pointerLeave;
    value.motion = pointerMotion;
    value.button = pointerButton;
    value.axis = pointerAxis;
    value.frame = pointerFrame;
    value.axis_source = pointerAxisSource;
    value.axis_stop = pointerAxisStop;
    value.axis_discrete = pointerAxisDiscrete;
    break :blk value;
};

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

test "Wayland pointer callbacks encode drag release pixel and wheel events" {
    var app: App = .{ .allocator = std.testing.allocator, .renderer = undefined, .screen = undefined };
    app.session = try vt.Session.init(std.testing.allocator, 4, 10);
    defer app.session.deinit();
    defer app.pending.deinit(std.testing.allocator);
    app.screen = app.session.activeScreen();
    app.screen_ready = true;
    app.renderer.cell_width = 8;
    app.renderer.cell_height = 16;
    app.session.modes.mouse_tracking = 1002;
    app.session.modes.mouse_sgr = true;
    pointerEnter(&app, null, 0, null, 8 * 256, 16 * 256);
    pointerButton(&app, null, 0, 0, 0x110, c.WL_POINTER_BUTTON_STATE_PRESSED);
    pointerMotion(&app, null, 0, 16 * 256, 16 * 256);
    pointerButton(&app, null, 0, 0, 0x110, c.WL_POINTER_BUTTON_STATE_RELEASED);
    pointerMotion(&app, null, 0, 24 * 256, 16 * 256);
    pointerAxisDiscrete(&app, null, 0, -1);
    pointerAxisDiscrete(&app, null, 1, 1);
    pointerFrame(&app, null);
    try std.testing.expectEqualStrings("\x1b[<0;2;2M\x1b[<32;3;2M\x1b[<0;3;2m\x1b[<64;4;2M\x1b[<67;4;2M", app.pending.items);
    app.pending.clearRetainingCapacity();
    app.session.modes.mouse_pixels = true;
    pointerButton(&app, null, 0, 0, 0x111, c.WL_POINTER_BUTTON_STATE_PRESSED);
    try std.testing.expectEqualStrings("\x1b[<2;25;17M", app.pending.items);
    try std.testing.expect(app.failure == null);
}

test "Ctrl click opens the hovered link and consumes the gesture during mouse reporting" {
    const Capture = struct {
        fn open(app: *App, uri: []const u8) !void {
            try app.pending.appendSlice(app.allocator, uri);
        }
    };
    var app: App = .{ .allocator = std.testing.allocator, .renderer = try Renderer.initFont(std.testing.allocator, "DejaVu Sans"), .screen = undefined, .open_uri = Capture.open };
    defer app.renderer.deinit();
    defer app.pending.deinit(app.allocator);
    app.session = try vt.Session.init(app.allocator, 2, 30);
    defer app.session.deinit();
    app.screen = app.session.activeScreen();
    app.screen_ready = true;
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbFailed;
    defer c.xkb_context_unref(context);
    const keymap = c.xkb_keymap_new_from_names(context, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbFailed;
    defer c.xkb_keymap_unref(keymap);
    const state = c.xkb_state_new(keymap) orelse return error.XkbFailed;
    defer c.xkb_state_unref(state);
    app.key_state = state;
    const ctrl = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_CTRL);
    _ = c.xkb_state_update_mask(state, @as(u32, 1) << @intCast(ctrl), 0, 0, 0, 0, 0);
    var parser = vt.Parser.init();
    parser.feed("https://example.com", &app.session);
    app.session.modes.mouse_tracking = 1003;
    app.session.modes.mouse_sgr = true;
    pointerEnter(&app, null, 1, null, @intCast(app.renderer.cell_width * 256), 0);
    try app.updateHover();
    try std.testing.expect(app.renderer.hover != null);
    pointerButton(&app, null, 1, 0, 0x110, c.WL_POINTER_BUTTON_STATE_PRESSED);
    pointerMotion(&app, null, 0, @intCast(app.renderer.cell_width * 512), 0);
    pointerButton(&app, null, 1, 0, 0x110, c.WL_POINTER_BUTTON_STATE_RELEASED);
    try std.testing.expectEqualStrings("https://example.com", app.pending.items);
    app.pending.clearRetainingCapacity();
    _ = c.xkb_state_update_mask(state, 0, 0, 0, 0, 0, 0);
    pointerButton(&app, null, 1, 0, 0x110, c.WL_POINTER_BUTTON_STATE_PRESSED);
    pointerButton(&app, null, 1, 0, 0x110, c.WL_POINTER_BUTTON_STATE_RELEASED);
    try std.testing.expectEqualStrings("\x1b[<0;3;1M\x1b[<0;3;1m", app.pending.items);
    pointerLeave(&app, null, 0, null);
    try app.updateHover();
    try std.testing.expect(app.renderer.hover == null);
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

test "benchmark keyboard handler to PTY during continuous output" {
    if (c.getenv("VERTEX_BENCH") == null) return error.SkipZigTest;
    const t = std.testing;
    var app: App = .{
        .allocator = t.allocator,
        .renderer = undefined,
        .screen = undefined,
        .session = try vt.Session.init(t.allocator, 48, 160),
        .focused = true,
    };
    defer app.session.deinit();
    defer app.pending.deinit(t.allocator);
    app.screen = app.session.activeScreen();
    app.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbFailed;
    defer c.xkb_context_unref(app.xkb_context);
    var names = std.mem.zeroes(c.xkb_rule_names);
    names.layout = "us";
    app.keymap = c.xkb_keymap_new_from_names(app.xkb_context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbFailed;
    defer c.xkb_keymap_unref(app.keymap);
    app.key_state = c.xkb_state_new(app.keymap) orelse return error.XkbFailed;
    defer c.xkb_state_unref(app.key_state);
    app.pty = try Pty.spawn(t.allocator, &.{ "/bin/sh", "-c", "stty raw -echo; yes 'continuous log output' & cat >/dev/null" }, 48, 160);
    defer app.pty.?.deinit();
    var ready = c.pollfd{ .fd = app.pty.?.master, .events = c.POLLIN, .revents = 0 };
    try t.expect(c.poll(&ready, 1, 1000) > 0);
    var samples: [200]i64 = undefined;
    for (0..220) |iteration| {
        try app.drainPty();
        const start = common.nanoseconds();
        keyboardKey(&app, null, 1, 0, 30, c.WL_KEYBOARD_KEY_STATE_PRESSED);
        if (app.failure) |err| return err;
        try t.expect(app.pending.items.len > app.pending_offset);
        try app.flushInput();
        try t.expectEqual(@as(usize, 0), app.pending.items.len);
        const elapsed = common.nanoseconds() - start;
        keyboardKey(&app, null, 1, 0, 30, c.WL_KEYBOARD_KEY_STATE_RELEASED);
        if (iteration >= 20) samples[iteration - 20] = elapsed;
    }
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    try t.expect(app.screen.revision > 1000); // the producer actually ran
    std.debug.print("\nvertex benchmark: Wayland key handler -> PTY write during continuous output; p50={d}us p95={d}us p99={d}us (excludes compositor/app/network latency)\n", .{ @divTrunc(samples[100], 1000), @divTrunc(samples[190], 1000), @divTrunc(samples[198], 1000) });
}
