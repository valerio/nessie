const std = @import("std");
const opcodes = @import("opcodes.zig");
const addressing = @import("addressing.zig");
const nes = @import("system.zig");

const testing = std.testing;
const System = nes.System;

/// Flags register
/// NV1B DIZC
pub const Flags = packed struct(u8) {
    /// Carry flag
    c: bool = false,
    /// Zero flag
    z: bool = false,
    /// Interrupt disable flag
    i: bool = false,
    /// Decimal mode flag, used in og 6502s for BCD ops, not used in NES cpus
    d: bool = false,
    /// Break flag, not an actual flag, used when pushing flags to stack
    b: bool = false,
    /// unused, always 1
    unused: bool = true,
    /// oVerflow flag
    v: bool = false,
    /// Negative flag, usually bit 7 of a result
    n: bool = false,

    pub fn fromByte(byte: u8) Flags {
        return @bitCast(byte | 0b0010_0000);
    }

    pub fn toByte(self: Flags) u8 {
        return @as(u8, @bitCast(self)) | 0b0010_0000;
    }
};

const StatusFlag = enum { n, v, b, d, i, z, c };
const AluOp = enum { @"and", ora, eor };

test "flags" {
    var f = Flags.fromByte(0x0F);
    try testing.expect(f.d);
    try testing.expect(f.i);
    try testing.expect(!f.v);
    try testing.expect(!f.n);
    try testing.expect(f.unused);

    f.unused = false; // ignored
    f.b = true;
    const byte = f.toByte();
    try testing.expectEqual(byte, 0x3F);
}

pub fn exec(s: *System) void {
    const op = opcodes.table[s.cycleRead(s.cpu.pc)];
    s.cpu.pc +%= 1;

    // addressing
    // TODO: could optional addressing be done without the unwrapping (.?) below?
    const addr: ?u16 = switch (op.mode) {
        .implied => null,
        .immediate => addressing.immediate(s),
        .zeroPage => addressing.zeroPage(s, null),
        .zeroPageX => addressing.zeroPage(s, .x),
        .zeroPageY => addressing.zeroPage(s, .y),
        .absolute => addressing.absolute(s, null, op.forceDummyRead),
        .absoluteX => addressing.absolute(s, .x, op.forceDummyRead),
        .absoluteY => addressing.absolute(s, .y, op.forceDummyRead),
        .indirect => addressing.indirect(s),
        .indirectX => addressing.indirectIndexed(s, .x, op.forceDummyRead),
        .indirectY => addressing.indirectIndexed(s, .y, op.forceDummyRead),
        .relative => addressing.relative(s),
    };

    // execution
    switch (op.mnemonic) {
        .nop => _ = s.cycleRead(s.cpu.pc),
        .lda => s.cpu.setRegNZ(.a, s.cycleRead(addr.?)),
        .ldx => s.cpu.setRegNZ(.x, s.cycleRead(addr.?)),
        .ldy => s.cpu.setRegNZ(.y, s.cycleRead(addr.?)),
        .sta => s.cycleWrite(addr.?, s.cpu.a),
        .stx => s.cycleWrite(addr.?, s.cpu.x),
        .sty => s.cycleWrite(addr.?, s.cpu.y),
        .@"and" => s.cpu.setRegNZ(.a, s.cpu.aluA(.@"and", s.cycleRead(addr.?))),
        .ora => s.cpu.setRegNZ(.a, s.cpu.aluA(.ora, s.cycleRead(addr.?))),
        .eor => s.cpu.setRegNZ(.a, s.cpu.aluA(.eor, s.cycleRead(addr.?))),
        .adc => adc(s, addr.?),
        .sbc => sbc(s, addr.?),
        .bit => bit(s, addr.?),
        .cmp => s.cpu.compare(s.cpu.a, s.cycleRead(addr.?)),
        .cpx => s.cpu.compare(s.cpu.x, s.cycleRead(addr.?)),
        .cpy => s.cpu.compare(s.cpu.y, s.cycleRead(addr.?)),
        .jmp => s.cpu.pc = addr.?,
        .bcc => branch(s, addr.?, .c, false),
        .bcs => branch(s, addr.?, .c, true),
        .beq => branch(s, addr.?, .z, true),
        .bne => branch(s, addr.?, .z, false),
        .bpl => branch(s, addr.?, .n, false),
        .bmi => branch(s, addr.?, .n, true),
        .bvc => branch(s, addr.?, .v, false),
        .bvs => branch(s, addr.?, .v, true),
        .tax => transfer(s, .a, .x),
        .txa => transfer(s, .x, .a),
        .tay => transfer(s, .a, .y),
        .tya => transfer(s, .y, .a),
        .tsx => transfer(s, .sp, .x),
        .txs => transfer(s, .x, .sp),
        .inx => increment(s, .x),
        .dex => decrement(s, .x),
        .iny => increment(s, .y),
        .dey => decrement(s, .y),
        .clc => setFlag(s, .c, false),
        .sec => setFlag(s, .c, true),
        .cli => setFlag(s, .i, false),
        .sei => setFlag(s, .i, true),
        .cld => setFlag(s, .d, false),
        .sed => setFlag(s, .d, true),
        .clv => setFlag(s, .v, false),
        .pha => push(s, s.cpu.a),
        .php => push(s, s.cpu.flags.toByte() | 0x10),
        .pla => pullReg(s, .a),
        .plp => pullFlags(s),
        else => @panic("boom"),
    }
}

// Instructions
// TODO: move somewhere else.

fn overflowBit(acc: u8, operand: u8, sum: u8) bool {
    return (~(acc ^ operand) & (acc ^ sum) & 0x80) != 0;
}

fn adc(s: *System, addr: u16) void {
    const value = s.cycleRead(addr);
    const a = s.cpu.a;
    const carry: u16 = if (s.cpu.flags.c) 1 else 0;
    const sum: u16 = @as(u16, a) +% value +% @as(u16, carry);

    s.cpu.flags.c = sum > 0xff;
    s.cpu.flags.v = overflowBit(a, value, @truncate(sum));
    s.cpu.a = @truncate(sum);
    s.cpu.setNZ(s.cpu.a);
}

fn sbc(s: *System, addr: u16) void {
    const value = s.cycleRead(addr) ^ 0xff;
    const a = s.cpu.a;
    const carry: u16 = if (s.cpu.flags.c) 1 else 0;
    const sum: u16 = @as(u16, a) +% value +% @as(u16, carry);

    s.cpu.flags.c = sum > 0xff;
    s.cpu.flags.v = overflowBit(a, value, @truncate(sum));
    s.cpu.a = @truncate(sum);
    s.cpu.setNZ(s.cpu.a);
}

fn bit(s: *System, addr: u16) void {
    const value = s.cycleRead(addr);
    s.cpu.flags.z = s.cpu.a & value == 0;
    s.cpu.flags.n = (value >> 7) > 0;
    s.cpu.flags.v = (value >> 6) > 0;
}

fn branch(s: *System, addr: u16, flag: StatusFlag, set: bool) void {
    if (s.cpu.getStatusFlag(flag) != set) return;

    const base = s.cpu.pc;
    _ = s.cycleRead(base);
    if ((base & 0xff00) != (addr & 0xff00)) {
        _ = s.cycleRead((base & 0xff00) | (addr & 0x00ff));
    }
    s.cpu.pc = addr;
}

fn transfer(s: *System, src: Register8, dst: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cpu.setReg(dst, s.cpu.readReg(src));
    if (dst != .sp) s.cpu.setNZ(s.cpu.readReg(src));
}

fn increment(s: *System, reg: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cpu.setRegNZ(reg, s.cpu.readReg(reg) +% 1);
}

fn decrement(s: *System, reg: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cpu.setRegNZ(reg, s.cpu.readReg(reg) -% 1);
}

fn setFlag(s: *System, flag: StatusFlag, value: bool) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cpu.setStatusFlag(flag, value);
}

fn push(s: *System, value: u8) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cycleWrite(s.cpu.stackAddr(), value);
    s.cpu.sp -%= 1;
}

fn pullReg(s: *System, reg: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(s.cpu.stackAddr());
    s.cpu.sp +%= 1;
    s.cpu.setRegNZ(reg, s.cycleRead(s.cpu.stackAddr()));
}

fn pullFlags(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(s.cpu.stackAddr());
    s.cpu.sp +%= 1;
    s.cpu.flags = Flags.fromByte(s.cycleRead(s.cpu.stackAddr()));
}

pub const Register8 = enum { a, x, y, sp };

pub const Cpu = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xFD,
    pc: u16 = 0,
    flags: Flags = Flags{ .i = true },

    pub fn readReg(self: *const Cpu, reg: Register8) u8 {
        return switch (reg) {
            .a => self.a,
            .x => self.x,
            .y => self.y,
            .sp => self.sp,
        };
    }

    pub fn setReg(self: *Cpu, reg: Register8, value: u8) void {
        switch (reg) {
            .a => self.a = value,
            .x => self.x = value,
            .y => self.y = value,
            .sp => self.sp = value,
        }
    }

    pub fn setNZ(self: *Cpu, value: u8) void {
        self.flags.z = value == 0;
        self.flags.n = (value & 0x80) != 0;
    }

    pub fn setRegNZ(self: *Cpu, reg: Register8, value: u8) void {
        self.setReg(reg, value);
        self.setNZ(value);
    }

    pub fn stackAddr(self: *const Cpu) u16 {
        return 0x0100 | @as(u16, self.sp);
    }

    // TODO: probably refactor/simplify this.
    pub fn setStatusFlag(self: *Cpu, flag: StatusFlag, value: bool) void {
        switch (flag) {
            .c => self.flags.c = value,
            .i => self.flags.i = value,
            .d => self.flags.d = value,
            .b => self.flags.b = value,
            .z => self.flags.z = value,
            .n => self.flags.n = value,
            .v => self.flags.v = value,
        }
    }

    pub fn getStatusFlag(self: *Cpu, flag: StatusFlag) bool {
        return switch (flag) {
            .c => self.flags.c,
            .i => self.flags.i,
            .d => self.flags.d,
            .b => self.flags.b,
            .z => self.flags.z,
            .n => self.flags.n,
            .v => self.flags.v,
        };
    }

    pub fn aluA(self: *Cpu, op: AluOp, value: u8) u8 {
        return switch (op) {
            .@"and" => self.a & value,
            .ora => self.a | value,
            .eor => self.a ^ value,
        };
    }

    pub fn compare(self: *Cpu, reg: u8, value: u8) void {
        self.flags.z = reg == value;
        self.flags.c = reg >= value;
        self.flags.n = ((reg -% value) & 0x80) != 0;
    }
};

test "cpu init" {
    const cpu = Cpu{};
    try testing.expectEqual(0x24, cpu.flags.toByte());
    try testing.expectEqual(0xFD, cpu.sp);
}
