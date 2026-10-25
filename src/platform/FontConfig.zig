//! Startup-only font settings. Explicit renderer initializers never read these.
const std = @import("std");
const c = @import("c");
const Config = @This();

font_family: []const u8 = "monospace",
font_size: f64 = 12,

pub fn parseSize(value: []const u8) !f64 {
    const size = std.fmt.parseFloat(f64, value) catch return error.InvalidFontSize;
    if (!std.math.isFinite(size) or size < 4 or size > 128) return error.InvalidFontSize;
    return size;
}

/// Values borrow input; comments occupy a whole line. Optional quotes are accepted.
pub fn parse(text: []const u8) !Config {
    var result: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidFontConfig;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        var value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (std.mem.eql(u8, key, "font_family")) {
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidFontConfig;
            result.font_family = value;
        } else if (std.mem.eql(u8, key, "font_size")) {
            result.font_size = try parseSize(value);
        } else return error.InvalidFontConfig;
    }
    return result;
}

pub fn path(allocator: std.mem.Allocator, xdg: ?[]const u8, home: ?[]const u8) !?[:0]u8 {
    if (xdg) |base| if (std.fs.path.isAbsolute(base)) return try std.fmt.allocPrintSentinel(allocator, "{s}/vertex/config", .{base}, 0);
    if (home) |base| if (base.len != 0) return try std.fmt.allocPrintSentinel(allocator, "{s}/.config/vertex/config", .{base}, 0);
    return null;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name);
    return if (value == null) null else std.mem.span(value);
}

pub fn overrides(config: Config, family: ?[]const u8, size: ?[]const u8) !Config {
    var result = config;
    if (family) |value| result.font_family = if (value.len == 0) "monospace" else value;
    if (size) |value| if (value.len != 0) {
        result.font_size = try parseSize(value);
    };
    return result;
}

/// The returned family is owned and must be freed by the caller.
pub fn load(allocator: std.mem.Allocator) !Config {
    const filename = try path(allocator, env("XDG_CONFIG_HOME"), env("HOME"));
    defer if (filename) |name| allocator.free(name);
    return loadAt(allocator, filename, env("VERTEX_FONT"), env("VERTEX_FONT_SIZE"));
}

/// Injectable paths and overrides keep tests independent of the user's settings.
pub fn loadAt(allocator: std.mem.Allocator, filename: ?[:0]const u8, family: ?[]const u8, size: ?[]const u8) !Config {
    var data: [65537]u8 = undefined;
    var length: usize = 0;
    if (filename) |name| {
        const fd = c.open(name.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) {
            if (c.__errno_location().* != c.ENOENT) return error.FontConfigReadFailed;
        } else {
            defer _ = c.close(fd);
            while (length < data.len) {
                const n = c.read(fd, data[length..].ptr, data.len - length);
                if (n < 0) {
                    if (c.__errno_location().* == c.EINTR) continue;
                    return error.FontConfigReadFailed;
                }
                if (n == 0) break;
                length += @intCast(n);
            }
            if (length == data.len) return error.FontConfigTooLarge;
        }
    }
    const config = try overrides(try parse(data[0..length]), family, size);
    return .{ .font_family = try allocator.dupe(u8, config.font_family), .font_size = config.font_size };
}

test "font settings load from disk and missing files preserve environment overrides" {
    const t = std.testing;
    const missing = try loadAt(t.allocator, "/tmp/vertex-missing-font-config/no-config", null, "13");
    defer t.allocator.free(missing.font_family);
    try t.expectEqualStrings("monospace", missing.font_family);
    try t.expectEqual(@as(f64, 13), missing.font_size);
    var filename = "/tmp/vertex-font-config-XXXXXX".*;
    const fd = c.mkstemp(&filename);
    if (fd < 0) return error.TestFileFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(&filename);
    const text = "font_family = Vertex Test Mono\nfont_size = 13.25\n";
    try t.expectEqual(@as(isize, text.len), c.write(fd, text, text.len));
    const config = try loadAt(t.allocator, &filename, "sans", null);
    defer t.allocator.free(config.font_family);
    try t.expectEqualStrings("sans", config.font_family);
    try t.expectEqual(@as(f64, 13.25), config.font_size);
    try t.expectError(error.InvalidFontSize, loadAt(t.allocator, &filename, null, "nan"));
}

test "font config values paths validation and environment precedence" {
    const t = std.testing;
    const parsed = try parse("# Kitty equivalent\nfont_family = \"JetBrainsMonoNL Nerd Font\"\r\nfont_size = 13.25\n");
    try t.expectEqualStrings("JetBrainsMonoNL Nerd Font", parsed.font_family);
    try t.expectEqual(@as(f64, 13.25), parsed.font_size);
    const override = try overrides(parsed, "sans", "15.5");
    try t.expectEqualStrings("sans", override.font_family);
    try t.expectEqual(@as(f64, 15.5), override.font_size);
    try t.expectEqualStrings("monospace", (try overrides(parsed, "", null)).font_family);
    try t.expectEqual(@as(f64, 13.25), (try overrides(parsed, null, "")).font_size);
    for ([_][]const u8{ "0", "-1", "nan", "inf", "129", "bad" }) |bad| try t.expectError(error.InvalidFontSize, parseSize(bad));
    try t.expectError(error.InvalidFontConfig, parse("font_family ="));
    try t.expectError(error.InvalidFontConfig, parse("unknown = 3"));
    const xdg = (try path(t.allocator, "/tmp/settings", "/home/test")).?;
    defer t.allocator.free(xdg);
    try t.expectEqualStrings("/tmp/settings/vertex/config", xdg);
    const home = (try path(t.allocator, "relative", "/home/test")).?;
    defer t.allocator.free(home);
    try t.expectEqualStrings("/home/test/.config/vertex/config", home);
    try t.expect(try path(t.allocator, null, null) == null);
}
