//! Shared defaults for rendering and terminal color queries.
pub const foreground: u32 = 0xd8dee9;
pub const background: u32 = 0x15171a;
pub const palette = [_]u32{
    0x2e3440, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
    0x4c566a, 0xd08770, 0xb5d99c, 0xffdf9e, 0x81a1c1, 0xc6a0c9, 0x9dd9e5, 0xffffff,
};

pub fn indexed(index: u8) u32 {
    if (index < 16) return palette[index];
    if (index >= 232) {
        const level: u32 = 8 + @as(u32, index - 232) * 10;
        return level * 0x010101;
    }
    const n: u32 = index - 16;
    return (cube(n / 36) << 16) | (cube(n / 6 % 6) << 8) | cube(n % 6);
}
fn cube(value: u32) u32 {
    return if (value == 0) 0 else 55 + value * 40;
}
