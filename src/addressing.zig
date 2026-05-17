const cpuMod = @import("cpu.zig");
const Cpu = cpuMod.Cpu;
const Register8 = cpuMod.Register8;

pub fn immediate(cpu: *Cpu) u16 {
    const addr = cpu.pc;
    cpu.pc +%= 1;
    return addr;
}

pub fn zeroPage(cpu: *Cpu, ctx: anytype, comptime r: ?Register8) u16 {
    const addr = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    if (r == null) return addr;

    ctx.idle(cpu.pc);
    return (addr + cpu.readReg(r.?)) & 0xff;
}

pub fn absolute(cpu: *Cpu, ctx: anytype, comptime r: ?Register8) u16 {
    const lo = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    const hi = ctx.read(cpu.pc);
    cpu.pc +%= 1;

    const base: u16 = hi << 8 | lo;
    if (r == null) return base;

    const addr = (base +% cpu.readReg(r.?));
    // TODO: some instructions will always do this extra read regardless.
    if ((base & 0xff00) != (addr & 0xff00)) {
        ctx.idle(cpu.pc); // TODO dummy read
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

    const ptrHi = if ((ptr & 0x00ff) == 0x00ff) ptr & 0x00ff else ptr + 1;
    const addrHi = ctx.read(ptrHi);

    cpu.pc +%= 1;
    return @as(u16, addrHi) << 8 | addrLo;
}
