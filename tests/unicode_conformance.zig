const std = @import("std");
const vt = @import("vertex_terminal");

test "Unicode 18.0 extended grapheme conformance" {
    var lines = std.mem.splitScalar(u8, @embedFile("unicode/GraphemeBreakTest.txt"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        const content = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        var tokens = std.mem.tokenizeAny(u8, content, " \t\r");
        var cluster: std.ArrayList(u21) = .empty;
        defer cluster.deinit(std.testing.allocator);
        var boundary = true;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                boundary = true;
                continue;
            }
            if (std.mem.eql(u8, token, "×")) {
                boundary = false;
                continue;
            }
            const cp = try std.fmt.parseInt(u21, token, 16);
            const joined = vt.Unicode.joins(cluster.items, cp);
            if (joined == boundary) {
                std.debug.print("grapheme failure: {s}\n", .{line});
                return error.GraphemeConformance;
            }
            if (boundary) cluster.clearRetainingCapacity();
            try cluster.append(std.testing.allocator, cp);
            count += 1;
        }
    }
    try std.testing.expect(count > 1000);
}
