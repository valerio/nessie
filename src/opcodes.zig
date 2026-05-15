const std = @import("std");
const testing = std.testing;

// zig fmt: off
pub const Mnemonic = enum(u6) {
    nop,
    lda, ldx, ldy,
    @"and", ora, eor,
    cmp, cpx, cpy,
    tax, txa, tay, tya,
    inx, dex,
    iny, dey,
    clc, sec,
    cli, sei,
    sta, stx, sty,
    kil,
};

pub const AddrMode = enum(u4) {
    implied,
    immediate,
    zeroPage,
    zeroPageX,
    zeroPageY,
    absolute,
    absoluteX,
    absoluteY,
    indirectX,
    indirectY,
};

/// A parsed NES opcode specification
pub const OpcodeSpec = struct {
    op: u8,
    mnemonic: Mnemonic,
    mode: AddrMode,
    bytes: u2,
    forceDummyRead: bool = false,
};

/// A packed representation of a NES opcode metadata.
/// Used during execution.
pub const Opcode = packed struct(u16) {
    mnemonic: Mnemonic = .kil,
    mode: AddrMode = .implied,
    bytes: u2 = 1,
    forceDummyRead: bool = false,
    reserved: u3 = 0,
};

pub fn buildTable(comptime specs: []const OpcodeSpec) [256]Opcode {
    var result = [_]Opcode{.{}} ** 256;

    for (specs) |spec| {
        result[spec.op] = Opcode{
            .mnemonic = spec.mnemonic,
            .mode = spec.mode,
            .bytes = spec.bytes,
            .forceDummyRead = spec.forceDummyRead,
        };
    }

    return result;
}

pub const table = buildTable(@import("opcodes.zon"));

test "builds opcode table" {
    const opcodes: []const OpcodeSpec = @import("opcodes.zon");
    const spec = opcodes[0];

    try testing.expectEqual(spec.mnemonic, table[spec.op].mnemonic);
    try testing.expectEqual(spec.mode, table[spec.op].mode);
    try testing.expectEqual(spec.bytes, table[spec.op].bytes);
    try testing.expectEqual(spec.forceDummyRead, table[spec.op].forceDummyRead);
}
