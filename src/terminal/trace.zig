//! Human-readable, ASCII-only event tracing; raw terminal controls never reach
//! the output. This is a debugging consumer, separate from the parser API.
const std = @import("std");
const terminal = @import("root.zig");
const Writer = std.Io.Writer;

pub fn writeEvent(writer: *Writer, event: terminal.Event) Writer.Error!void {
    switch (event) {
        .print => |codepoint| {
            try writer.print("PRINT U+{X:0>4} ", .{codepoint});
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
            try escaped(writer, bytes[0..len]);
        },
        .execute => |byte| try writer.print("EXECUTE 0x{X:0>2}", .{byte}),
        .esc => |command| {
            try writer.writeAll("ESC intermediates=");
            try escaped(writer, command.intermediates);
            try writer.writeAll(" final=");
            try escaped(writer, &.{command.final});
        },
        .csi => |command| {
            try writer.writeAll("CSI");
            try sequence(writer, command);
        },
        .osc => |command| {
            try writer.print("OSC terminator={s} data=", .{@tagName(command.terminator)});
            try escaped(writer, command.data);
        },
        .dcs_begin => |command| {
            try writer.writeAll("DCS_BEGIN");
            try sequence(writer, command);
        },
        .dcs_data => |byte| try writer.print("DCS_DATA 0x{X:0>2}", .{byte}),
        .dcs_end => |reason| try writer.print("DCS_END {s}", .{@tagName(reason)}),
        .osc_begin => try writer.writeAll("OSC_BEGIN"),
        .osc_data => |byte| try writer.print("OSC_DATA 0x{X:0>2}", .{byte}),
        .osc_end => |reason| try writer.print("OSC_END {s}", .{@tagName(reason)}),
        .apc_begin => try writer.writeAll("APC_BEGIN"),
        .apc_data => |byte| try writer.print("APC_DATA 0x{X:0>2}", .{byte}),
        .apc_end => |reason| try writer.print("APC_END {s}", .{@tagName(reason)}),
    }
    try writer.writeByte('\n');
}

fn sequence(writer: *Writer, command: terminal.Sequence) Writer.Error!void {
    try writer.writeAll(" prefix=");
    if (command.private_prefix) |prefix| {
        try escaped(writer, &.{prefix});
    } else {
        try escaped(writer, "");
    }
    // Brackets distinguish no parameters ([]) from one omitted parameter ([_]).
    try writer.writeAll(" params=[");
    for (command.parameters) |param| {
        switch (param.separator) {
            .none => {},
            .semicolon => try writer.writeByte(';'),
            .colon => try writer.writeByte(':'),
        }
        if (param.value) |value| {
            try writer.print("{d}", .{value});
        } else {
            try writer.writeByte('_');
        }
    }
    try writer.writeAll("] intermediates=");
    try escaped(writer, command.intermediates);
    try writer.writeAll(" final=");
    try escaped(writer, &.{command.final});
}

fn escaped(writer: *Writer, bytes: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (bytes) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
            else => try writer.print("\\x{X:0>2}", .{byte}),
        }
    }
    try writer.writeByte('"');
}
