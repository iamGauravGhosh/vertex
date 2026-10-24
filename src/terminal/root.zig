//! Platform-independent VT parsing. Screen state and command execution belong
//! to the consumer. See docs/vt-parser.md for the syntax contract.
pub const Parser = @import("Parser.zig");
pub const Event = Parser.Event;
pub const Events = Parser.Events;
pub const Parameter = Parser.Parameter;
pub const Sequence = Parser.Sequence;
pub const StringEnd = Parser.StringEnd;
pub const OscEnd = Parser.OscEnd;
pub const Options = Parser.Options;

test {
    _ = @import("parser_tests.zig");
}
