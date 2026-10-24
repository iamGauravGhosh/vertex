//! Platform-independent VT parsing and fixed-size terminal screen state.
//! See docs/vt-parser.md and docs/screen.md for the public contracts.
pub const Parser = @import("Parser.zig");
pub const Screen = @import("Screen.zig");
pub const Cell = Screen.Cell;
pub const Color = Screen.Color;
pub const Style = Screen.Style;
pub const Cursor = Screen.Cursor;
pub const Event = Parser.Event;
pub const Events = Parser.Events;
pub const Parameter = Parser.Parameter;
pub const Sequence = Parser.Sequence;
pub const StringEnd = Parser.StringEnd;
pub const OscEnd = Parser.OscEnd;
pub const Options = Parser.Options;

test {
    _ = @import("parser_tests.zig");
    _ = @import("screen_tests.zig");
}
