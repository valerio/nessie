const std = @import("std");
const opcodes = @import("opcodes.zig");
const addressing = @import("addressing.zig");

const testing = std.testing;

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

pub fn exec(c: *Cpu, ctx: anytype) void {
    const opcode = opcodes.table[ctx.read(c.pc)];
    c.pc +%= 1;

    // addressing
    // TODO: could optional addressing be done without the unwrapping (.?) below?
    const addr: ?u16 = switch (opcode.mode) {
        .implied => null,
        .immediate => addressing.immediate(c),
        .zeroPage => addressing.zeroPage(c, ctx, null),
        .zeroPageX => addressing.zeroPage(c, ctx, .x),
        .zeroPageY => addressing.zeroPage(c, ctx, .y),
        .absolute => addressing.absolute(c, ctx, null, opcode.forceDummyRead),
        .absoluteX => addressing.absolute(c, ctx, .x, opcode.forceDummyRead),
        .absoluteY => addressing.absolute(c, ctx, .y, opcode.forceDummyRead),
        .indirect => addressing.indirect(c, ctx),
        .indirectX => addressing.indirectIndexed(c, ctx, .x, opcode.forceDummyRead),
        .indirectY => addressing.indirectIndexed(c, ctx, .y, opcode.forceDummyRead),
        .relative => addressing.relative(c, ctx),
    };

    // execution
    switch (opcode.mnemonic) {
        .nop => _ = ctx.read(c.pc),
        .lda => c.setRegNZ(.a, ctx.read(addr.?)),
        .ldx => c.setRegNZ(.x, ctx.read(addr.?)),
        .ldy => c.setRegNZ(.y, ctx.read(addr.?)),
        .sta => ctx.write(addr.?, c.a),
        .stx => ctx.write(addr.?, c.x),
        .sty => ctx.write(addr.?, c.y),
        .@"and" => c.setRegNZ(.a, c.aluA(.@"and", ctx.read(addr.?))),
        .ora => c.setRegNZ(.a, c.aluA(.ora, ctx.read(addr.?))),
        .eor => c.setRegNZ(.a, c.aluA(.eor, ctx.read(addr.?))),
        .adc => adc(c, ctx, addr.?),
        .sbc => sbc(c, ctx, addr.?),
        .bit => bit(c, ctx, addr.?),
        .cmp => c.compare(c.a, ctx.read(addr.?)),
        .cpx => c.compare(c.x, ctx.read(addr.?)),
        .cpy => c.compare(c.y, ctx.read(addr.?)),
        .jmp => c.pc = addr.?,
        .bcc => branch(c, ctx, addr.?, .c, false),
        .bcs => branch(c, ctx, addr.?, .c, true),
        .beq => branch(c, ctx, addr.?, .z, true),
        .bne => branch(c, ctx, addr.?, .z, false),
        .bpl => branch(c, ctx, addr.?, .n, false),
        .bmi => branch(c, ctx, addr.?, .n, true),
        .bvc => branch(c, ctx, addr.?, .v, false),
        .bvs => branch(c, ctx, addr.?, .v, true),
        .tax => transfer(c, ctx, .a, .x),
        .txa => transfer(c, ctx, .x, .a),
        .tay => transfer(c, ctx, .a, .y),
        .tya => transfer(c, ctx, .y, .a),
        .tsx => transfer(c, ctx, .sp, .x),
        .txs => transfer(c, ctx, .x, .sp),
        .inx => increment(c, ctx, .x),
        .dex => decrement(c, ctx, .x),
        .iny => increment(c, ctx, .y),
        .dey => decrement(c, ctx, .y),
        .clc => setFlag(c, ctx, .c, false),
        .sec => setFlag(c, ctx, .c, true),
        .cli => setFlag(c, ctx, .i, false),
        .sei => setFlag(c, ctx, .i, true),
        .cld => setFlag(c, ctx, .d, false),
        .sed => setFlag(c, ctx, .d, true),
        .clv => setFlag(c, ctx, .v, false),
        .pha => push(c, ctx, c.a),
        .php => push(c, ctx, c.flags.toByte() | 0x10),
        .pla => pullReg(c, ctx, .a),
        .plp => pullFlags(c, ctx),
        else => @panic("boom"),
    }

    ctx.afterInstruction();
}

// Instructions
// TODO: move somewhere else.

fn overflowBit(acc: u8, operand: u8, sum: u8) bool {
    return (~(acc ^ operand) & (acc ^ sum) & 0x80) != 0;
}

fn adc(c: *Cpu, ctx: anytype, addr: u16) void {
    const value = ctx.read(addr);
    const a = c.a;
    const carry: u16 = if (c.flags.c) 1 else 0;
    const sum: u16 = @as(u16, a) +% value +% @as(u16, carry);

    c.flags.c = sum > 0xff;
    c.flags.v = overflowBit(a, value, @truncate(sum));
    c.a = @truncate(sum);
    c.setNZ(c.a);
}

fn sbc(c: *Cpu, ctx: anytype, addr: u16) void {
    const value = ctx.read(addr) ^ 0xff;
    const a = c.a;
    const carry: u16 = if (c.flags.c) 1 else 0;
    const sum: u16 = @as(u16, a) +% value +% @as(u16, carry);

    c.flags.c = sum > 0xff;
    c.flags.v = overflowBit(a, value, @truncate(sum));
    c.a = @truncate(sum);
    c.setNZ(c.a);
}

fn bit(c: *Cpu, ctx: anytype, addr: u16) void {
    const value = ctx.read(addr);
    c.flags.z = c.a & value == 0;
    c.flags.n = (value >> 7) > 0;
    c.flags.v = (value >> 6) > 0;
}

fn branch(c: *Cpu, ctx: anytype, addr: u16, flag: StatusFlag, set: bool) void {
    if (c.getStatusFlag(flag) != set) return;

    const base = c.pc;
    _ = ctx.read(base);
    if ((base & 0xff00) != (addr & 0xff00)) {
        _ = ctx.read((base & 0xff00) | (addr & 0x00ff));
    }
    c.pc = addr;
}

fn transfer(c: *Cpu, ctx: anytype, src: Register8, dst: Register8) void {
    _ = ctx.read(c.pc);
    c.setReg(dst, c.readReg(src));
    if (dst != .sp) c.setNZ(c.readReg(src));
}

fn increment(c: *Cpu, ctx: anytype, reg: Register8) void {
    _ = ctx.read(c.pc);
    c.setRegNZ(reg, c.readReg(reg) +% 1);
}

fn decrement(c: *Cpu, ctx: anytype, reg: Register8) void {
    _ = ctx.read(c.pc);
    c.setRegNZ(reg, c.readReg(reg) -% 1);
}

fn setFlag(c: *Cpu, ctx: anytype, flag: StatusFlag, value: bool) void {
    _ = ctx.read(c.pc);
    c.setStatusFlag(flag, value);
}

fn push(c: *Cpu, ctx: anytype, value: u8) void {
    _ = ctx.read(c.pc);
    ctx.write(c.stackAddr(), value);
    c.sp -%= 1;
}

fn pullReg(c: *Cpu, ctx: anytype, reg: Register8) void {
    _ = ctx.read(c.pc);
    _ = ctx.read(c.stackAddr());
    c.sp +%= 1;
    c.setRegNZ(reg, ctx.read(c.stackAddr()));
}

fn pullFlags(c: *Cpu, ctx: anytype) void {
    _ = ctx.read(c.pc);
    _ = ctx.read(c.stackAddr());
    c.sp +%= 1;
    c.flags = Flags.fromByte(ctx.read(c.stackAddr()));
}

pub const Register8 = enum { a, x, y, sp };

pub const Cpu = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xFD,
    pc: u16 = 0,
    flags: Flags = Flags{ .i = true },

    pub fn init() Cpu {
        return .{};
    }

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
    const cpu = Cpu.init();
    try testing.expectEqual(0x24, cpu.flags.toByte());
    try testing.expectEqual(0xFD, cpu.sp);
}
