const cpuMod = @import("cpu.zig");
const Cpu = cpuMod.Cpu;
const Register8 = cpuMod.Register8;

pub fn immediate(cpu: *Cpu) u16 {
    const addr = cpu.pc;
    cpu.pc +%= 1;
    return addr;
}

pub fn relative(cpu: *Cpu, ctx: anytype) u16 {
    const offset = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    if (offset < 0x80) return cpu.pc +% offset;
    return cpu.pc -% (0x100 - @as(u16, offset));
}

pub fn zeroPage(cpu: *Cpu, ctx: anytype, comptime r: ?Register8) u16 {
    const addr = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    if (r == null) return addr;

    ctx.idle();
    return (addr +% cpu.readReg(r.?)) & 0xff;
}

pub fn absolute(cpu: *Cpu, ctx: anytype, comptime r: ?Register8, forceDummyRead: bool) u16 {
    const lo = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    const hi = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    const base: u16 = @as(u16, hi) << 8 | lo;
    if (r == null) return base;

    const addr = (base +% cpu.readReg(r.?));
    if (forceDummyRead or (base & 0xff00) != (addr & 0xff00)) {
        _ = ctx.read((base & 0xff00) | (addr & 0x00ff));
    }
    return addr;
}

pub fn indirect(cpu: *Cpu, ctx: anytype) u16 {
    const lo = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    const hi = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    const ptr: u16 = @as(u16, hi) << 8 | lo;
    const addrLo = ctx.read(ptr);
    cpu.pc +%= 1;

    const ptrHi = if ((ptr & 0x00ff) == 0x00ff) ptr & 0xff00 else ptr + 1;
    const addrHi = ctx.read(ptrHi);

    cpu.pc +%= 1;
    return @as(u16, addrHi) << 8 | addrLo;
}

pub fn indirectIndexed(cpu: *Cpu, ctx: anytype, comptime r: Register8, forceDummyRead: bool) u16 {
    const operand = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    var ptr: u8 = undefined;
    switch (r) {
        .x => {
            ctx.idle();
            ptr = operand +% cpu.x;
        },
        .y => ptr = operand,
        else => @compileError("invalid register for indirectIndexed"),
    }

    const lo = ctx.read(ptr);
    const hi = ctx.read(ptr +% 1);
    const base: u16 = @as(u16, hi) << 8 | lo;

    if (r == .x) return base;

    const addr = base +% cpu.y;
    if (forceDummyRead or (base & 0xff00) != (addr & 0xff00)) {
        _ = ctx.read((base & 0xff00) | (addr & 0x00ff));
    }
    return addr;
}
