//! Platform-independent VT parsing and resizable terminal screen state.
//! See docs/vt-parser.md and docs/screen.md for the public contracts.
pub const Parser = @import("Parser.zig");
pub const Session = @import("Session.zig");
pub const Input = @import("Input.zig");
pub const Unicode = @import("Unicode.zig");
pub const Screen = @import("Screen.zig");
pub const Links = @import("Links.zig");
pub const Graphics = @import("Graphics.zig");
pub const Cell = Screen.Cell;
pub const Color = Screen.Color;
pub const Style = Screen.Style;
pub const Cursor = Screen.Cursor;
pub const Theme = @import("Colors.zig").Theme;
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
    _ = @import("input_tests.zig");
    _ = @import("multiplexer_tests.zig");
    _ = @import("graphics_tests.zig");
}
