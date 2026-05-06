const std = @import("std");

/// Flags register
/// NV1B DIZC
pub const Flags = packed struct(u8) {
    /// Carry flag
    c: bool,
    /// Zero flag
    z: bool,
    /// Interrupt disable flag
    i: bool,
    /// Decimal mode flag, used in og 6502s for BCD ops, not used in NES cpus
    d: bool,
    /// Break flag, not an actual flag, used when pushing flags to stack
    b: bool,
    /// unused, always 1
    unused: bool = true,
    /// oVerflow flag
    v: bool,
    /// Negative flag, usually bit 7 of a result
    n: bool,

    pub fn fromByte(byte: u8) Flags {
        return @bitCast(byte | 0b0010_0000);
    }

    pub fn toByte(self: Flags) u8 {
        return @as(u8, @bitCast(self)) | 0b0010_0000;
    }
};

test "flags" {
    var f = Flags.fromByte(0x0F);
    try std.testing.expect(f.d);
    try std.testing.expect(f.i);
    try std.testing.expect(f.z);
    try std.testing.expect(f.c);
    try std.testing.expect(!f.v);
    try std.testing.expect(!f.n);
    try std.testing.expect(f.unused);

    f.unused = false; // ignored
    f.b = true;
    const byte = f.toByte();
    try std.testing.expectEqual(byte, 0x3F);
}

pub const Cpu = struct {
    a: u8,
    x: u8,
    y: u8,
    sp: u8,
    pc: u8,
    flags: Flags,
};
