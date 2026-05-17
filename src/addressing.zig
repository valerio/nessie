const Cpu = @import("cpu.zig").Cpu;

pub fn immediate(cpu: *Cpu) u16 {
    const addr = cpu.pc;
    cpu.pc +%= 1;
    return addr;
}

pub fn zeroPage(comptime Context: type, cpu: *Cpu, ctx: *Context) u16 {
    const addr = ctx.read(cpu.pc);
    cpu.pc +%= 1;
    return addr;
}
