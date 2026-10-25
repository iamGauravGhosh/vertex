//! A child session with a controlling terminal. No window-system dependencies.
const std = @import("std");
const c = @import("c");
const common = @import("common.zig");
const Pty = @This();

master: c_int,
pid: c.pid_t,
status: ?u8 = null,

pub fn spawn(allocator: std.mem.Allocator, command: []const []const u8, rows: usize, columns: usize) !Pty {
    return spawnPixels(allocator, command, rows, columns, 0, 0);
}
pub const Env = struct { name: []const u8, value: []const u8 };
pub const Options = struct { working_directory: ?[]const u8 = null, env: []const Env = &.{} };
pub fn spawnPixels(allocator: std.mem.Allocator, command: []const []const u8, rows: usize, columns: usize, width: usize, height: usize) !Pty {
    return spawnConfigured(allocator, command, rows, columns, width, height, .{});
}
pub fn spawnConfigured(allocator: std.mem.Allocator, command: []const []const u8, rows: usize, columns: usize, width: usize, height: usize, options: Options) !Pty {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var shell: []const u8 = "/bin/sh";
    const environment_shell = c.getenv("SHELL");
    if (environment_shell != null and environment_shell[0] != 0) {
        shell = std.mem.span(environment_shell);
    } else if (c.getpwuid(c.getuid())) |account| {
        if (account.*.pw_shell != null and account.*.pw_shell[0] != 0) shell = std.mem.span(account.*.pw_shell);
    }
    const arguments = if (command.len == 0) &[_][]const u8{ shell, "-i" } else command;
    const argv = try scratch.alloc(?[*:0]const u8, arguments.len + 1);
    for (arguments, 0..) |argument, i| argv[i] = (try scratch.dupeSentinel(u8, argument, 0)).ptr;
    argv[arguments.len] = null;
    const directory = if (options.working_directory) |path| try scratch.dupeSentinel(u8, path, 0) else null;
    var environment: std.ArrayList(?[*:0]const u8) = .empty;
    var index: usize = 0;
    while (c.environ[index] != null) : (index += 1) {
        const value = std.mem.span(c.environ[index]);
        if (std.mem.startsWith(u8, value, "TERM=") or std.mem.startsWith(u8, value, "COLORTERM=") or std.mem.startsWith(u8, value, "TERM_PROGRAM=") or std.mem.startsWith(u8, value, "TERM_PROGRAM_VERSION=")) continue;
        var overridden = false;
        for (options.env) |entry| if (std.mem.startsWith(u8, value, entry.name) and value.len > entry.name.len and value[entry.name.len] == '=') {
            overridden = true;
            break;
        };
        if (!overridden) try environment.append(scratch, c.environ[index]);
    }
    var term = false;
    var colorterm = false;
    var term_program = false;
    var term_version = false;
    for (options.env) |entry| {
        try environment.append(scratch, try std.fmt.allocPrintSentinel(scratch, "{s}={s}", .{ entry.name, entry.value }, 0));
        term = term or std.mem.eql(u8, entry.name, "TERM");
        colorterm = colorterm or std.mem.eql(u8, entry.name, "COLORTERM");
        term_program = term_program or std.mem.eql(u8, entry.name, "TERM_PROGRAM");
        term_version = term_version or std.mem.eql(u8, entry.name, "TERM_PROGRAM_VERSION");
    }
    if (!term) try environment.append(scratch, "TERM=xterm-256color");
    if (!colorterm) try environment.append(scratch, "COLORTERM=truecolor");
    if (!term_program) try environment.append(scratch, "TERM_PROGRAM=vertex");
    if (!term_version) try environment.append(scratch, "TERM_PROGRAM_VERSION=0.0.1");
    try environment.append(scratch, null);
    var errors: [2]c_int = undefined;
    if (c.pipe2(&errors, c.O_CLOEXEC) != 0) return error.PipeFailed;
    defer _ = c.close(errors[0]);
    var size = windowSize(rows, columns);
    size.ws_xpixel = @intCast(@min(width, 65535));
    size.ws_ypixel = @intCast(@min(height, 65535));
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &size);
    if (pid < 0) {
        _ = c.close(errors[1]);
        return error.ForkPtyFailed;
    }
    if (pid == 0) {
        _ = c.close(errors[0]);
        var mask: c.sigset_t = undefined;
        _ = c.sigemptyset(&mask);
        _ = c.sigprocmask(c.SIG_SETMASK, &mask, null);
        for ([_]c_int{ c.SIGINT, c.SIGQUIT, c.SIGTERM, c.SIGHUP, c.SIGCHLD, c.SIGPIPE, c.SIGWINCH, c.SIGTSTP, c.SIGTTIN, c.SIGTTOU }) |signal| {
            _ = c.signal(signal, c.SIG_DFL);
        }
        if (directory) |path| if (c.chdir(path) != 0) {
            const failure = -common.errno();
            _ = c.write(errors[1], &failure, @sizeOf(c_int));
            c._exit(127);
        };
        _ = c.execvpe(argv[0].?, @ptrCast(argv.ptr), @ptrCast(environment.items.ptr));
        const failure = common.errno();
        _ = c.write(errors[1], &failure, @sizeOf(c_int));
        c._exit(127);
    }
    _ = c.close(errors[1]);
    var result: Pty = .{ .master = master, .pid = pid };
    errdefer result.deinit();
    var failure: c_int = 0;
    while (true) {
        const count = c.read(errors[0], &failure, @sizeOf(c_int));
        if (count < 0 and common.errno() == c.EINTR) continue;
        if (count < 0) return error.ExecStatusFailed;
        if (count > 0) {
            if (failure < 0) {
                std.debug.print("vertex: cannot enter working directory {s}: {s}\n", .{ options.working_directory orelse "", c.strerror(-failure) });
                return error.WorkingDirectoryFailed;
            }
            std.debug.print("vertex: cannot execute {s}: {s}\n", .{ arguments[0], c.strerror(failure) });
            return error.ShellExecFailed;
        }
        break;
    }
    if (c.fcntl(master, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0 or
        c.fcntl(master, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.FcntlFailed;
    return result;
}

pub fn resize(self: *Pty, rows: usize, columns: usize) !void {
    try self.resizePixels(rows, columns, 0, 0);
}
pub fn resizePixels(self: *Pty, rows: usize, columns: usize, width: usize, height: usize) !void {
    var size = windowSize(rows, columns);
    size.ws_xpixel = @intCast(@min(width, 65535));
    size.ws_ypixel = @intCast(@min(height, 65535));
    if (c.ioctl(self.master, c.TIOCSWINSZ, &size) < 0) return error.PtyResizeFailed;
}

pub fn read(self: *Pty, bytes: []u8) !usize {
    while (true) {
        const count = c.read(self.master, bytes.ptr, bytes.len);
        if (count >= 0) return @intCast(count);
        switch (common.errno()) {
            c.EINTR => continue,
            c.EAGAIN => return error.WouldBlock,
            c.EIO => return 0, // Linux reports the last slave closing as EIO.
            else => return error.PtyReadFailed,
        }
    }
}

pub fn write(self: *Pty, bytes: []const u8) !usize {
    while (true) {
        const count = c.write(self.master, bytes.ptr, bytes.len);
        if (count >= 0) return @intCast(count);
        switch (common.errno()) {
            c.EINTR => continue,
            c.EAGAIN => return error.WouldBlock,
            else => return error.PtyWriteFailed,
        }
    }
}

pub fn pollExit(self: *Pty) !?u8 {
    if (self.status) |status| return status;
    var status: c_int = 0;
    const result = c.waitpid(self.pid, &status, c.WNOHANG);
    if (result == 0 or (result < 0 and common.errno() == c.EINTR)) return null;
    if (result < 0) return error.WaitFailed;
    self.status = if (c.WIFEXITED(status)) @intCast(c.WEXITSTATUS(status)) else @intCast(128 + c.WTERMSIG(status));
    return self.status;
}

pub fn deinit(self: *Pty) void {
    if (self.status == null) {
        const foreground = c.tcgetpgrp(self.master);
        if (foreground > 0) _ = c.kill(-foreground, c.SIGHUP);
        _ = c.kill(-self.pid, c.SIGHUP);
    }
    _ = c.close(self.master);
    if (self.status == null) {
        const deadline = common.milliseconds() + 500;
        while (common.milliseconds() < deadline) {
            if ((self.pollExit() catch null) != null) break;
            _ = c.poll(null, 0, 10);
        }
        if (self.status == null) {
            _ = c.kill(-self.pid, c.SIGKILL);
            _ = c.kill(self.pid, c.SIGKILL);
            var status: c_int = 0;
            while (c.waitpid(self.pid, &status, 0) < 0 and common.errno() == c.EINTR) {}
        }
    }
    self.* = undefined;
}

fn windowSize(rows: usize, columns: usize) c.winsize {
    return .{ .ws_row = @intCast(@min(rows, 65535)), .ws_col = @intCast(@min(columns, 65535)), .ws_xpixel = 0, .ws_ypixel = 0 };
}
