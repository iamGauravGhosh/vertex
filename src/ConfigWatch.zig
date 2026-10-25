//! Filtered directory watches survive editor rename saves and missing directories.
const std = @import("std");
const c = @import("c");
const common = @import("platform/common.zig");
const Watch = @This();
const Entry = struct { wd: c_int, name: []const u8 };
fd: c_int = -1,
arena: ?*std.heap.ArenaAllocator = null,
entries: std.ArrayList(Entry) = .empty,
deadline: ?i64 = null,

pub fn init(allocator: std.mem.Allocator, paths: []const []const u8) !Watch {
    var self: Watch = .{ .fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC) };
    if (self.fd < 0) return error.ConfigWatchFailed;
    errdefer self.deinit();
    self.arena = try allocator.create(std.heap.ArenaAllocator);
    self.arena.?.* = std.heap.ArenaAllocator.init(allocator);
    try self.addPaths(paths);
    return self;
}
pub fn addPaths(self: *Watch, paths: []const []const u8) !void {
    const scratch = self.arena.?.allocator();
    for (paths) |path| {
        var target = path;
        while (std.fs.path.dirname(target)) |dir| {
            var name: [4096:0]u8 = @splat(0);
            if (dir.len >= name.len) return error.ConfigPathTooLong;
            @memcpy(name[0..dir.len], dir);
            const wd = c.inotify_add_watch(self.fd, &name, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_MOVED_FROM | c.IN_CREATE | c.IN_DELETE | c.IN_DELETE_SELF | c.IN_MOVE_SELF | c.IN_ATTRIB);
            if (wd >= 0) {
                const basename = std.fs.path.basename(target);
                var duplicate = false;
                for (self.entries.items) |entry| if (entry.wd == wd and std.mem.eql(u8, entry.name, basename)) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) try self.entries.append(scratch, .{ .wd = wd, .name = try scratch.dupe(u8, basename) });
            } else if (c.__errno_location().* != c.ENOENT and c.__errno_location().* != c.EACCES) return error.ConfigWatchFailed;
            if (std.mem.eql(u8, dir, "/")) break;
            target = dir;
        }
    }
}
pub fn deinit(self: *Watch) void {
    if (self.fd >= 0) _ = c.close(self.fd);
    if (self.arena) |arena| {
        const parent = arena.child_allocator;
        arena.deinit();
        parent.destroy(arena);
    }
    self.* = .{};
}
pub fn poll(self: *Watch) bool {
    if (self.fd < 0) return false;
    var buffer: [8192]u8 align(@alignOf(c.inotify_event)) = undefined;
    while (true) {
        const count = c.read(self.fd, &buffer, buffer.len);
        if (count < 0 and c.__errno_location().* == c.EINTR) continue;
        if (count <= 0) break;
        var offset: usize = 0;
        while (offset + @sizeOf(c.inotify_event) <= count) {
            const event: *const c.inotify_event = @ptrCast(@alignCast(buffer[offset..].ptr));
            const end = offset + @sizeOf(c.inotify_event) + event.len;
            if (end > count) break;
            const name = std.mem.sliceTo(buffer[offset + @sizeOf(c.inotify_event) .. end], 0);
            var relevant = event.mask & (c.IN_Q_OVERFLOW | c.IN_IGNORED | c.IN_DELETE_SELF | c.IN_MOVE_SELF) != 0;
            for (self.entries.items) |entry| if (entry.wd == event.wd and std.mem.eql(u8, name, entry.name)) {
                relevant = true;
                break;
            };
            if (relevant) self.deadline = common.milliseconds() + 120;
            offset = end;
        }
    }
    if (self.deadline) |deadline| if (common.milliseconds() >= deadline) {
        self.deadline = null;
        return true;
    };
    return false;
}
