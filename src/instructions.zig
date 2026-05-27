const cpu = @import("cpu.zig");
const opcodes = @import("opcodes.zig");
const nes = @import("system.zig");
const addressing = @import("addressing.zig");

const System = nes.System;
const Register8 = cpu.Register8;

const Interrupt = enum { irq, nmi, brk };
const ShiftOp = enum { asl, lsr, rol, ror };

fn stackPush(s: *System, value: u8) void {
    s.cycleWrite(0x0100 | @as(u16, s.cpu.sp), value);
    s.cpu.sp -%= 1;
}

fn stackPop(s: *System) u8 {
    s.cpu.sp +%= 1;
    return s.cycleRead(0x0100 | @as(u16, s.cpu.sp));
}

pub fn exec(s: *System, op: opcodes.Opcode) void {
    const addr = addressing.resolveAddr(s, op);

    switch (op.mnemonic) {
        .nop => nop(s),
        .lda => ld(s, .a, addr),
        .ldx => ld(s, .x, addr),
        .ldy => ld(s, .y, addr),
        .sta => st(s, .a, addr),
        .stx => st(s, .x, addr),
        .sty => st(s, .y, addr),
        .@"and" => aluA(s, .@"and", addr),
        .ora => aluA(s, .ora, addr),
        .eor => aluA(s, .eor, addr),
        .adc => addA(s, .adc, addr),
        .sbc => addA(s, .sbc, addr),
        .bit => bit(s, addr),
        .cmp => cmp(s, .a, addr),
        .cpx => cmp(s, .x, addr),
        .cpy => cmp(s, .y, addr),
        .asl => shift(s, .asl, if (op.mode == .accumulator) null else addr),
        .lsr => shift(s, .lsr, if (op.mode == .accumulator) null else addr),
        .rol => shift(s, .rol, if (op.mode == .accumulator) null else addr),
        .ror => shift(s, .ror, if (op.mode == .accumulator) null else addr),
        .inc => incMem(s, addr),
        .dec => decMem(s, addr),
        .inx => incReg(s, .x),
        .dex => decReg(s, .x),
        .iny => incReg(s, .y),
        .dey => decReg(s, .y),
        .tax => transfer(s, .a, .x),
        .txa => transfer(s, .x, .a),
        .tay => transfer(s, .a, .y),
        .tya => transfer(s, .y, .a),
        .tsx => transfer(s, .sp, .x),
        .txs => transfer(s, .x, .sp),
        .bcc => branch(s, addr, !s.cpu.flags.c),
        .bcs => branch(s, addr, s.cpu.flags.c),
        .beq => branch(s, addr, s.cpu.flags.z),
        .bne => branch(s, addr, !s.cpu.flags.z),
        .bmi => branch(s, addr, s.cpu.flags.n),
        .bpl => branch(s, addr, !s.cpu.flags.n),
        .bvs => branch(s, addr, s.cpu.flags.v),
        .bvc => branch(s, addr, !s.cpu.flags.v),
        .clc => flag(s, .clc),
        .sec => flag(s, .sec),
        .cli => flag(s, .cli),
        .sei => flag(s, .sei),
        .cld => flag(s, .cld),
        .sed => flag(s, .sed),
        .clv => flag(s, .clv),
        .jmp => s.cpu.pc = addr,
        .jsr => jsr(s, addr),
        .rti => rti(s),
        .rts => rts(s),
        .brk => interrupt(s, .brk),
        .pha => pha(s),
        .php => php(s),
        .pla => pla(s),
        .plp => plp(s),
        .kil => s.cpu.halted = true,
    }
}

pub fn interrupt(s: *System, kind: Interrupt) void {
    if (kind != .brk) _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(s.cpu.pc);
    if (kind == .brk) s.cpu.pc +%= 1;

    const pc = s.cpu.pc;
    stackPush(s, @truncate(pc >> 8));
    stackPush(s, @truncate(pc));

    var flags = s.cpu.flags;
    flags.b = kind == .brk;
    flags.unused = true;
    stackPush(s, flags.toByte());

    s.cpu.flags.i = true;
    const vector: u16 = if (kind == .nmi) 0xfffa else 0xfffe;
    const lo = s.cycleRead(vector);
    const hi = s.cycleRead(vector + 1);
    s.cpu.pc = @as(u16, hi) << 8 | lo;
}

fn nop(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
}

fn ld(s: *System, reg: Register8, addr: u16) void {
    const value = s.cycleRead(addr);
    s.cpu.setRegNZ(reg, value);
}

fn st(s: *System, reg: Register8, addr: u16) void {
    s.cycleWrite(addr, s.cpu.readReg(reg));
}

fn transfer(s: *System, src: Register8, dst: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    const value = s.cpu.readReg(src);
    s.cpu.setReg(dst, value);
    if (dst != .sp) s.cpu.setNZ(value);
}

fn aluA(s: *System, comptime op: opcodes.Mnemonic, addr: u16) void {
    const value = s.cycleRead(addr);
    const result: u8 = switch (op) {
        .@"and" => s.cpu.a & value,
        .ora => s.cpu.a | value,
        .eor => s.cpu.a ^ value,
        else => @compileError("invalid alu op"),
    };
    s.cpu.setRegNZ(.a, result);
}

fn addA(s: *System, comptime op: opcodes.Mnemonic, addr: u16) void {
    var value = s.cycleRead(addr);
    if (op == .sbc) value ^= 0xff;

    const a = s.cpu.a;
    const carry: u16 = @intFromBool(s.cpu.flags.c);
    const sum: u16 = @as(u16, a) +% @as(u16, value) +% carry;
    const result8: u8 = @truncate(sum);

    s.cpu.flags.c = sum > 0xff;
    s.cpu.flags.v = (~(a ^ value) & (a ^ result8) & 0x80) != 0;
    s.cpu.setRegNZ(.a, result8);
}

fn bit(s: *System, addr: u16) void {
    const value = s.cycleRead(addr);
    s.cpu.flags.z = s.cpu.a & value == 0;
    s.cpu.flags.n = value & 0x80 != 0;
    s.cpu.flags.v = value & 0x40 != 0;
}

fn cmp(s: *System, reg: Register8, addr: u16) void {
    const value = s.cycleRead(addr);
    s.cpu.compare(s.cpu.readReg(reg), value);
}

fn incReg(s: *System, reg: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cpu.setRegNZ(reg, s.cpu.readReg(reg) +% 1);
}

fn decReg(s: *System, reg: Register8) void {
    _ = s.cycleRead(s.cpu.pc);
    s.cpu.setRegNZ(reg, s.cpu.readReg(reg) -% 1);
}

fn shift(s: *System, op: ShiftOp, addr: ?u16) void {
    var original: u8 = s.cpu.a;
    if (addr) |a| original = s.cycleRead(a);

    const carry: u8 = @intFromBool(s.cpu.flags.c);
    var value: u8 = undefined;
    switch (op) {
        .asl => {
            s.cpu.flags.c = original & 0x80 != 0;
            value = original << 1;
        },
        .lsr => {
            s.cpu.flags.c = original & 0x01 != 0;
            value = original >> 1;
        },
        .rol => {
            s.cpu.flags.c = original & 0x80 != 0;
            value = (original << 1) | carry;
        },
        .ror => {
            s.cpu.flags.c = original & 0x01 != 0;
            value = (carry << 7) | (original >> 1);
        },
    }

    if (addr) |a| {
        s.cycleWrite(a, original);
        s.cycleWrite(a, value);
    } else {
        s.cpu.a = value;
    }

    s.cpu.setNZ(value);
}

fn incMem(s: *System, addr: u16) void {
    const original = s.cycleRead(addr);
    const value = original +% 1;
    s.cycleWrite(addr, original);
    s.cycleWrite(addr, value);
    s.cpu.setNZ(value);
}

fn decMem(s: *System, addr: u16) void {
    const original = s.cycleRead(addr);
    const value = original -% 1;
    s.cycleWrite(addr, original);
    s.cycleWrite(addr, value);
    s.cpu.setNZ(value);
}

fn jsr(s: *System, addrLo: u16) void {
    _ = s.cycleRead(0x0100 | @as(u16, s.cpu.sp));
    const returnPc = s.cpu.pc;
    stackPush(s, @truncate(returnPc >> 8));
    stackPush(s, @truncate(returnPc));
    const addrHi = s.cycleRead(s.cpu.pc);
    s.cpu.pc = @as(u16, addrHi) << 8 | addrLo;
}

fn rti(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(0x0100 | @as(u16, s.cpu.sp));
    s.cpu.flags = cpu.Flags.fromByte(stackPop(s));
    s.cpu.flags.b = false;
    const lo = stackPop(s);
    const hi = stackPop(s);
    s.cpu.pc = @as(u16, hi) << 8 | lo;
}

fn rts(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(0x0100 | @as(u16, s.cpu.sp));
    const lo = stackPop(s);
    const hi = stackPop(s);
    const addr = @as(u16, hi) << 8 | lo;
    _ = s.cycleRead(addr);
    s.cpu.pc = addr +% 1;
}

fn branch(s: *System, addr: u16, taken: bool) void {
    if (!taken) return;

    const pc = s.cpu.pc;
    _ = s.cycleRead(pc);
    if ((pc & 0xff00) != (addr & 0xff00)) {
        _ = s.cycleRead((pc & 0xff00) | (addr & 0x00ff));
    }
    s.cpu.pc = addr;
}

fn flag(s: *System, comptime op: opcodes.Mnemonic) void {
    _ = s.cycleRead(s.cpu.pc);
    switch (op) {
        .clc => s.cpu.flags.c = false,
        .sec => s.cpu.flags.c = true,
        .cli => s.cpu.flags.i = false,
        .sei => s.cpu.flags.i = true,
        .cld => s.cpu.flags.d = false,
        .sed => s.cpu.flags.d = true,
        .clv => s.cpu.flags.v = false,
        else => @compileError("invalid flag op"),
    }
}

fn pha(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    stackPush(s, s.cpu.a);
}

fn php(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    var flags = s.cpu.flags;
    flags.b = true;
    flags.unused = true;
    stackPush(s, flags.toByte());
}

fn pla(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(0x0100 | @as(u16, s.cpu.sp));
    s.cpu.setRegNZ(.a, stackPop(s));
}

fn plp(s: *System) void {
    _ = s.cycleRead(s.cpu.pc);
    _ = s.cycleRead(0x0100 | @as(u16, s.cpu.sp));
    s.cpu.flags = cpu.Flags.fromByte(stackPop(s));
    s.cpu.flags.b = false;
}
