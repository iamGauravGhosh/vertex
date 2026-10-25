const std = @import("std");
const c = @import("c");
const Config = @import("Config.zig");
const t = std.testing;
fn settings(text: []const u8) !Config {
    var name = "/tmp/vertex-toml-test-XXXXXX".*;
    const fd = c.mkstemp(&name);
    if (fd < 0) return error.TempFileFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(&name);
    if (c.write(fd, text.ptr, text.len) != text.len) return error.TempFileFailed;
    return Config.loadAt(t.allocator, &name, true, false);
}
test "TOML defaults round trip through owned configuration" {
    var config = try settings(Config.defaults);
    defer config.deinit();
    try t.expectEqualStrings("monospace", config.value.font.family);
    try t.expect(!config.value.font.ligatures);
    try t.expectEqual(@as(f64, 12), config.value.font.size);
    try t.expectEqual(@as(u32, 0x15171a), config.value.colors.background);
    try t.expectEqual(@as(usize, 5), config.value.keyboard.bindings.len);
    try t.expectEqual(@as(u16, 80), config.value.window.columns);
}
test "TOML syntax features nested values and color overrides" {
    var config = try settings(
        "font = { family = 'Vertex Test Mono', size = 13.25, ligatures = true, features = ['ss01=1'] }\n" ++
            "window.padding.left = 12\nwindow.opacity = 0.75 # inline comment\n" ++
            "colors.background = '#123456'\n[colors.indexed]\n'200' = '#aabbcc'\n" ++
            "[terminal.env]\nEDITOR = 'nvim'\n" ++
            "[[keyboard.bindings]]\nkey='F5'\naction='send_text'\ntext=\"hello\\n\"\n",
    );
    defer config.deinit();
    try t.expect(config.value.font.ligatures);
    try t.expectEqual(@as(u16, 12), config.value.window.padding.left);
    try t.expectEqual(@as(u32, 0xaabbcc), config.value.colors.at(200));
    try t.expectEqualStrings("nvim", config.value.terminal.env[0].value);
    try t.expectEqualStrings("hello\n", config.value.keyboard.bindings[0].text.?);
}
test "TOML rejects unknown duplicates invalid values and partial bindings" {
    for ([_][]const u8{
        "[font]\nunknown = true",         "[font]\nsize=12\nsize=13",           "[font]\nsize=nan",                                   "[font]\nsize=129",
        "[font]\nligatures='yes'",        "[window]\nopacity=1.1",              "[colors]\nbackground='red'",                         "[cursor]\nblink_interval=0",
        "[font]\ncell_width_offset=-300", "[font]\nfeatures=['not a feature']", "[[keyboard.bindings]]\nkey='v'\naction='send_text'", "[terminal.env]\n'BAD=NAME'='x'",
    }) |text| {
        if (settings(text)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedInvalidConfig;
        } else |_| {}
    }
}
test "config paths and explicit missing file behavior" {
    const path = (try Config.defaultPath(t.allocator, "relative", "/home/test")).?;
    defer t.allocator.free(path);
    try t.expectEqualStrings("/home/test/.config/vertex/config.toml", path);
    var config = try Config.loadAt(t.allocator, "/tmp/vertex-config-test-does-not-exist", false, false);
    defer config.deinit();
    try t.expectError(error.ConfigReadFailed, Config.loadAt(t.allocator, "/tmp/vertex-config-test-does-not-exist", true, false));
}
test "imports merge tables replace arrays and reject cycles" {
    var directory = "/tmp/vertex-import-test-XXXXXX".*;
    if (c.mkdtemp(&directory) == null) return error.TempFileFailed;
    defer _ = c.rmdir(&directory);
    const child = try std.fmt.allocPrintSentinel(t.allocator, "{s}/theme.toml", .{directory}, 0);
    defer t.allocator.free(child);
    const root = try std.fmt.allocPrintSentinel(t.allocator, "{s}/config.toml", .{directory}, 0);
    defer t.allocator.free(root);
    defer _ = c.unlink(child);
    defer _ = c.unlink(root);
    try writeFile(child, "font.size=15\ncolors.background='#123456'\nkeyboard.bindings=[]\nterminal.env.A='one'\nterminal.env.B='base'\n");
    try writeFile(root, "general.import=['theme.toml']\nfont.size=14\nterminal.env.B='override'\n");
    var config = try Config.loadAt(t.allocator, root, true, false);
    defer config.deinit();
    try t.expectEqual(@as(f64, 14), config.value.font.size);
    try t.expectEqual(@as(u32, 0x123456), config.value.colors.background);
    try t.expectEqual(@as(usize, 0), config.value.keyboard.bindings.len);
    try t.expectEqualStrings("override", config.value.terminal.env[1].value);
    try writeFile(child, "general.import=['config.toml']");
    try t.expectError(error.ConfigImportCycle, Config.loadAt(t.allocator, root, true, false));
}
fn writeFile(path: [:0]const u8, text: []const u8) !void {
    const fd = c.open(path, c.O_CREAT | c.O_TRUNC | c.O_WRONLY | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.TempFileFailed;
    defer _ = c.close(fd);
    if (c.write(fd, text.ptr, text.len) != text.len) return error.TempFileFailed;
}

test "directory watch handles rename saves missing parents and ignores unrelated files" {
    const Watch = @import("ConfigWatch.zig");
    const common = @import("platform/common.zig");
    var directory = "/tmp/vertex-watch-test-XXXXXX".*;
    if (c.mkdtemp(&directory) == null) return error.TempFileFailed;
    defer _ = c.rmdir(&directory);
    const path = try std.fmt.allocPrintSentinel(t.allocator, "{s}/config.toml", .{directory}, 0);
    defer t.allocator.free(path);
    const other = try std.fmt.allocPrintSentinel(t.allocator, "{s}/unrelated", .{directory}, 0);
    defer t.allocator.free(other);
    defer _ = c.unlink(path);
    defer _ = c.unlink(other);
    var watch = try Watch.init(t.allocator, &.{path});
    defer watch.deinit();
    try writeFile(other, "ignored");
    try t.expect(!watch.poll());
    try t.expect(watch.deadline == null);
    try t.expectEqual(@as(c_int, 0), c.rename(other, path));
    _ = watch.poll();
    try t.expect(watch.deadline != null);
    const deadline = common.milliseconds() + 1000;
    var ready = false;
    while (common.milliseconds() < deadline) {
        if (watch.poll()) {
            ready = true;
            break;
        }
        _ = c.poll(null, 0, 10);
    }
    try t.expect(ready);
    const nested = try std.fmt.allocPrintSentinel(t.allocator, "{s}/missing/config.toml", .{directory}, 0);
    defer t.allocator.free(nested);
    try watch.addPaths(&.{nested});
    const subdir = try std.fmt.allocPrintSentinel(t.allocator, "{s}/missing", .{directory}, 0);
    defer t.allocator.free(subdir);
    defer _ = c.rmdir(subdir);
    try t.expectEqual(@as(c_int, 0), c.mkdir(subdir, 0o700));
    _ = watch.poll();
    try t.expect(watch.deadline != null);
}

test "configured PTY starts in its directory with environment overrides" {
    const Pty = @import("platform/Pty.zig");
    const common = @import("platform/common.zig");
    var pty = try Pty.spawnConfigured(t.allocator, &.{ "/bin/sh", "-c", "printf '%s:%s:%s' \"$PWD\" \"$VERTEX_CONFIG_TEST\" \"$TERM\"" }, 24, 80, 0, 0, .{ .working_directory = "/tmp", .env = &.{ .{ .name = "VERTEX_CONFIG_TEST", .value = "configured" }, .{ .name = "TERM", .value = "custom-term" } } });
    defer pty.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(t.allocator);
    const deadline = common.milliseconds() + 3000;
    while (common.milliseconds() < deadline) {
        var buffer: [1024]u8 = undefined;
        const count = c.read(pty.master, &buffer, buffer.len);
        if (count > 0) try output.appendSlice(t.allocator, buffer[0..@intCast(count)]);
        if (try pty.pollExit()) |_| break;
        _ = c.poll(null, 0, 10);
    }
    try t.expectEqualStrings("/tmp:configured:custom-term", output.items);
    try t.expectEqual(@as(?u8, 0), try pty.pollExit());
    try t.expectError(error.WorkingDirectoryFailed, Pty.spawnConfigured(t.allocator, &.{"/bin/sh"}, 24, 80, 0, 0, .{ .working_directory = "/vertex/missing/directory" }));
}

test "environment overrides preserve empty size and override individual settings" {
    var config = try settings("font.size=13.25\nfont.family='configured'\n");
    defer config.deinit();
    try config.applyOverrides(.{ .family = "sans", .size = "", .renderer = "cpu", .bidi = "auto" });
    try t.expectEqualStrings("sans", config.value.font.family);
    try t.expectEqual(@as(f64, 13.25), config.value.font.size);
    try t.expect(config.value.terminal.renderer == .cpu and config.value.terminal.bidi == .auto);
    try config.applyOverrides(.{ .family = "", .size = "14.5" });
    try t.expectEqualStrings("monospace", config.value.font.family);
    try t.expectEqual(@as(f64, 14.5), config.value.font.size);
    try t.expectError(error.InvalidFontSize, config.applyOverrides(.{ .size = "nan" }));
    try t.expectError(error.InvalidRenderer, config.applyOverrides(.{ .renderer = "invalid" }));
    try t.expectError(error.InvalidBidi, config.applyOverrides(.{ .bidi = "invalid" }));
}
fn allocationSnapshot(allocator: std.mem.Allocator) !void {
    var config = try Config.loadAt(allocator, null, false, false);
    defer config.deinit();
    try config.applyOverrides(.{ .family = "owned font", .size = "13.5" });
}
test "configuration snapshot allocation failures release owned storage" {
    try std.testing.checkAllAllocationFailures(t.allocator, allocationSnapshot, .{});
}

test "shipped themes use the same validated schema" {
    for ([_][]const u8{ "assets/themes/dark.toml", "assets/themes/light.toml", "assets/config.example.toml" }) |path| {
        var config = try Config.loadAt(t.allocator, path, true, false);
        defer config.deinit();
        try t.expect(config.value.colors.foreground != config.value.colors.background);
    }
}

fn allocationFileSnapshot(allocator: std.mem.Allocator) !void {
    var config = try Config.loadAt(allocator, "assets/config.example.toml", true, false);
    defer config.deinit();
    try t.expectEqualStrings("monospace", config.value.font.family);
}
test "TOML snapshot decoding cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(t.allocator, allocationFileSnapshot, .{});
}
