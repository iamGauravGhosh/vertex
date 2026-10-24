//! A child session with a controlling terminal. No window-system dependencies.
const std = @import("std");
const c = @import("c");
const common = @import("common.zig");
const Pty = @This();

master: c_int,
pid: c.pid_t,
status: ?u8 = null,

pub fn spawn(allocator: std.mem.Allocator, command: []const []const u8, rows: usize, columns: usize) !Pty {
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
    var environment: std.ArrayList(?[*:0]const u8) = .empty;
    var index: usize = 0;
    while (c.environ[index] != null) : (index += 1) {
        const value = std.mem.span(c.environ[index]);
        if (std.mem.startsWith(u8, value, "TERM=") or std.mem.startsWith(u8, value, "COLORTERM=")) continue;
        try environment.append(scratch, c.environ[index]);
    }
    try environment.appendSlice(scratch, &.{ "TERM=xterm-256color", "COLORTERM=truecolor", null });
    var errors: [2]c_int = undefined;
    if (c.pipe2(&errors, c.O_CLOEXEC) != 0) return error.PipeFailed;
    defer _ = c.close(errors[0]);
    var size = windowSize(rows, columns);
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
    var size = windowSize(rows, columns);
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
