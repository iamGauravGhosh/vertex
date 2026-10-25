//! Owned TOML snapshots. No configuration access occurs in the terminal or renderer.
const std = @import("std");
const c = @import("c");
const Colors = @import("terminal/Colors.zig");
const Input = @import("terminal/Input.zig");
const Config = @This();

pub const Font = struct {
    family: []const u8 = "monospace",
    bold_family: ?[]const u8 = null,
    italic_family: ?[]const u8 = null,
    bold_italic_family: ?[]const u8 = null,
    size: f64 = 12,
    ligatures: bool = false,
    features: []const []const u8 = &.{},
    cell_width_offset: i32 = 0,
    cell_height_offset: i32 = 0,
    glyph_offset_x: i32 = 0,
    glyph_offset_y: i32 = 0,
};
pub const Padding = struct { left: u16 = 0, right: u16 = 0, top: u16 = 0, bottom: u16 = 0 };
pub const Window = struct {
    padding: Padding = .{},
    dynamic_padding: bool = false,
    opacity: f64 = 1,
    unfocused_opacity: ?f64 = null,
    title: []const u8 = "Vertex",
    dynamic_title: bool = true,
    app_id: []const u8 = "vertex",
    columns: u16 = 80,
    rows: u16 = 24,
    startup_mode: enum { windowed, maximized, fullscreen } = .windowed,
    decorations: enum { none, server } = .none,
};
pub const Cursor = struct {
    shape: @FieldType(@import("terminal/Screen.zig").Cursor, "shape") = .block,
    thickness: u16 = 2,
    blinking: bool = false,
    blink_interval: u16 = 500,
    unfocused_hollow: bool = true,
};
pub const Action = enum { paste, paste_primary, font_increase, font_decrease, font_reset, opacity_increase, opacity_decrease, reload, fullscreen, new_window, send_text, launch, none, ignore };
pub const Binding = struct {
    key: []const u8 = "",
    mods: []const u8 = "",
    action: Action = .ignore,
    text: ?[]const u8 = null,
    command: []const []const u8 = &.{},
};
pub const Modifier = enum { none, shift, control, alt, super };
pub const Mouse = struct {
    paste_button: enum { none, left, middle, right } = .middle,
    paste_primary: bool = true,
    link_button: enum { none, left, middle, right } = .left,
    link_modifier: Modifier = .control,
    reporting_bypass: Modifier = .shift,
    wheel_multiplier: f64 = 1,
    hide_when_typing: bool = false,
};
pub const Env = @import("platform/Pty.zig").Env;
pub const Terminal = struct {
    shell: []const []const u8 = &.{},
    working_directory: ?[]const u8 = null,
    env: []const Env = &.{},
    bidi: enum { off, auto } = .off,
    renderer: enum { auto, gpu, cpu } = .auto,
};
pub const Values = struct {
    general: struct { import: []const []const u8 = &.{}, live_reload: bool = true } = .{},
    font: Font = .{},
    colors: Colors.Theme = .{},
    window: Window = .{},
    cursor: Cursor = .{},
    keyboard: struct { bindings: []const Binding = &.{
        .{ .key = "v", .mods = "Control|Shift", .action = .paste },
        .{ .key = "Insert", .mods = "Shift", .action = .paste_primary },
    } } = .{},
    mouse: Mouse = .{},
    terminal: Terminal = .{},
};

arena: *std.heap.ArenaAllocator,
value: Values = .{},
files: std.ArrayList([]const u8) = .empty,
root: ?[]const u8 = null,
explicit: bool = false,
bytes: usize = 0,
locations: std.StringHashMapUnmanaged(struct { source: []const u8, line: c_int, column: c_int }) = .empty,

pub const defaults = @embedFile("config_defaults.toml");

pub fn deinit(self: *Config) void {
    const parent = self.arena.child_allocator;
    self.arena.deinit();
    parent.destroy(self.arena);
    self.* = undefined;
}
pub fn env(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name);
    return if (value == null) null else std.mem.span(value);
}
pub fn defaultPath(allocator: std.mem.Allocator, xdg: ?[]const u8, home: ?[]const u8) !?[]const u8 {
    if (xdg) |base| if (std.fs.path.isAbsolute(base)) return try std.fs.path.join(allocator, &.{ base, "vertex/config.toml" });
    if (home) |base| if (std.fs.path.isAbsolute(base)) return try std.fs.path.join(allocator, &.{ base, ".config/vertex/config.toml" });
    return null;
}
pub fn load(allocator: std.mem.Allocator, filename: ?[]const u8) !Config {
    const path = filename orelse try defaultPath(allocator, env("XDG_CONFIG_HOME"), env("HOME"));
    defer if (filename == null) if (path) |p| allocator.free(p);
    return loadAt(allocator, path, filename != null, true);
}
pub fn init(allocator: std.mem.Allocator) !Config {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return .{ .arena = arena };
}
pub fn loadAt(allocator: std.mem.Allocator, filename: ?[]const u8, explicit: bool, environment: bool) !Config {
    var self = try init(allocator);
    errdefer self.deinit();
    try self.read(filename, explicit, environment);
    return self;
}
/// A rejected snapshot retains attempted paths so the watcher can follow repairs.
pub fn read(self: *Config, filename: ?[]const u8, explicit: bool, environment: bool) !void {
    self.explicit = explicit;
    if (filename) |name| {
        self.root = try self.resolve(name, null);
        try self.loadFile(self.root.?, !explicit, &.{});
    }
    if (environment) try self.applyOverrides(.{
        .family = env("VERTEX_FONT"),
        .size = env("VERTEX_FONT_SIZE"),
        .renderer = env("VERTEX_RENDERER"),
        .bidi = env("VERTEX_BIDI"),
    });
    try self.validate();
}
pub const Overrides = struct { family: ?[]const u8 = null, size: ?[]const u8 = null, renderer: ?[]const u8 = null, bidi: ?[]const u8 = null };
pub fn applyOverrides(self: *Config, overrides: Overrides) !void {
    if (overrides.family) |family| self.value.font.family = try self.arena.allocator().dupe(u8, if (family.len == 0) "monospace" else family);
    if (overrides.size) |size| if (size.len != 0) {
        const points = std.fmt.parseFloat(f64, size) catch {
            std.debug.print("vertex: VERTEX_FONT_SIZE: expected 4–128 points\n", .{});
            return error.InvalidFontSize;
        };
        if (!std.math.isFinite(points) or points < 4 or points > 128) {
            std.debug.print("vertex: VERTEX_FONT_SIZE: expected 4–128 points\n", .{});
            return error.InvalidFontSize;
        }
        self.value.font.size = points;
    };
    if (overrides.renderer) |mode| self.value.terminal.renderer = std.meta.stringToEnum(@FieldType(Terminal, "renderer"), mode) orelse {
        std.debug.print("vertex: VERTEX_RENDERER: expected auto, gpu, or cpu\n", .{});
        return error.InvalidRenderer;
    };
    if (overrides.bidi) |mode| self.value.terminal.bidi = std.meta.stringToEnum(@FieldType(Terminal, "bidi"), mode) orelse {
        std.debug.print("vertex: VERTEX_BIDI: expected off or auto\n", .{});
        return error.InvalidBidi;
    };
}
fn resolve(self: *Config, name: []const u8, base: ?[]const u8) ![]const u8 {
    const allocator = self.arena.allocator();
    if (std.mem.startsWith(u8, name, "~/")) {
        const home = env("HOME") orelse return error.HomeNotSet;
        return std.fs.path.resolve(allocator, &.{ home, name[2..] });
    }
    if (std.fs.path.isAbsolute(name)) return std.fs.path.resolve(allocator, &.{name});
    var cwd: [4096]u8 = undefined;
    const directory = base orelse if (c.getcwd(&cwd, cwd.len) != null) std.mem.sliceTo(&cwd, 0) else return error.WorkingDirectoryFailed;
    return std.fs.path.resolve(allocator, &.{ directory, name });
}
fn loadFile(self: *Config, path: []const u8, missing_ok: bool, parents: []const []const u8) anyerror!void {
    const allocator = self.arena.allocator();
    if (parents.len >= 32 or self.files.items.len >= 128) return error.TooManyConfigImports;
    const filename = try allocator.dupeSentinel(u8, path, 0);
    try self.files.append(allocator, path);
    var canonical_buf: [4096]u8 = undefined;
    const canonical = if (c.realpath(filename, &canonical_buf) != null) try allocator.dupe(u8, std.mem.sliceTo(&canonical_buf, 0)) else path;
    for (parents) |parent| if (std.mem.eql(u8, parent, canonical)) {
        std.debug.print("vertex: {s}: cyclic config import\n", .{path});
        return error.ConfigImportCycle;
    };
    if (!std.mem.eql(u8, path, canonical)) try self.files.append(allocator, canonical);
    const fd = c.open(filename, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) {
        if (missing_ok and c.__errno_location().* == c.ENOENT) return;
        std.debug.print("vertex: {s}: cannot read configuration: {s}\n", .{ path, c.strerror(c.__errno_location().*) });
        return error.ConfigReadFailed;
    }
    defer _ = c.close(fd);
    var data: std.ArrayList(u8) = .empty;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.ConfigReadFailed;
        }
        if (n == 0) break;
        self.bytes += @intCast(n);
        if (self.bytes > 1024 * 1024) return error.ConfigTooLarge;
        try data.appendSlice(allocator, buffer[0..@intCast(n)]);
    }
    const parsed = c.toml_parse_named(data.items.ptr, @intCast(data.items.len), filename);
    defer c.toml_free(parsed);
    if (!parsed.ok) {
        std.debug.print("vertex: {s}: {s}\n", .{ path, std.mem.sliceTo(&parsed.errmsg, 0) });
        return error.InvalidToml;
    }
    const imports = c.toml_seek(parsed.toptab, "general.import");
    if (imports.type != c.TOML_UNKNOWN) {
        var names: []const []const u8 = &.{};
        try self.decode(@TypeOf(names), &names, imports, "general.import");
        const stack = try allocator.alloc([]const u8, parents.len + 1);
        @memcpy(stack[0..parents.len], parents);
        stack[parents.len] = canonical;
        for (names) |name| try self.loadFile(try self.resolve(name, std.fs.path.dirname(path)), false, stack);
    }
    try self.decode(Values, &self.value, parsed.toptab, "");
}
fn invalid(node: c.toml_datum_t, key: []const u8, message: []const u8) error{InvalidConfig} {
    std.debug.print("vertex: {s}:{d}:{d}: {s}: {s}\n", .{ if (node.source != null) std.mem.span(node.source) else "config", node.lineno, node.colno, key, message });
    return error.InvalidConfig;
}
fn string(node: c.toml_datum_t, key: []const u8) ![]const u8 {
    if (node.type != c.TOML_STRING) return invalid(node, key, "expected a string");
    const bytes = node.u.str.ptr[0..@intCast(node.u.str.len)];
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return invalid(node, key, "NUL is not allowed");
    return bytes;
}
fn colorValue(node: c.toml_datum_t, key: []const u8) !u32 {
    const text = try string(node, key);
    if (text.len != 7 or text[0] != '#') return invalid(node, key, "expected #RRGGBB");
    return std.fmt.parseInt(u32, text[1..], 16) catch return invalid(node, key, "expected #RRGGBB");
}
fn decode(self: *Config, comptime T: type, destination: *T, node: c.toml_datum_t, key: []const u8) anyerror!void {
    const allocator = self.arena.allocator();
    if (key.len != 0 and node.source != null) try self.locations.put(allocator, try allocator.dupe(u8, key), .{ .source = try allocator.dupe(u8, std.mem.span(node.source)), .line = node.lineno, .column = node.colno });
    if (T == u32) {
        destination.* = try colorValue(node, key);
        return;
    }
    if (T == []const Env) {
        if (node.type != c.TOML_TABLE) return invalid(node, key, "expected an environment table");
        var entries: std.ArrayList(Env) = .empty;
        try entries.appendSlice(allocator, destination.*);
        for (0..@intCast(node.u.tab.size)) |i| {
            const name = std.mem.span(node.u.tab.key[i]);
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) return invalid(node, key, "invalid environment name");
            const entry: Env = .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, try string(node.u.tab.value[i], key)) };
            var found = false;
            for (entries.items) |*old| if (std.mem.eql(u8, old.name, name)) {
                old.* = entry;
                found = true;
                break;
            };
            if (!found) try entries.append(allocator, entry);
        }
        destination.* = entries.items;
        return;
    }
    if (T == [256]?u32) {
        if (node.type != c.TOML_TABLE) return invalid(node, key, "expected indexed color table");
        for (0..@intCast(node.u.tab.size)) |i| {
            const index = std.fmt.parseInt(u8, std.mem.span(node.u.tab.key[i]), 10) catch return invalid(node.u.tab.value[i], key, "index must be 0–255");
            destination[index] = try colorValue(node.u.tab.value[i], key);
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (node.type != c.TOML_TABLE) return invalid(node, key, "expected a table");
            for (0..@intCast(node.u.tab.size)) |i| {
                const name = std.mem.span(node.u.tab.key[i]);
                const path = if (key.len == 0) name else try std.fmt.allocPrint(allocator, "{s}.{s}", .{ key, name });
                var found = false;
                inline for (info.field_names, info.field_types) |field_name, FieldType| if (std.mem.eql(u8, name, field_name)) {
                    try self.decode(FieldType, &@field(destination, field_name), node.u.tab.value[i], path);
                    found = true;
                };
                if (!found) return invalid(node.u.tab.value[i], path, "unknown setting");
            }
        },
        .pointer => |info| {
            if (info.child == u8) {
                destination.* = try allocator.dupe(u8, try string(node, key));
            } else {
                if (node.type != c.TOML_ARRAY) return invalid(node, key, "expected an array");
                const values = try allocator.alloc(info.child, @intCast(node.u.arr.size));
                for (values, 0..) |*value, i| {
                    value.* = if (@typeInfo(info.child) == .@"struct") .{} else undefined;
                    try self.decode(info.child, value, node.u.arr.elem[i], key);
                }
                destination.* = values;
            }
        },
        .array => |info| {
            if (node.type != c.TOML_ARRAY or node.u.arr.size != info.len) return invalid(node, key, "expected exactly eight colors");
            for (0..info.len) |i| try self.decode(info.child, &destination[i], node.u.arr.elem[i], key);
        },
        .optional => |info| {
            var value: info.child = undefined;
            try self.decode(info.child, &value, node, key);
            destination.* = value;
        },
        .bool => {
            if (node.type != c.TOML_BOOLEAN) return invalid(node, key, "expected true or false");
            destination.* = node.u.boolean;
        },
        .int => {
            if (node.type != c.TOML_INT64) return invalid(node, key, "expected an integer");
            destination.* = std.math.cast(T, node.u.int64) orelse return invalid(node, key, "integer out of range");
        },
        .float => {
            destination.* = if (node.type == c.TOML_INT64) @floatFromInt(node.u.int64) else if (node.type == c.TOML_FP64) node.u.fp64 else return invalid(node, key, "expected a number");
            if (!std.math.isFinite(destination.*)) return invalid(node, key, "number must be finite");
        },
        .@"enum" => destination.* = std.meta.stringToEnum(T, try string(node, key)) orelse return invalid(node, key, "unknown option"),
        else => @compileError("unsupported config type " ++ @typeName(T)),
    }
}
fn bad(self: *Config, key: []const u8, message: []const u8, err: anyerror) anyerror {
    if (self.locations.get(key)) |location| {
        std.debug.print("vertex: {s}:{d}:{d}: {s}: {s}\n", .{ location.source, location.line, location.column, key, message });
    } else std.debug.print("vertex: {s}: {s}: {s}\n", .{ self.root orelse "environment", key, message });
    return err;
}
fn validate(self: *Config) !void {
    const v = &self.value;
    if (!std.math.isFinite(v.font.size) or v.font.size < 4 or v.font.size > 128) return self.bad("font.size", "expected 4–128 points", error.InvalidFontSize);
    if (v.font.family.len == 0) return self.bad("font.family", "font family cannot be empty", error.InvalidConfig);
    inline for (.{ "bold_family", "italic_family", "bold_italic_family" }) |field| if (@field(v.font, field)) |family| if (family.len == 0) return self.bad("font." ++ field, "font family cannot be empty", error.InvalidConfig);
    if (v.window.app_id.len == 0 or v.window.app_id.len > 255) return self.bad("window.app_id", "expected 1–255 characters", error.InvalidAppId);
    for (v.window.app_id) |byte| if (byte <= 0x20 or byte == '/' or byte == '\\') return self.bad("window.app_id", "cannot contain whitespace or path separators", error.InvalidAppId);
    if (v.window.title.len > 4095) return self.bad("window.title", "title exceeds 4095 bytes", error.InvalidConfig);
    for (v.window.title) |byte| if (byte < 0x20 or byte == 0x7f) return self.bad("window.title", "control characters are not allowed", error.InvalidConfig);
    if (v.window.rows == 0 or v.window.rows > 4096) return self.bad("window.rows", "expected 1–4096", error.InvalidWindowSize);
    if (v.window.columns == 0 or v.window.columns > 4096 or @as(u32, v.window.columns) * v.window.rows > 1024 * 1024) return self.bad("window.columns", "expected 1–4096, at most 1M cells", error.InvalidWindowSize);
    inline for (.{ "left", "right", "top", "bottom" }) |field| if (@field(v.window.padding, field) > 8192) return self.bad("window.padding." ++ field, "padding exceeds 8192 logical pixels", error.InvalidWindowSize);
    if (v.window.opacity < 0 or v.window.opacity > 1) return self.bad("window.opacity", "expected 0–1", error.InvalidOpacity);
    if (v.window.unfocused_opacity) |opacity| if (opacity < 0 or opacity > 1) return self.bad("window.unfocused_opacity", "expected 0–1", error.InvalidOpacity);
    if (v.colors.dim_factor < 0 or v.colors.dim_factor > 1) return self.bad("colors.dim_factor", "expected 0–1", error.InvalidConfig);
    if (v.mouse.wheel_multiplier < 0 or v.mouse.wheel_multiplier > 100) return self.bad("mouse.wheel_multiplier", "expected 0–100", error.InvalidConfig);
    if (v.cursor.thickness == 0 or v.cursor.thickness > 128) return self.bad("cursor.thickness", "expected 1–128 logical pixels", error.InvalidCursor);
    if (v.cursor.blink_interval < 100 or v.cursor.blink_interval > 10000) return self.bad("cursor.blink_interval", "expected 100–10000 ms", error.InvalidCursor);
    inline for (.{ "cell_width_offset", "cell_height_offset", "glyph_offset_x", "glyph_offset_y" }) |field| if (@abs(@field(v.font, field)) > 256) return self.bad("font." ++ field, "expected -256–256 logical pixels", error.InvalidFontSpacing);
    for (v.font.features) |feature| {
        var parsed: c.hb_feature_t = undefined;
        if (c.hb_feature_from_string(feature.ptr, @intCast(feature.len), &parsed) == 0) return self.bad("font.features", "invalid OpenType feature", error.InvalidFontFeature);
    }
    for (v.keyboard.bindings, 0..) |binding, i| {
        if (keySymbol(binding.key) == 0) return self.bad("keyboard.bindings.key", "expected an XKB keysym name", error.InvalidBindingKey);
        const mods = parseModifiers(binding.mods) catch |err| return self.bad("keyboard.bindings.mods", "expected modifiers separated by |", err);
        for (v.keyboard.bindings[0..i]) |previous| if (keySymbol(previous.key) == keySymbol(binding.key) and mods == try parseModifiers(previous.mods)) return self.bad("keyboard.bindings", "duplicate shortcut", error.DuplicateBinding);
        if (binding.action == .send_text and binding.text == null) return self.bad("keyboard.bindings", "send_text requires text", error.MissingBindingText);
        if (binding.action == .launch and (binding.command.len == 0 or binding.command[0].len == 0)) return self.bad("keyboard.bindings", "launch requires a command argument vector", error.MissingBindingCommand);
        if (binding.action != .send_text and binding.text != null) return self.bad("keyboard.bindings", "text is only used by send_text", error.UnusedBindingText);
        if (binding.action != .launch and binding.command.len != 0) return self.bad("keyboard.bindings", "command is only used by launch", error.UnusedBindingCommand);
    }
    if (v.terminal.shell.len != 0 and v.terminal.shell[0].len == 0) return self.bad("terminal.shell", "executable cannot be empty", error.InvalidShell);
    if (v.terminal.working_directory) |directory| v.terminal.working_directory = try self.resolve(directory, if (self.root) |root| std.fs.path.dirname(root) else null);
}
pub fn keySymbol(key: []const u8) u32 {
    var buffer: [128:0]u8 = @splat(0);
    if (key.len == 0 or key.len >= buffer.len) return 0;
    @memcpy(buffer[0..key.len], key);
    return c.xkb_keysym_from_name(&buffer, c.XKB_KEYSYM_CASE_INSENSITIVE);
}
pub fn parseModifiers(text: []const u8) !u8 {
    var result: u8 = 0;
    var parts = std.mem.splitScalar(u8, text, '|');
    while (parts.next()) |part| {
        if (part.len == 0 and text.len == 0) continue;
        const bit: u8 = if (std.ascii.eqlIgnoreCase(part, "Shift")) 1 else if (std.ascii.eqlIgnoreCase(part, "Control")) 2 else if (std.ascii.eqlIgnoreCase(part, "Alt")) 4 else if (std.ascii.eqlIgnoreCase(part, "Super")) 8 else return error.InvalidBindingModifiers;
        if (result & bit != 0) return error.InvalidBindingModifiers;
        result |= bit;
    }
    return result;
}
pub fn modifierBits(mods: Input.Modifiers) u8 {
    return @as(u8, @intFromBool(mods.shift)) | (@as(u8, @intFromBool(mods.control)) << 1) | (@as(u8, @intFromBool(mods.alt)) << 2) | (@as(u8, @intFromBool(mods.super)) << 3);
}
pub fn modifierHeld(modifier: Modifier, mods: Input.Modifiers) bool {
    return switch (modifier) {
        .none => false,
        .shift => mods.shift,
        .control => mods.control,
        .alt => mods.alt,
        .super => mods.super,
    };
}
