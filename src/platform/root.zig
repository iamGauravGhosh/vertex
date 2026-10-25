//! Linux GUI is optional; the parser and CLI never require a display.
pub const run = if (@import("build_options").gui)
    @import("linux.zig").run
else
    @import("disabled.zig").run;
const implementation = if (@import("build_options").gui) @import("linux.zig") else @import("disabled.zig");
pub const runWithOptions = implementation.runWithOptions;
pub const checkConfig = implementation.checkConfig;
