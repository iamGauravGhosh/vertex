//! Vertex's incremental parser for UTF-8 and seven-bit control sequences.
//! Syntax and recovery are specified in docs/vt-parser.md. No allocator or I/O
//! is used here. Slice payloads are valid only until the next parser operation.
const std = @import("std");
const Parser = @This();

pub const max_parameters = 32;
pub const max_intermediates = 4;
pub const max_osc_bytes = 4096;

pub const Options = struct {
    osc_mode: enum { buffered, streaming } = .buffered,
    apc_mode: enum { ignored, streaming } = .ignored,
};
pub const Parameter = struct {
    value: ?u16 = null,
    separator: enum { none, semicolon, colon } = .none,
};
pub const Sequence = struct {
    private_prefix: ?u8,
    parameters: []const Parameter,
    intermediates: []const u8,
    final: u8,
};
pub const StringEnd = enum { st, cancelled, interrupted, end_of_input };
pub const OscEnd = enum { bel, st, cancelled, interrupted, end_of_input };
pub const Event = union(enum) {
    print: u21,
    execute: u8,
    esc: struct { intermediates: []const u8, final: u8 },
    csi: Sequence,
    osc: struct { data: []const u8, terminator: enum { bel, st } },
    dcs_begin: Sequence,
    dcs_data: u8,
    dcs_end: StringEnd,
    osc_begin: void,
    osc_data: u8,
    osc_end: OscEnd,
    apc_begin: void,
    apc_data: u8,
    apc_end: StringEnd,
};
/// Ordered events occupy the first slots; remaining slots are null.
pub const Events = [3]?Event;

const Output = struct {
    items: Events = @splat(null),
    count: usize = 0,

    fn append(self: *Output, event: Event) void {
        std.debug.assert(self.count < self.items.len);
        self.items[self.count] = event;
        self.count += 1;
    }
};
const Phase = enum { text, escape, header, payload };
const HeaderKind = enum { csi, dcs };
const HeaderPart = enum { start, values, intermediates };
const PayloadKind = enum { osc, dcs, apc, ignored };

options: Options = .{},
phase: Phase = .text,
header_kind: HeaderKind = .csi,
header_part: HeaderPart = .start,
header_invalid: bool = false,
prefix: ?u8 = null,
params: [max_parameters]Parameter = undefined,
param_count: usize = 0,
intermediate_bytes: [max_intermediates]u8 = undefined,
intermediate_count: usize = 0,
payload_kind: PayloadKind = .ignored,
escape_pending: bool = false,
osc_bytes: [max_osc_bytes]u8 = undefined,
osc_count: usize = 0,
osc_discard: bool = false,
scalar: u21 = 0,
continuations: u3 = 0,
continuation_min: u8 = 0x80,
continuation_max: u8 = 0xbf,

pub fn init() Parser {
    return initWithOptions(.{});
}

pub fn initWithOptions(options: Options) Parser {
    return .{ .options = options };
}

/// Abandon pending input without events; retain configuration.
pub fn reset(self: *Parser) void {
    self.* = initWithOptions(self.options);
}

/// The handler must consume/copy borrowed payloads before returning, and must
/// not reenter this parser. Use next() for a consumer that can return errors.
pub fn feed(self: *Parser, bytes: []const u8, handler: anytype) void {
    for (bytes) |byte| {
        for (self.next(byte)) |item| {
            if (item) |event| handler.handle(event);
        }
    }
}

pub fn next(self: *Parser, byte: u8) Events {
    var output: Output = .{};
    self.consume(byte, &output);
    return output.items;
}

/// Finalize a stream, reporting incomplete UTF-8 and open streamed strings.
/// Incomplete buffered commands are discarded. Configuration is retained.
pub fn finish(self: *Parser) Events {
    var output: Output = .{};
    if (self.continuations != 0) output.append(.{ .print = 0xfffd });
    if (self.phase == .payload) self.endPayload(.end_of_input, &output);
    self.reset();
    return output.items;
}

fn consume(self: *Parser, byte: u8, output: *Output) void {
    if (self.phase == .text) {
        self.text(byte, output);
        return;
    }
    if (byte == 0x18 or byte == 0x1a) {
        if (self.phase == .payload) self.endPayload(.cancelled, output);
        self.phase = .text;
        output.append(.{ .execute = byte });
        return;
    }
    if (self.phase == .payload) {
        if (self.escape_pending) {
            self.escape_pending = false;
            if (byte == '\\') {
                self.endPayload(.st, output);
                return;
            }
            self.endPayload(.interrupted, output);
            self.openEscape();
            // The byte after an interrupted string belongs to the new ESC.
        } else {
            if (byte == 0x1b) {
                self.escape_pending = true;
            } else if (self.payload_kind == .osc and byte == 7) {
                self.endPayload(.bel, output);
            } else {
                self.payloadByte(byte, output);
            }
            return;
        }
    }
    if (byte == 0x1b) {
        self.openEscape();
        return;
    }
    if (byte < 0x20) {
        if (self.phase == .escape or self.header_kind == .csi)
            output.append(.{ .execute = byte });
        return;
    }
    if (byte >= 0x7f) return;
    switch (self.phase) {
        .escape => self.escapeByte(byte, output),
        .header => self.headerByte(byte, output),
        else => unreachable,
    }
}

fn text(self: *Parser, byte: u8, output: *Output) void {
    if (self.continuations != 0) {
        if (byte >= self.continuation_min and byte <= self.continuation_max) {
            self.scalar = (self.scalar << 6) | @as(u21, byte & 0x3f);
            self.continuations -= 1;
            self.continuation_min = 0x80;
            self.continuation_max = 0xbf;
            if (self.continuations == 0) output.append(.{ .print = self.scalar });
            return;
        }
        self.continuations = 0;
        output.append(.{ .print = 0xfffd });
    }
    if (byte == 0x1b) {
        self.openEscape();
    } else if (byte < 0x20) {
        output.append(.{ .execute = byte });
    } else if (byte < 0x7f) {
        output.append(.{ .print = byte });
    } else if (byte == 0x7f) {
        return;
    } else if (byte >= 0xc2 and byte <= 0xf4) {
        self.continuation_min = if (byte == 0xe0) 0xa0 else if (byte == 0xf0) 0x90 else 0x80;
        self.continuation_max = if (byte == 0xed) 0x9f else if (byte == 0xf4) 0x8f else 0xbf;
        if (byte < 0xe0) {
            self.scalar = byte & 0x1f;
            self.continuations = 1;
        } else if (byte < 0xf0) {
            self.scalar = byte & 0x0f;
            self.continuations = 2;
        } else {
            self.scalar = byte & 7;
            self.continuations = 3;
        }
    } else {
        output.append(.{ .print = 0xfffd });
    }
}

fn openEscape(self: *Parser) void {
    self.phase = .escape;
    self.header_part = .start;
    self.header_invalid = false;
    self.prefix = null;
    self.param_count = 0;
    self.intermediate_count = 0;
}

fn addIntermediate(self: *Parser, byte: u8) void {
    if (self.intermediate_count == max_intermediates) {
        self.rejectHeader();
        return;
    }
    self.intermediate_bytes[self.intermediate_count] = byte;
    self.intermediate_count += 1;
}

fn rejectHeader(self: *Parser) void {
    self.header_invalid = true;
    // A malformed DCS is a discarded string even if no final byte arrives.
    if (self.phase == .header and self.header_kind == .dcs) self.openPayload(.ignored);
}

fn escapeByte(self: *Parser, byte: u8, output: *Output) void {
    if (byte < 0x30) {
        self.addIntermediate(byte);
        return;
    }
    if (self.intermediate_count == 0 and !self.header_invalid) {
        switch (byte) {
            '[', 'P' => {
                self.header_kind = if (byte == '[') .csi else .dcs;
                self.phase = .header;
                return;
            },
            ']' => {
                self.openPayload(.osc);
                if (self.options.osc_mode == .streaming) output.append(.osc_begin);
                return;
            },
            '_' => {
                self.openPayload(if (self.options.apc_mode == .streaming) .apc else .ignored);
                if (self.options.apc_mode == .streaming) output.append(.apc_begin);
                return;
            },
            'X', '^' => {
                self.openPayload(.ignored);
                return;
            },
            else => {},
        }
    }
    if (!self.header_invalid) output.append(.{ .esc = .{
        .intermediates = self.intermediate_bytes[0..self.intermediate_count],
        .final = byte,
    } });
    self.phase = .text;
}

fn headerByte(self: *Parser, byte: u8, output: *Output) void {
    if (byte >= 0x40) {
        if (!self.header_invalid) {
            const command: Sequence = .{
                .private_prefix = self.prefix,
                .parameters = self.params[0..self.param_count],
                .intermediates = self.intermediate_bytes[0..self.intermediate_count],
                .final = byte,
            };
            output.append(if (self.header_kind == .csi) .{ .csi = command } else .{ .dcs_begin = command });
        }
        if (self.header_kind == .dcs) {
            self.openPayload(if (self.header_invalid) .ignored else .dcs);
        } else self.phase = .text;
        return;
    }
    if (self.header_invalid) return;
    if (byte < 0x30) {
        self.header_part = .intermediates;
        self.addIntermediate(byte);
        return;
    }
    if (self.header_part == .intermediates) {
        self.rejectHeader();
        return;
    }
    if (byte >= 0x3c) {
        if (self.header_part != .start) {
            self.rejectHeader();
        } else {
            self.prefix = byte;
            self.header_part = .values;
        }
        return;
    }
    self.header_part = .values;
    if (self.param_count == 0) {
        self.params[0] = .{};
        self.param_count = 1;
    }
    if (byte == ':' or byte == ';') {
        if (self.param_count == max_parameters) {
            self.rejectHeader();
            return;
        }
        self.params[self.param_count] = .{ .separator = if (byte == ':') .colon else .semicolon };
        self.param_count += 1;
    } else {
        const slot = &self.params[self.param_count - 1].value;
        slot.* = (slot.* orelse 0) *| 10 +| @as(u16, byte - '0');
    }
}

fn openPayload(self: *Parser, kind: PayloadKind) void {
    self.phase = .payload;
    self.payload_kind = kind;
    self.escape_pending = false;
    self.osc_count = 0;
    self.osc_discard = false;
}

fn payloadByte(self: *Parser, byte: u8, output: *Output) void {
    switch (self.payload_kind) {
        .ignored => {},
        .apc => output.append(.{ .apc_data = byte }),
        .dcs => if (byte != 0x7f) {
            output.append(.{ .dcs_data = byte });
        },
        .osc => {
            if (byte < 0x20) return;
            if (self.options.osc_mode == .streaming) {
                output.append(.{ .osc_data = byte });
            } else if (!self.osc_discard) {
                if (self.osc_count == max_osc_bytes) {
                    self.osc_discard = true;
                } else {
                    self.osc_bytes[self.osc_count] = byte;
                    self.osc_count += 1;
                }
            }
        },
    }
}

fn endPayload(self: *Parser, reason: OscEnd, output: *Output) void {
    switch (self.payload_kind) {
        .ignored => {},
        .apc => output.append(.{ .apc_end = nonOscEnd(reason) }),
        .dcs => output.append(.{ .dcs_end = nonOscEnd(reason) }),
        .osc => {
            if (self.options.osc_mode == .streaming) {
                output.append(.{ .osc_end = reason });
            } else if (!self.osc_discard and (reason == .bel or reason == .st)) {
                output.append(.{ .osc = .{
                    .data = self.osc_bytes[0..self.osc_count],
                    .terminator = if (reason == .bel) .bel else .st,
                } });
            }
        },
    }
    self.phase = .text;
    self.escape_pending = false;
}

fn nonOscEnd(reason: OscEnd) StringEnd {
    return switch (reason) {
        .st => .st,
        .cancelled => .cancelled,
        .interrupted => .interrupted,
        .end_of_input => .end_of_input,
        .bel => unreachable,
    };
}
