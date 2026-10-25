//! Extended grapheme boundaries (UAX #29) and terminal cluster widths.
pub const data = @import("unicode_data.zig");
pub const version = data.version;
pub fn isEmojiPresentation(cp: u21) bool {
    return lookup(&data.emoji, cp) != 0;
}

fn lookup(ranges: []const data.Range, cp: u21) u8 {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.first) hi = mid else if (cp > r.last) lo = mid + 1 else return r.value;
    }
    return 0;
}
fn prop(cp: u21) data.Break {
    return @fromBackingInt(@intCast(lookup(&data.breaks, cp)));
}
fn control(p: data.Break) bool {
    return p == .Control or p == .CR or p == .LF;
}
pub fn joins(cluster: []const u21, cp: u21) bool {
    if (cluster.len == 0) return false;
    const a = prop(cluster[cluster.len - 1]);
    const b = prop(cp);
    if (a == .CR and b == .LF) return true;
    if (control(a) or control(b)) return false;
    if (a == .L and (b == .L or b == .V or b == .LV or b == .LVT)) return true;
    if ((a == .LV or a == .V) and (b == .V or b == .T)) return true;
    if ((a == .LVT or a == .T) and b == .T) return true;
    if (b == .Extend or b == .ZWJ or b == .SpacingMark or a == .Prepend) return true;
    if (lookup(&data.incb, cp) == 1) {
        var linker = false;
        var i = cluster.len;
        while (i > 0) {
            i -= 1;
            switch (lookup(&data.incb, cluster[i])) {
                3 => linker = true,
                2 => {},
                1 => {
                    if (linker) return true;
                    break;
                },
                else => break,
            }
        }
    }
    if (lookup(&data.pictographic, cp) != 0 and a == .ZWJ) {
        var i = cluster.len - 1;
        while (i > 0) {
            i -= 1;
            if (prop(cluster[i]) == .Extend) continue;
            if (lookup(&data.pictographic, cluster[i]) != 0) return true;
            break;
        }
    }
    if (a == .Regional_Indicator and b == .Regional_Indicator) {
        var count: usize = 0;
        var i = cluster.len;
        while (i > 0 and prop(cluster[i - 1]) == .Regional_Indicator) : (i -= 1) count += 1;
        return count % 2 == 1;
    }
    return false;
}
pub fn scalarWidth(cp: u21) u2 {
    const p = prop(cp);
    if (p == .Extend or p == .ZWJ or p == .Control or p == .Prepend) return 0;
    return if (lookup(&data.wide, cp) != 0 or lookup(&data.emoji, cp) != 0) 2 else 1;
}
pub fn width(cluster: []const u21) u2 {
    var result: u2 = 0;
    var text = false;
    for (cluster) |cp| {
        if (cp == 0xfe0e) text = true;
        if (cp == 0xfe0f or cp == 0x20e3) result = 2;
        result = @max(result, scalarWidth(cp));
    }
    if (text and cluster.len > 0 and lookup(&data.wide, cluster[0]) == 0) return 1;
    return @max(1, result);
}

/// Bidi controls have no terminal advance but remain in the logical text.
pub fn isFormat(cp: u21) bool {
    return cp == 0x061c or cp == 0x200b or cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2060 and cp <= 0x206f) or cp == 0xfeff;
}
