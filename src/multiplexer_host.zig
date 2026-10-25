//! Test-only PTY host. JSON lines on stdin control input/resize/snapshots.
//! This exercises Vertex's actual parser, Session, input encoder and PTY.
const std = @import("std");
const c = @import("c");
const vt = @import("terminal/root.zig");
const Pty = @import("platform/Pty.zig");
const common = @import("platform/common.zig");

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 1;
    run(args[1..]) catch |err| {
        std.debug.print("multiplexer host: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            if (common.errno() == c.EINTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
fn snapshot(allocator: std.mem.Allocator, session: *vt.Session, clipboard: ?[]const u8) !void {
    const screen = session.activeScreen();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const lines = try scratch.alloc([]const u8, screen.rows);
    for (lines, 0..) |*line, row| {
        var text: std.ArrayList(u8) = .empty;
        for (0..screen.columns) |col| {
            for (screen.getGrapheme(row, col).?) |cp| {
                var bytes: [4]u8 = undefined;
                const count = try std.unicode.utf8Encode(cp, &bytes);
                try text.appendSlice(scratch, bytes[0..count]);
            }
        }
        line.* = text.items;
    }
    const json = try std.json.Stringify.valueAlloc(scratch, .{ .rows = screen.rows, .columns = screen.columns, .lines = lines, .cursor = screen.cursor, .alternate = session.alternate, .modes = session.getModes(), .clipboard = clipboard }, .{});
    try writeAll(1, json);
    try writeAll(1, "\n");
}
fn run(args: []const []const u8) !void {
    const allocator = std.heap.page_allocator;
    if (args.len == 0) return error.MissingCommand;
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    var child = try Pty.spawn(allocator, args, 24, 80);
    defer child.deinit();
    const trace_path = c.getenv("VERTEX_HOST_TRACE");
    const trace = if (trace_path != null) c.open(trace_path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600)) else -1;
    defer if (trace >= 0) {
        _ = c.close(trace);
    };
    var session = try vt.Session.init(allocator, 24, 80);
    defer session.deinit();
    var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
    var commands: std.ArrayList(u8) = .empty;
    defer commands.deinit(allocator);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var offset: usize = 0;
    var clipboard: ?[]u8 = null;
    defer if (clipboard) |bytes| allocator.free(bytes);
    while (true) {
        _ = session.presentationHeld(common.milliseconds());
        var fds = [_]c.pollfd{
            .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.master, .events = @as(c_short, c.POLLIN) | (if (offset < pending.items.len) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
        };
        const result = c.poll(&fds, 2, 20);
        if (result < 0) {
            if (common.errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        var bytes: [4096]u8 = undefined;
        // Drain ready output before answering a snapshot request.
        if (fds[1].revents & (c.POLLIN | c.POLLHUP) != 0) {
            var budget: usize = 256 * 1024;
            while (budget > 0) {
                const count = child.read(bytes[0..@min(bytes.len, budget)]) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
                if (count == 0) break;
                if (trace >= 0) try writeAll(trace, bytes[0..count]);
                parser.feed(bytes[0..count], &session);
                if (session.takeError()) |err| return err;
                try pending.appendSlice(allocator, session.replies.items);
                session.replies.clearRetainingCapacity();
                if (session.takeClipboard()) |text| {
                    if (clipboard) |old| allocator.free(old);
                    clipboard = text;
                }
                budget -= count;
            }
        }
        if (fds[0].revents & c.POLLIN != 0) {
            const count = c.read(0, &bytes, bytes.len);
            if (count <= 0) return;
            if (commands.items.len + @as(usize, @intCast(count)) > 16 * 1024 * 1024) return error.CommandTooLarge;
            try commands.appendSlice(allocator, bytes[0..@intCast(count)]);
            while (std.mem.indexOfScalar(u8, commands.items, '\n')) |end| {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, commands.items[0..end], .{});
                defer parsed.deinit();
                const object = parsed.value.object;
                if (object.get("input")) |value| try pending.appendSlice(allocator, value.string);
                if (object.get("key")) |value| {
                    var key = try std.json.parseFromValue(vt.Input.Key, allocator, value, .{});
                    defer key.deinit();
                    var encoded: [256]u8 = undefined;
                    try pending.appendSlice(allocator, try vt.Input.encodeKey(&encoded, key.value, session.getModes()));
                }
                if (object.get("pointer")) |value| {
                    var pointer = try std.json.parseFromValue(vt.Input.Pointer, allocator, value, .{});
                    defer pointer.deinit();
                    var encoded: [128]u8 = undefined;
                    try pending.appendSlice(allocator, try vt.Input.encodePointer(&encoded, pointer.value, session.getModes()));
                }
                if (object.get("paste")) |value| {
                    const text = try vt.Input.paste(allocator, value.string, session.getModes().bracketed_paste);
                    defer allocator.free(text);
                    try pending.appendSlice(allocator, text);
                }
                if (object.get("resize")) |value| {
                    const rows: usize = @intCast(value.array.items[0].integer);
                    const columns: usize = @intCast(value.array.items[1].integer);
                    if (rows == 0 or columns == 0 or rows > 256 or columns > 512) return error.InvalidDimensions;
                    try session.resize(rows, columns);
                    try child.resize(rows, columns);
                }
                if (object.get("snapshot") != null) try snapshot(allocator, &session, clipboard);
                if (object.get("close") != null) return;
                std.mem.copyForwards(u8, commands.items, commands.items[end + 1 ..]);
                commands.items.len -= end + 1;
            }
        } else if (fds[0].revents & c.POLLHUP != 0) return;
        while (offset < pending.items.len) {
            const count = child.write(pending.items[offset..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (count == 0) break;
            offset += count;
        }
        if (offset == pending.items.len) {
            pending.clearRetainingCapacity();
            offset = 0;
        }
        // Keep accepting snapshots after a short-lived explicit command exits.
        _ = try child.pollExit();
    }
}

test "multiplexer host driver" {
    const command = c.getenv("VERTEX_HOST_COMMAND") orelse return error.SkipZigTest;
    var parsed = try std.json.parseFromSlice([]const []const u8, std.testing.allocator, std.mem.span(command), .{});
    defer parsed.deinit();
    try run(parsed.value);
}
