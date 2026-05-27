const cpu = @import("cpu.zig");
const nes = @import("system.zig");

const System = nes.System;
const Register8 = cpu.Register8;

pub fn immediate(s: *System) u16 {
    const addr = s.cpu.pc;
    s.cpu.pc +%= 1;
    return addr;
}

pub fn relative(s: *System) u16 {
    const offset = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    if (offset < 0x80) return s.cpu.pc +% offset;
    return s.cpu.pc -% (0x100 - @as(u16, offset));
}

pub fn zeroPage(s: *System, comptime r: ?Register8) u16 {
    const addr = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    if (r == null) return addr;

    s.cycleIdle();
    return (addr +% s.cpu.readReg(r.?)) & 0xff;
}

pub fn absolute(s: *System, comptime r: ?Register8, forceDummyRead: bool) u16 {
    const lo = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    const hi = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    const base: u16 = @as(u16, hi) << 8 | lo;
    if (r == null) return base;

    const addr = (base +% s.cpu.readReg(r.?));
    if (forceDummyRead or (base & 0xff00) != (addr & 0xff00)) {
        _ = s.cycleRead((base & 0xff00) | (addr & 0x00ff));
    }
    return addr;
}

pub fn indirect(s: *System) u16 {
    const lo = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    const hi = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    const ptr: u16 = @as(u16, hi) << 8 | lo;
    const addrLo = s.cycleRead(ptr);
    s.cpu.pc +%= 1;

    const ptrHi = if ((ptr & 0x00ff) == 0x00ff) ptr & 0xff00 else ptr + 1;
    const addrHi = s.cycleRead(ptrHi);

    s.cpu.pc +%= 1;
    return @as(u16, addrHi) << 8 | addrLo;
}

pub fn indirectIndexed(s: *System, comptime r: Register8, forceDummyRead: bool) u16 {
    const operand = s.cycleRead(s.cpu.pc);
    s.cpu.pc +%= 1;

    var ptr: u8 = undefined;
    switch (r) {
        .x => {
            s.cycleIdle();
            ptr = operand +% s.cpu.x;
        },
        .y => ptr = operand,
        else => @compileError("invalid register for indirectIndexed"),
    }

    const lo = s.cycleRead(ptr);
    const hi = s.cycleRead(ptr +% 1);
    const base: u16 = @as(u16, hi) << 8 | lo;

    if (r == .x) return base;

    const addr = base +% s.cpu.y;
    if (forceDummyRead or (base & 0xff00) != (addr & 0xff00)) {
        _ = s.cycleRead((base & 0xff00) | (addr & 0x00ff));
    }
    return addr;
}
