const std = @import("std");

const testing = std.testing;

// zig fmt: off
pub const Mnemonic = enum(u7) {
    lda, sta, ldx, stx, ldy, sty,            // access
    tax, txa, tay, tya,                      // transfer
    adc, sbc, inc, dec, inx, dex, iny, dey,  // arithmetic
    asl, lsr, rol, ror,                      // shift
    @"and", ora, eor, bit,                   // bitwise
    cmp, cpx, cpy,                           // compare
    bcc, bcs, beq, bne, bpl, bmi, bvc, bvs,  // branch
    jmp, jsr, rts, brk, rti,                 // jump
    pha, pla, php, plp, txs, tsx,            // stack
    clc, sec, cli, sei, cld, sed, clv,       // flags
    nop, kil,                                // other
    slo, rla, sre, rra, sax, lax,            // unofficial
    sha, shs, shy, shx, lae,                 // unofficial
    anc, asr, arr, ane, axs, dcp, isc,       // unofficial
};

pub const AddrMode = enum(u4) {
    implied,
    accumulator,
    immediate,
    relative,
    jsrAbsolute,
    zeroPage, zeroPageX, zeroPageY,
    absolute, absoluteX, absoluteY,
    indirect, indirectX, indirectY,
};
// zig fmt: on

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
    reserved: u2 = 0,
};

pub fn buildTable(comptime specs: []const OpcodeSpec) [256]Opcode {
    var result: [256]Opcode = @splat(.{});

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
