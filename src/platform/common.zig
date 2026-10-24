const c = @import("c");

pub fn errno() c_int {
    return c.__errno_location().*;
}

pub fn milliseconds() i64 {
    var time: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &time);
    return time.tv_sec * 1000 + @divTrunc(time.tv_nsec, 1_000_000);
}
