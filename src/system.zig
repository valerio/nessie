const std = @import("std");
const cpu = @import("cpu.zig");
const mapper = @import("mapper.zig");
const cart = @import("cart.zig");
const input = @import("input.zig");
const apu_mod = @import("apu.zig");
const dmc_mod = @import("dmc.zig");
const ppu = @import("ppu.zig");
const opcodes = @import("opcodes.zig");
const addressing = @import("addressing.zig");
const instructions = @import("instructions.zig");

const testing = std.testing;
const Cpu = cpu.Cpu;
const Mapper = mapper.Mapper;
const Cartridge = cart.Cartridge;
const Ppu = ppu.Ppu;
const Controller = input.Controller;
const Apu = apu_mod.Apu;

const internalRamSize = 0x800; // 2KB
const apuDecodeMask = 0xffe0;
const apuDecodeBase = 0x4000;

fn isPpuRegisterAddr(addr: u16) bool {
    return addr >= 0x2000 and addr < 0x4000;
}

fn dotToCpuCycle(dot: u32) u32 {
    return (dot + 2) / 3;
}

pub const System = struct {
    // Owned machine components.
    cpu: Cpu = .{},
    ppu: Ppu = .{},
    apu: Apu = .{},
    controller1: Controller = .{},
    controller2: Controller = .{},
    mapper: Mapper,
    cartridge: Cartridge = .{},
    internalRam: [internalRamSize]u8 = [_]u8{0} ** internalRamSize,

    // CPU bus and frame accounting.
    cpuCycles: u64 = 0,
    frameCounter: u64 = 0,
    lastBusValue: u8 = 0,
    lastReadAddr: u16 = 0,
    ppuDotAdjust: i8 = 0,

    // NMI edge timing.
    pendingNmi: bool = false,
    nmiDelay: ?u8 = null,
    ppuNmiLine: bool = false,
    nmiRisingDot: ?u32 = null,
    nmiFallingDot: ?u32 = null,
    ppuDotsSinceNmiCommit: u32 = 0,
    nmiCommittedCyclesThisInstruction: u32 = 0,

    // IRQ sampling.
    irqReady: bool = false,
    pendingIrq: bool = false,
    irqSample: bool = false,
    prevIrqSample: bool = false,

    // DMA state.
    pendingOamDmaPage: ?u8 = null,
    oamDmaActive: bool = false,
    oamDmaRemaining: u16 = 0,
    oamHaltedCoreAddr: u16 = 0,

    pub fn initFromCart(c: Cartridge) System {
        var sys: System = .{
            .mapper = mapper.fromCart(&c),
            .cartridge = c,
            .cpuCycles = 7,
        };
        const lo = sys.busRead(0xfffc);
        const hi = sys.busRead(0xfffd);
        sys.cpu.pc = @as(u16, hi) << 8 | lo;
        return sys;
    }

    pub fn initFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !System {
        const c = try cart.loadFile(allocator, io, path);
        return initFromCart(c);
    }

    pub fn deinit(self: *System, allocator: std.mem.Allocator) void {
        cart.deinit(&self.cartridge, allocator);
        self.* = undefined;
    }

    pub fn runFrame(self: *System) void {
        var previousScanline = self.ppu.scanline;
        var frameComplete = false;

        while (!frameComplete) {
            self.runInstruction();
            const currentScanline = self.ppu.scanline;
            frameComplete = previousScanline < ppu.scanlinePostRender and currentScanline >= ppu.scanlinePostRender;
            previousScanline = currentScanline;
        }
    }

    pub fn setController1Buttons(self: *System, buttons: u8) void {
        self.controller1.buttons = buttons;
        if (self.controller1.strobe) self.controller1.shiftReg = buttons;
    }

    pub fn setController2Buttons(self: *System, buttons: u8) void {
        self.controller2.buttons = buttons;
        if (self.controller2.strobe) self.controller2.shiftReg = buttons;
    }

    pub fn readMemory(self: *const System, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x1fff => self.internalRam[addr & 0x07ff],
            0x6000...0xffff => self.mapper.read(addr),
            else => 0,
        };
    }

    fn runInstruction(self: *System) void {
        const cyclesBefore = self.cpuCycles;
        self.nmiCommittedCyclesThisInstruction = 0;
        if (self.cpu.halted) {
            tick(self);
            self.commitNmiForInstruction(cyclesBefore);
            return;
        }

        if (self.pendingNmi) {
            self.pendingNmi = false;
            instructions.interrupt(self, .nmi);
            self.runPendingDmaAtInstructionBoundary();
            self.commitNmiForInstruction(cyclesBefore);
            self.samplePendingIrq();
            return;
        }

        if (self.irqReady) {
            self.irqReady = false;
            instructions.interrupt(self, .irq);
            self.runPendingDmaAtInstructionBoundary();
            self.commitNmiForInstruction(cyclesBefore);
            self.samplePendingIrq();
            return;
        }

        const op = opcodes.table[self.cycleRead(self.cpu.pc)];
        self.cpu.pc +%= 1;

        instructions.exec(self, op);
        self.runPendingDmaAtInstructionBoundary();
        self.commitNmiForInstruction(cyclesBefore);
        self.samplePendingIrq();
    }

    pub fn cycleRead(s: *System, addr: u16) u8 {
        return s.cycleReadWithIrqLatch(addr, true);
    }

    pub fn cycleReadWithoutIrqLatch(s: *System, addr: u16) u8 {
        return s.cycleReadWithIrqLatch(addr, false);
    }

    fn cycleReadWithIrqLatch(s: *System, addr: u16, latch_irq: bool) u8 {
        const deferPpu = isPpuRegisterAddr(addr);
        s.lastReadAddr = addr;
        s.tickPre(latch_irq, !deferPpu);
        s.runDmcSteal(.read);
        const value = s.busRead(addr);
        s.finishCpuBusOp(deferPpu);
        return value;
    }

    pub fn cycleWrite(s: *System, addr: u16, value: u8) void {
        const deferPpu = isPpuRegisterAddr(addr);
        s.tickPre(true, !deferPpu);
        s.runDmcSteal(.write);
        s.busWrite(addr, value);
        s.finishCpuBusOp(deferPpu);
    }

    pub fn cycleIdle(s: *System) void {
        s.tickPre(true, true);
        s.runDmcSteal(.idle);
        s.lastReadAddr = 0;
        s.finishCpuBusOp(false);
    }

    fn dmaCycleRead(s: *System, addr: u16) u8 {
        s.lastReadAddr = addr;
        s.tickPre(false, true);
        s.runDmcSteal(.read);
        const value = s.busRead(addr);
        s.finishCpuBusOp(false);
        return value;
    }

    fn dmaCycleIdle(s: *System) void {
        s.tickPre(false, true);
        s.runDmcSteal(.idle);
        s.lastReadAddr = 0;
        s.finishCpuBusOp(false);
    }

    fn tickPre(s: *System, latch_irq: bool, advance_ppu: bool) void {
        s.cpu.lastCycleWasDmcRead = false;
        if (latch_irq) s.latchIrq();
        if (advance_ppu) s.advancePpu();
        s.cpuCycles += 1;
        s.apu.tickChannelTimers(s.isGetCycle());
    }

    fn latchIrq(self: *System) void {
        self.prevIrqSample = self.irqSample;
        self.irqSample = self.pendingIrq and !self.cpu.flags.i;
    }

    fn samplePendingIrq(self: *System) void {
        self.irqReady = self.prevIrqSample;
    }

    fn tickNmiDelay(self: *System, cpu_cycles: u32) void {
        const delay = self.nmiDelay orelse return;
        if (cpu_cycles >= delay) {
            self.nmiDelay = null;
            self.pendingNmi = true;
        } else {
            self.nmiDelay = @intCast(delay - cpu_cycles);
        }
    }

    fn commitNmiForInstruction(self: *System, cycles_before: u64) void {
        const total: u32 = @intCast(self.cpuCycles - cycles_before);
        if (total <= self.nmiCommittedCyclesThisInstruction) return;
        self.commitNmi(total - self.nmiCommittedCyclesThisInstruction);
    }

    pub fn commitNmi(self: *System, cpu_cycles: u32) void {
        if (cpu_cycles == 0) return;
        self.nmiCommittedCyclesThisInstruction += cpu_cycles;

        if (self.nmiRisingDot) |risingDot| {
            self.nmiRisingDot = null;
            if (self.nmiDelay == null and !self.pendingNmi) {
                const detectCycle = dotToCpuCycle(risingDot);
                if (self.nmiFallingDot) |fallingDot| {
                    self.nmiFallingDot = null;
                    if (dotToCpuCycle(fallingDot) <= detectCycle) {
                        self.tickNmiDelay(cpu_cycles);
                        self.ppuDotsSinceNmiCommit = 0;
                        return;
                    }
                }

                const preTriggerCycles = @min(cpu_cycles, detectCycle + 1);
                self.tickNmiDelay(preTriggerCycles);

                self.nmiDelay = 1;
                if (detectCycle + 1 <= cpu_cycles) self.tickNmiDelay(cpu_cycles - detectCycle - 1);
            } else {
                self.tickNmiDelay(cpu_cycles);
            }
        } else {
            self.nmiFallingDot = null;
            self.tickNmiDelay(cpu_cycles);
        }

        self.ppuDotsSinceNmiCommit = 0;
    }

    fn setPpuNmiLine(self: *System, level: bool) void {
        if (level) {
            if (!self.ppuNmiLine) {
                self.ppuNmiLine = true;
                if (self.nmiRisingDot == null) self.nmiRisingDot = self.ppuDotsSinceNmiCommit;
                self.nmiFallingDot = null;
            }
            return;
        }

        if (self.ppuNmiLine and self.nmiRisingDot != null and self.nmiFallingDot == null) {
            self.nmiFallingDot = self.ppuDotsSinceNmiCommit;
        }
        self.ppuNmiLine = false;
    }

    fn cancelNmi(self: *System) void {
        self.nmiDelay = null;
        self.pendingNmi = false;
        self.nmiRisingDot = null;
        self.nmiFallingDot = null;
        self.ppuNmiLine = false;
    }

    fn updateIrqLine(self: *System) void {
        self.pendingIrq = self.apu.frameIrqPending or self.apu.dmc.irqFlag;
    }

    fn tick(s: *System) void {
        s.advancePpu();
        s.cpuCycles += 1;
        s.apu.tickTimers(s.isGetCycle());
        s.updateIrqLine();
        if ((s.cpuCycles & 1) == 0) {
            s.controller1.commitStrobe();
            s.controller2.commitStrobe();
        }
    }

    fn tickDmcDmaCycle(s: *System) void {
        tick(s);
        if (!s.oamDmaActive) s.latchIrq();
    }

    fn finishCpuBusOp(self: *System, deferred_ppu: bool) void {
        self.apu.tickFrameCounter();
        self.updateIrqLine();
        if ((self.cpuCycles & 1) == 0) {
            self.controller1.commitStrobe();
            self.controller2.commitStrobe();
        }
        if (deferred_ppu) self.advancePpu();
    }

    fn advancePpu(self: *System) void {
        const dots = 3 + self.ppuDotAdjust;
        self.ppuDotAdjust = 0;
        if (dots <= 0) return;
        self.advancePpuDots(@intCast(dots));
    }

    fn advancePpuDots(self: *System, dots: u32) void {
        for (0..dots) |_| {
            const result = self.ppu.tickDots(&self.mapper, self.cartridge.mirrorMode, 1);
            if (result.nmi) self.setPpuNmiLine(true);
            if (!self.ppu.status.vblank or !self.ppu.ctrl.nmiEnable) self.setPpuNmiLine(false);
            if (result.frameDone) self.frameCounter += 1;
            self.ppuDotsSinceNmiCommit += 1;
        }
    }

    fn isGetCycle(self: *const System) bool {
        return (self.cpuCycles & 1) == 0;
    }

    fn busRead(self: *System, addr: u16) u8 {
        self.lastReadAddr = addr;

        if (self.readOamDmaApuMirror(addr)) |dmaValue| return dmaValue;

        switch (addr) {
            0x0000...0x1fff => {
                self.lastBusValue = self.internalRam[addr & 0x07ff];
                return self.lastBusValue;
            },
            0x2000...0x3fff => {
                if ((addr & 0x0007) == 0x0002) {
                    const statusHigh = self.ppu.readStatusRegisterM2High();
                    if (statusHigh.suppressNmi) self.cancelNmi();
                    self.setPpuNmiLine(false);
                    self.advancePpuDots(2);
                    self.lastBusValue = self.ppu.finishStatusRegisterM2Low(statusHigh.vblankBit);
                    self.ppuDotAdjust -= 2;
                } else {
                    self.lastBusValue = self.ppu.readRegister(&self.mapper, self.cartridge.mirrorMode, addr);
                }
                return self.lastBusValue;
            },
            0x4000...0x401f => return self.readIoRegister(addr),
            0x4020...0x5fff => return self.lastBusValue,
            0x6000...0xffff => {
                self.lastBusValue = self.mapper.read(addr);
                return self.lastBusValue;
            },
        }
    }

    fn readOamDmaApuMirror(self: *System, addr: u16) ?u8 {
        if (!self.oamDmaActive) return null;

        const coreBusInApuRange = (self.oamHaltedCoreAddr & apuDecodeMask) == apuDecodeBase;
        if (!coreBusInApuRange) {
            if (addr >= 0x4000 and addr < 0x4020) return self.lastBusValue;
            return null;
        }

        if (addr < 0x2000) {
            self.lastBusValue = self.internalRam[addr & 0x07ff];
        } else if (addr >= 0x6000) {
            self.lastBusValue = self.mapper.read(addr);
        }

        const mirrored: u16 = 0x4000 | (addr & 0x001f);
        self.lastBusValue = self.readIoRegister(mirrored);
        return self.lastBusValue;
    }

    fn readIoRegister(self: *System, addr: u16) u8 {
        var effectiveAddr = addr;
        var conflictSample: ?u8 = null;
        if (addr == 0x4000 and self.apu.dmc.conflictVisibleCpuOpsRemaining > 0) {
            effectiveAddr = 0x4000 | (self.apu.dmc.conflictSampleAddr & 0x001f);
            conflictSample = self.apu.dmc.conflictSample;
        }

        if (effectiveAddr == 0x4015) {
            const status = self.apu.readStatus(self.lastBusValue);
            self.updateIrqLine();
            if (conflictSample != null) {
                return self.lastBusValue;
            }
            return (status & 0xdf) | (self.lastBusValue & 0x20);
        }

        const highBits: u8 = if (conflictSample) |sample| sample & 0xe0 else self.lastBusValue & 0xe0;
        if (effectiveAddr == 0x4016) {
            self.lastBusValue = (self.controller1.read() & 0x1f) | highBits;
            return self.lastBusValue;
        }
        if (effectiveAddr == 0x4017) {
            self.lastBusValue = (self.controller2.read() & 0x1f) | highBits;
            return self.lastBusValue;
        }

        return self.lastBusValue;
    }

    fn busWrite(self: *System, addr: u16, value: u8) void {
        self.lastBusValue = value;
        switch (addr) {
            0x0000...0x1fff => self.internalRam[addr & 0x07ff] = value,
            0x2000...0x3fff => {
                const wasNmiEnabled = self.ppu.ctrl.nmiEnable;
                self.ppu.writeRegister(&self.mapper, self.cartridge.mirrorMode, addr, value);
                if ((addr & 0x0007) == 0 and !wasNmiEnabled and self.ppu.ctrl.nmiEnable and self.ppu.status.vblank) {
                    self.setPpuNmiLine(true);
                } else if ((addr & 0x0007) == 0 and !self.ppu.ctrl.nmiEnable) {
                    self.setPpuNmiLine(false);
                }
            },
            0x4014 => self.pendingOamDmaPage = value,
            0x4016 => {
                self.controller1.write4016(value);
                self.controller2.write4016(value);
            },
            0x4017 => {
                self.apu.writeFrameCounter(value);
                self.updateIrqLine();
            },
            0x4010...0x4013, 0x4000...0x400f => {
                self.apu.writeRegister(addr, value);
                self.updateIrqLine();
            },
            0x4015 => {
                self.apu.writeStatus(value, self.isGetCycle());
                self.updateIrqLine();
            },
            0x6000...0xffff => self.mapper.write(addr, value),
            else => {},
        }
    }

    fn writeOamDma(self: *System, page: u8) void {
        const base: u16 = @as(u16, page) << 8;
        self.oamDmaActive = true;
        defer {
            self.oamDmaActive = false;
            self.oamDmaRemaining = 0;
        }

        const needsAlignment = !self.isGetCycle();
        var remaining: u16 = 1 + (if (needsAlignment) @as(u16, 1) else 0) + 512;

        self.oamDmaRemaining = remaining;
        remaining -= 1;
        self.dmaCycleIdle();

        if (needsAlignment) {
            self.oamDmaRemaining = remaining;
            remaining -= 1;
            self.dmaCycleIdle();
        }

        const startOamAddr = self.ppu.oamAddr;
        for (0..256) |i| {
            self.oamDmaRemaining = remaining;
            remaining -= 1;
            const value = self.dmaCycleRead(base + @as(u16, @intCast(i)));

            self.ppu.oam[startOamAddr +% @as(u8, @intCast(i))] = value;

            self.oamDmaRemaining = remaining;
            remaining -= 1;
            self.dmaCycleIdle();
        }
    }

    fn runPendingDmaAtInstructionBoundary(self: *System) void {
        self.oamHaltedCoreAddr = self.cpu.pc;
        self.runPendingOamDma();
    }

    fn runPendingOamDma(self: *System) void {
        const page = self.pendingOamDmaPage orelse return;
        self.pendingOamDmaPage = null;
        self.writeOamDma(page);
    }

    fn runDmcSteal(self: *System, op_type: dmc_mod.BusOp) void {
        while (true) {
            const step = self.apu.dmc.tickDma(self.isGetCycle(), op_type, self.oamDmaActive);
            switch (step) {
                .none, .wait => return,
                .phantom => |phase| {
                    const overlapsOamCycle = phase != .alignPhase or
                        (op_type == .idle and self.oamDmaRemaining <= 2);
                    if (self.oamDmaActive and overlapsOamCycle) return;

                    _ = self.busRead(self.lastReadAddr);
                    self.tickDmcDmaCycle();
                },
                .sample => |addr| {
                    const byte = self.busRead(addr);
                    self.apu.dmc.completeDmaRead(byte);
                    self.tickDmcDmaCycle();
                    self.cpu.lastCycleWasDmcRead = true;
                    self.updateIrqLine();
                    return;
                },
            }
        }
    }
};

test "system executes LDA immediate" {
    var system: System = .{ .mapper = mapper.fromData(&[_]u8{0} ** 0x4000) };
    const testPc: u16 = 0x0200;

    system.cpu.pc = testPc;
    system.busWrite(testPc, 0xa9);
    system.busWrite(testPc + 1, 0x80);
    system.runInstruction();

    try testing.expectEqual(0x80, system.cpu.a);
    try testing.expect(!system.cpu.flags.z);
    try testing.expect(system.cpu.flags.n);
    try testing.expectEqual(testPc + 2, system.cpu.pc);
}

test "instruction execution" {
    const Setup = struct {
        a: u8 = 0,
        x: u8 = 0,
        y: u8 = 0,
        sp: u8 = 0xfd,
        flags: u8 = 0x24,
        read: ?struct { addr: u16, value: u8 = 0x42 } = null,
        ptr: ?struct { addr: u8, value: u16 } = null,
        addrPtr: ?struct { addr: u16, value: u16 = 0xabcd } = null,
    };
    const Want = struct {
        a: ?u8 = null,
        x: ?u8 = null,
        y: ?u8 = null,
        sp: ?u8 = null,
        flags: ?u8 = null,
        mem: ?struct { addr: u16, value: u8 } = null,
        pc: ?u16 = null,
    };

    const testPc: u16 = 0x0200;

    const testCases = [_]struct {
        opcode: u8,
        operand: []const u8 = &.{},
        setup: Setup = .{},
        want: Want = .{},
    }{
        .{ .opcode = 0xea, .setup = .{ .a = 0x11, .x = 0x22, .y = 0x33, .flags = 0x25 } }, // nop
        .{ .opcode = 0xaa, .setup = .{ .a = 0x80, .x = 0x11 }, .want = .{ .x = 0x80, .flags = 0xa4 } }, // tax
        .{ .opcode = 0x8a, .setup = .{ .a = 0x42, .x = 0x80 }, .want = .{ .a = 0x80, .flags = 0xa4 } }, // txa
        .{ .opcode = 0xa8, .setup = .{ .a = 0x42, .y = 0x11 }, .want = .{ .y = 0x42 } }, // tay
        .{ .opcode = 0x98, .setup = .{ .a = 0x42, .y = 0x80 }, .want = .{ .a = 0x80, .flags = 0xa4 } }, // tya
        .{ .opcode = 0xba, .setup = .{ .x = 0x11, .sp = 0x80 }, .want = .{ .x = 0x80, .sp = 0x80, .flags = 0xa4 } }, // tsx
        .{ .opcode = 0x9a, .setup = .{ .x = 0x42, .sp = 0x80, .flags = 0xa4 }, .want = .{ .x = 0x42, .sp = 0x42, .flags = 0xa4 } }, // txs
        .{ .opcode = 0xe8, .setup = .{ .x = 0xff }, .want = .{ .x = 0x00, .flags = 0x26 } }, // inx wraps
        .{ .opcode = 0xca, .setup = .{ .x = 0x00 }, .want = .{ .x = 0xff, .flags = 0xa4 } }, // dex wraps
        .{ .opcode = 0xc8, .setup = .{ .y = 0x7f }, .want = .{ .y = 0x80, .flags = 0xa4 } }, // iny
        .{ .opcode = 0x88, .setup = .{ .y = 0x01 }, .want = .{ .y = 0x00, .flags = 0x26 } }, // dey
        .{ .opcode = 0x18, .setup = .{ .flags = 0x25 }, .want = .{ .flags = 0x24 } }, // clc
        .{ .opcode = 0x38, .want = .{ .flags = 0x25 } }, // sec
        .{ .opcode = 0x58, .want = .{ .flags = 0x20 } }, // cli
        .{ .opcode = 0x78, .setup = .{ .flags = 0x20 }, .want = .{ .flags = 0x24 } }, // sei
        .{ .opcode = 0xd8, .setup = .{ .flags = 0x2c }, .want = .{ .flags = 0x24 } }, // cld
        .{ .opcode = 0xf8, .want = .{ .flags = 0x2c } }, // sed
        .{ .opcode = 0xb8, .setup = .{ .flags = 0x64 }, .want = .{ .flags = 0x24 } }, // clv
        .{ .opcode = 0x48, .setup = .{ .a = 0x42 }, .want = .{ .a = 0x42, .sp = 0xfc, .mem = .{ .addr = 0x01fd, .value = 0x42 } } }, // pha
        .{ .opcode = 0x08, .want = .{ .sp = 0xfc, .mem = .{ .addr = 0x01fd, .value = 0x34 } } }, // php
        .{ .opcode = 0x68, .setup = .{ .sp = 0xfc, .read = .{ .addr = 0x01fd, .value = 0x80 } }, .want = .{ .a = 0x80, .sp = 0xfd, .flags = 0xa4 } }, // pla
        .{ .opcode = 0x28, .setup = .{ .sp = 0xfc, .read = .{ .addr = 0x01fd, .value = 0xc5 } }, .want = .{ .sp = 0xfd, .flags = 0xe5 } }, // plp

        .{ .opcode = 0xa9, .operand = &.{0x42}, .want = .{ .a = 0x42 } }, // lda immediate
        .{ .opcode = 0xa2, .operand = &.{0x42}, .want = .{ .x = 0x42 } }, // ldx immediate
        .{ .opcode = 0xa0, .operand = &.{0x42}, .want = .{ .y = 0x42 } }, // ldy immediate
        .{ .opcode = 0xa5, .operand = &.{0x80}, .setup = .{ .read = .{ .addr = 0x0080 } }, .want = .{ .a = 0x42 } }, // lda
        .{ .opcode = 0xa6, .operand = &.{0x80}, .setup = .{ .read = .{ .addr = 0x0080 } }, .want = .{ .x = 0x42 } }, // ldx
        .{ .opcode = 0xa4, .operand = &.{0x80}, .setup = .{ .read = .{ .addr = 0x0080 } }, .want = .{ .y = 0x42 } }, // ldy
        .{ .opcode = 0xb5, .operand = &.{0x80}, .setup = .{ .x = 0x04, .read = .{ .addr = 0x0084 } }, .want = .{ .a = 0x42 } }, // lda zero page,x
        .{ .opcode = 0xb4, .operand = &.{0x80}, .setup = .{ .x = 0x04, .read = .{ .addr = 0x0084 } }, .want = .{ .y = 0x42 } }, // ldy zero page,x
        .{ .opcode = 0xb6, .operand = &.{0x80}, .setup = .{ .y = 0x04, .read = .{ .addr = 0x0084 } }, .want = .{ .x = 0x42 } }, // ldx zero page,y
        .{ .opcode = 0xb5, .operand = &.{0xff}, .setup = .{ .x = 0x01, .read = .{ .addr = 0x0000 } }, .want = .{ .a = 0x42 } }, // zero page,x wraps
        .{ .opcode = 0xad, .operand = &.{ 0x34, 0x12 }, .setup = .{ .read = .{ .addr = 0x1234 } }, .want = .{ .a = 0x42 } }, // lda absolute
        .{ .opcode = 0xae, .operand = &.{ 0x34, 0x12 }, .setup = .{ .read = .{ .addr = 0x1234 } }, .want = .{ .x = 0x42 } }, // ldx absolute
        .{ .opcode = 0xac, .operand = &.{ 0x34, 0x12 }, .setup = .{ .read = .{ .addr = 0x1234 } }, .want = .{ .y = 0x42 } }, // ldy absolute
        .{ .opcode = 0xbd, .operand = &.{ 0x30, 0x12 }, .setup = .{ .x = 0x04, .read = .{ .addr = 0x1234 } }, .want = .{ .a = 0x42 } }, // lda absolute,x
        .{ .opcode = 0xb9, .operand = &.{ 0xff, 0x12 }, .setup = .{ .y = 0x01, .read = .{ .addr = 0x1300 } }, .want = .{ .a = 0x42 } }, // lda absolute,y page-cross
        .{ .opcode = 0xbe, .operand = &.{ 0x30, 0x12 }, .setup = .{ .y = 0x04, .read = .{ .addr = 0x1234 } }, .want = .{ .x = 0x42 } }, // ldx absolute,y
        .{ .opcode = 0xbc, .operand = &.{ 0x30, 0x12 }, .setup = .{ .x = 0x04, .read = .{ .addr = 0x1234 } }, .want = .{ .y = 0x42 } }, // ldy absolute,x
        .{ .opcode = 0xa1, .operand = &.{0x80}, .setup = .{ .x = 0x04, .read = .{ .addr = 0x1234 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x42 } }, // lda (indirect,x)
        .{ .opcode = 0xa1, .operand = &.{0xff}, .setup = .{ .x = 0x01, .read = .{ .addr = 0x1234 }, .ptr = .{ .addr = 0x00, .value = 0x1234 } }, .want = .{ .a = 0x42 } }, // lda (indirect,x) wraps pointer
        .{ .opcode = 0xb1, .operand = &.{0x80}, .setup = .{ .y = 0x04, .read = .{ .addr = 0x1234 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x42 } }, // lda (indirect),y
        .{ .opcode = 0xb1, .operand = &.{0xff}, .setup = .{ .y = 0x01, .read = .{ .addr = 0x1300 }, .ptr = .{ .addr = 0xff, .value = 0x12ff } }, .want = .{ .a = 0x42 } }, // lda (indirect),y wraps pointer and page-crosses

        .{ .opcode = 0x29, .operand = &.{0x0f}, .setup = .{ .a = 0xf3 }, .want = .{ .a = 0x03 } }, // and immediate
        .{ .opcode = 0x25, .operand = &.{0x80}, .setup = .{ .a = 0xf0, .read = .{ .addr = 0x0080, .value = 0x0f } }, .want = .{ .a = 0x00, .flags = 0x26 } }, // and zero page sets z
        .{ .opcode = 0x35, .operand = &.{0x80}, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x80 } }, .want = .{ .a = 0x80, .flags = 0xa4 } }, // and zero page,x sets n
        .{ .opcode = 0x2d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0xf3, .read = .{ .addr = 0x1234, .value = 0x0f } }, .want = .{ .a = 0x03 } }, // and absolute
        .{ .opcode = 0x3d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x7f } }, .want = .{ .a = 0x7f } }, // and absolute,x
        .{ .opcode = 0x39, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0xff, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x40 } }, .want = .{ .a = 0x40 } }, // and absolute,y page-cross
        .{ .opcode = 0x21, .operand = &.{0x80}, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x22 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x22 } }, // and (indirect,x)
        .{ .opcode = 0x31, .operand = &.{0x80}, .setup = .{ .a = 0xff, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x11 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x11 } }, // and (indirect),y

        .{ .opcode = 0x09, .operand = &.{0x0f}, .setup = .{ .a = 0xf0 }, .want = .{ .a = 0xff, .flags = 0xa4 } }, // ora immediate
        .{ .opcode = 0x05, .operand = &.{0x80}, .setup = .{ .a = 0x00, .read = .{ .addr = 0x0080, .value = 0x00 } }, .want = .{ .a = 0x00, .flags = 0x26 } }, // ora zero page sets z
        .{ .opcode = 0x15, .operand = &.{0x80}, .setup = .{ .a = 0x01, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x02 } }, .want = .{ .a = 0x03 } }, // ora zero page,x
        .{ .opcode = 0x0d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x10, .read = .{ .addr = 0x1234, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // ora absolute
        .{ .opcode = 0x1d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0x40, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x80 } }, .want = .{ .a = 0xc0, .flags = 0xa4 } }, // ora absolute,x
        .{ .opcode = 0x19, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0x20, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x01 } }, .want = .{ .a = 0x21 } }, // ora absolute,y page-cross
        .{ .opcode = 0x01, .operand = &.{0x80}, .setup = .{ .a = 0x01, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x04 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x05 } }, // ora (indirect,x)
        .{ .opcode = 0x11, .operand = &.{0x80}, .setup = .{ .a = 0x01, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x08 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x09 } }, // ora (indirect),y

        .{ .opcode = 0x49, .operand = &.{0xff}, .setup = .{ .a = 0x0f }, .want = .{ .a = 0xf0, .flags = 0xa4 } }, // eor immediate
        .{ .opcode = 0x45, .operand = &.{0x80}, .setup = .{ .a = 0xaa, .read = .{ .addr = 0x0080, .value = 0xaa } }, .want = .{ .a = 0x00, .flags = 0x26 } }, // eor zero page sets z
        .{ .opcode = 0x55, .operand = &.{0x80}, .setup = .{ .a = 0x0f, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0xf0 } }, .want = .{ .a = 0xff, .flags = 0xa4 } }, // eor zero page,x
        .{ .opcode = 0x4d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0xf0, .read = .{ .addr = 0x1234, .value = 0x0f } }, .want = .{ .a = 0xff, .flags = 0xa4 } }, // eor absolute
        .{ .opcode = 0x5d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x7f } }, .want = .{ .a = 0x80, .flags = 0xa4 } }, // eor absolute,x
        .{ .opcode = 0x59, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0xff, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0xfe } }, .want = .{ .a = 0x01 } }, // eor absolute,y page-cross
        .{ .opcode = 0x41, .operand = &.{0x80}, .setup = .{ .a = 0xf0, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x0f }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0xff, .flags = 0xa4 } }, // eor (indirect,x)
        .{ .opcode = 0x51, .operand = &.{0x80}, .setup = .{ .a = 0x0f, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x0e }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x01 } }, // eor (indirect),y

        .{ .opcode = 0x69, .operand = &.{0x02}, .setup = .{ .a = 0x10 }, .want = .{ .a = 0x12 } }, // adc immediate
        .{ .opcode = 0x69, .operand = &.{0x01}, .setup = .{ .a = 0xff }, .want = .{ .a = 0x00, .flags = 0x27 } }, // adc sets carry and zero
        .{ .opcode = 0x69, .operand = &.{0x01}, .setup = .{ .a = 0x7f }, .want = .{ .a = 0x80, .flags = 0xe4 } }, // adc sets overflow and negative
        .{ .opcode = 0x65, .operand = &.{0x80}, .setup = .{ .a = 0x10, .read = .{ .addr = 0x0080, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // adc zero page
        .{ .opcode = 0x75, .operand = &.{0x80}, .setup = .{ .a = 0x10, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // adc zero page,x
        .{ .opcode = 0x6d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x10, .read = .{ .addr = 0x1234, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // adc absolute
        .{ .opcode = 0x7d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0x10, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // adc absolute,x
        .{ .opcode = 0x79, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0x10, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // adc absolute,y page-cross
        .{ .opcode = 0x61, .operand = &.{0x80}, .setup = .{ .a = 0x10, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x02 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x12 } }, // adc (indirect,x)
        .{ .opcode = 0x71, .operand = &.{0x80}, .setup = .{ .a = 0x10, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x02 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x12 } }, // adc (indirect),y

        .{ .opcode = 0xe9, .operand = &.{0x10}, .setup = .{ .a = 0x30, .flags = 0x25 }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc immediate
        .{ .opcode = 0xe9, .operand = &.{0x20}, .setup = .{ .a = 0x10, .flags = 0x25 }, .want = .{ .a = 0xf0, .flags = 0xa4 } }, // sbc clears carry on borrow
        .{ .opcode = 0xe9, .operand = &.{0x01}, .setup = .{ .a = 0x80, .flags = 0x25 }, .want = .{ .a = 0x7f, .flags = 0x65 } }, // sbc sets overflow
        .{ .opcode = 0xe5, .operand = &.{0x80}, .setup = .{ .a = 0x30, .flags = 0x25, .read = .{ .addr = 0x0080, .value = 0x10 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc zero page
        .{ .opcode = 0xf5, .operand = &.{0x80}, .setup = .{ .a = 0x30, .x = 0x04, .flags = 0x25, .read = .{ .addr = 0x0084, .value = 0x10 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc zero page,x
        .{ .opcode = 0xed, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x30, .flags = 0x25, .read = .{ .addr = 0x1234, .value = 0x10 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc absolute
        .{ .opcode = 0xfd, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0x30, .x = 0x04, .flags = 0x25, .read = .{ .addr = 0x1234, .value = 0x10 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc absolute,x
        .{ .opcode = 0xf9, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0x30, .y = 0x01, .flags = 0x25, .read = .{ .addr = 0x1300, .value = 0x10 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc absolute,y page-cross
        .{ .opcode = 0xe1, .operand = &.{0x80}, .setup = .{ .a = 0x30, .x = 0x04, .flags = 0x25, .read = .{ .addr = 0x1234, .value = 0x10 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc (indirect,x)
        .{ .opcode = 0xf1, .operand = &.{0x80}, .setup = .{ .a = 0x30, .y = 0x04, .flags = 0x25, .read = .{ .addr = 0x1234, .value = 0x10 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x20, .flags = 0x25 } }, // sbc (indirect),y

        .{ .opcode = 0x24, .operand = &.{0x80}, .setup = .{ .a = 0x02, .read = .{ .addr = 0x0080, .value = 0xc2 } }, .want = .{ .a = 0x02, .flags = 0xe4 } }, // bit zero page sets n/v
        .{ .opcode = 0x2c, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x01, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .a = 0x01, .flags = 0x66 } }, // bit absolute sets z/v

        .{ .opcode = 0xc9, .operand = &.{0x40}, .setup = .{ .a = 0x40 }, .want = .{ .a = 0x40, .flags = 0x27 } }, // cmp immediate equal
        .{ .opcode = 0xc5, .operand = &.{0x80}, .setup = .{ .a = 0x20, .read = .{ .addr = 0x0080, .value = 0x40 } }, .want = .{ .a = 0x20, .flags = 0xa4 } }, // cmp zero page less
        .{ .opcode = 0xd5, .operand = &.{0x80}, .setup = .{ .a = 0x50, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x40 } }, .want = .{ .flags = 0x25 } }, // cmp zero page,x greater
        .{ .opcode = 0xcd, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x40, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .a = 0x40, .flags = 0x27 } }, // cmp absolute equal
        .{ .opcode = 0xdd, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0x50, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .flags = 0x25 } }, // cmp absolute,x
        .{ .opcode = 0xd9, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0x20, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x40 } }, .want = .{ .flags = 0xa4 } }, // cmp absolute,y page-cross
        .{ .opcode = 0xc1, .operand = &.{0x80}, .setup = .{ .a = 0x40, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x40 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .flags = 0x27 } }, // cmp (indirect,x)
        .{ .opcode = 0xd1, .operand = &.{0x80}, .setup = .{ .a = 0x50, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x40 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .flags = 0x25 } }, // cmp (indirect),y

        .{ .opcode = 0xe0, .operand = &.{0x40}, .setup = .{ .x = 0x40 }, .want = .{ .x = 0x40, .flags = 0x27 } }, // cpx immediate equal
        .{ .opcode = 0xe4, .operand = &.{0x80}, .setup = .{ .x = 0x20, .read = .{ .addr = 0x0080, .value = 0x40 } }, .want = .{ .x = 0x20, .flags = 0xa4 } }, // cpx zero page less
        .{ .opcode = 0xec, .operand = &.{ 0x34, 0x12 }, .setup = .{ .x = 0x50, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .x = 0x50, .flags = 0x25 } }, // cpx absolute greater
        .{ .opcode = 0xc0, .operand = &.{0x40}, .setup = .{ .y = 0x40 }, .want = .{ .y = 0x40, .flags = 0x27 } }, // cpy immediate equal
        .{ .opcode = 0xc4, .operand = &.{0x80}, .setup = .{ .y = 0x20, .read = .{ .addr = 0x0080, .value = 0x40 } }, .want = .{ .y = 0x20, .flags = 0xa4 } }, // cpy zero page less
        .{ .opcode = 0xcc, .operand = &.{ 0x34, 0x12 }, .setup = .{ .y = 0x50, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .y = 0x50, .flags = 0x25 } }, // cpy absolute greater

        .{ .opcode = 0x90, .operand = &.{0x04}, .setup = .{ .flags = 0x24 }, .want = .{ .flags = 0x24, .pc = testPc + 6 } }, // bcc taken forward
        .{ .opcode = 0x90, .operand = &.{0x04}, .setup = .{ .flags = 0x25 }, .want = .{ .flags = 0x25 } }, // bcc not taken
        .{ .opcode = 0xb0, .operand = &.{0x04}, .setup = .{ .flags = 0x25 }, .want = .{ .flags = 0x25, .pc = testPc + 6 } }, // bcs taken
        .{ .opcode = 0xf0, .operand = &.{0x04}, .setup = .{ .flags = 0x26 }, .want = .{ .flags = 0x26, .pc = testPc + 6 } }, // beq taken
        .{ .opcode = 0xd0, .operand = &.{0x04}, .setup = .{ .flags = 0x24 }, .want = .{ .flags = 0x24, .pc = testPc + 6 } }, // bne taken
        .{ .opcode = 0x10, .operand = &.{0x04}, .setup = .{ .flags = 0x24 }, .want = .{ .flags = 0x24, .pc = testPc + 6 } }, // bpl taken
        .{ .opcode = 0x30, .operand = &.{0x04}, .setup = .{ .flags = 0xa4 }, .want = .{ .flags = 0xa4, .pc = testPc + 6 } }, // bmi taken
        .{ .opcode = 0x50, .operand = &.{0x04}, .setup = .{ .flags = 0x24 }, .want = .{ .flags = 0x24, .pc = testPc + 6 } }, // bvc taken
        .{ .opcode = 0x70, .operand = &.{0x04}, .setup = .{ .flags = 0x64 }, .want = .{ .flags = 0x64, .pc = testPc + 6 } }, // bvs taken
        .{ .opcode = 0xd0, .operand = &.{0xfc}, .setup = .{ .flags = 0x24 }, .want = .{ .flags = 0x24, .pc = testPc - 2 } }, // bne taken backward

        .{ .opcode = 0x4c, .operand = &.{ 0x34, 0x12 }, .want = .{ .pc = 0x1234 } }, // jmp absolute
        .{ .opcode = 0x6c, .operand = &.{ 0x34, 0x12 }, .setup = .{ .addrPtr = .{ .addr = 0x1234 } }, .want = .{ .pc = 0xabcd } }, // jmp indirect
        .{ .opcode = 0x6c, .operand = &.{ 0xff, 0x13 }, .setup = .{ .addrPtr = .{ .addr = 0x13ff } }, .want = .{ .pc = 0xabcd } }, // jmp indirect wraps pointer high byte

        .{ .opcode = 0x85, .operand = &.{0x80}, .setup = .{ .a = 0x42 }, .want = .{ .a = 0x42, .mem = .{ .addr = 0x0080, .value = 0x42 } } }, // sta zero page
        .{ .opcode = 0x86, .operand = &.{0x80}, .setup = .{ .x = 0x43 }, .want = .{ .x = 0x43, .mem = .{ .addr = 0x0080, .value = 0x43 } } }, // stx zero page
        .{ .opcode = 0x84, .operand = &.{0x80}, .setup = .{ .y = 0x44 }, .want = .{ .y = 0x44, .mem = .{ .addr = 0x0080, .value = 0x44 } } }, // sty zero page
        .{ .opcode = 0x95, .operand = &.{0x80}, .setup = .{ .a = 0x45, .x = 0x04 }, .want = .{ .a = 0x45, .x = 0x04, .mem = .{ .addr = 0x0084, .value = 0x45 } } }, // sta zero page,x
        .{ .opcode = 0x96, .operand = &.{0x80}, .setup = .{ .x = 0x46, .y = 0x04 }, .want = .{ .x = 0x46, .y = 0x04, .mem = .{ .addr = 0x0084, .value = 0x46 } } }, // stx zero page,y
        .{ .opcode = 0x94, .operand = &.{0x80}, .setup = .{ .x = 0x04, .y = 0x47 }, .want = .{ .x = 0x04, .y = 0x47, .mem = .{ .addr = 0x0084, .value = 0x47 } } }, // sty zero page,x
        .{ .opcode = 0x95, .operand = &.{0xff}, .setup = .{ .a = 0x48, .x = 0x01 }, .want = .{ .a = 0x48, .x = 0x01, .mem = .{ .addr = 0x0000, .value = 0x48 } } }, // sta zero page,x wraps
        .{ .opcode = 0x8d, .operand = &.{ 0x00, 0x03 }, .setup = .{ .a = 0x49 }, .want = .{ .a = 0x49, .mem = .{ .addr = 0x0300, .value = 0x49 } } }, // sta absolute
        .{ .opcode = 0x8e, .operand = &.{ 0x00, 0x03 }, .setup = .{ .x = 0x4a }, .want = .{ .x = 0x4a, .mem = .{ .addr = 0x0300, .value = 0x4a } } }, // stx absolute
        .{ .opcode = 0x8c, .operand = &.{ 0x00, 0x03 }, .setup = .{ .y = 0x4b }, .want = .{ .y = 0x4b, .mem = .{ .addr = 0x0300, .value = 0x4b } } }, // sty absolute
        .{ .opcode = 0x81, .operand = &.{0x80}, .setup = .{ .a = 0x4c, .x = 0x04, .ptr = .{ .addr = 0x84, .value = 0x0300 } }, .want = .{ .a = 0x4c, .x = 0x04, .mem = .{ .addr = 0x0300, .value = 0x4c } } }, // sta (indirect,x)
        .{ .opcode = 0x91, .operand = &.{0x80}, .setup = .{ .a = 0x4d, .y = 0x04, .ptr = .{ .addr = 0x80, .value = 0x0300 } }, .want = .{ .a = 0x4d, .y = 0x04, .mem = .{ .addr = 0x0304, .value = 0x4d } } }, // sta (indirect),y
        .{ .opcode = 0x99, .operand = &.{ 0x00, 0x03 }, .setup = .{ .a = 0x4e, .y = 0x04 }, .want = .{ .a = 0x4e, .y = 0x04, .mem = .{ .addr = 0x0304, .value = 0x4e } } }, // sta absolute,y
        .{ .opcode = 0x9d, .operand = &.{ 0x00, 0x03 }, .setup = .{ .a = 0x4f, .x = 0x04 }, .want = .{ .a = 0x4f, .x = 0x04, .mem = .{ .addr = 0x0304, .value = 0x4f } } }, // sta absolute,x
    };

    for (testCases, 0..) |case, caseIndex| {
        errdefer std.debug.print("failed instruction case {d}: opcode 0x{x:0>2}\n", .{ caseIndex, case.opcode });
        var system: System = .{ .mapper = mapper.fromData(&[_]u8{0} ** 0x4000) };

        system.cpu.pc = testPc;
        system.cpu.a = case.setup.a;
        system.cpu.x = case.setup.x;
        system.cpu.y = case.setup.y;
        system.cpu.sp = case.setup.sp;
        system.cpu.flags = cpu.Flags.fromByte(case.setup.flags);
        system.busWrite(testPc, case.opcode);

        for (case.operand, 0..) |byte, index| {
            system.busWrite(testPc + @as(u16, @intCast(1 + index)), byte);
        }
        if (case.setup.ptr) |ptr| {
            system.busWrite(ptr.addr, @truncate(ptr.value));
            system.busWrite(ptr.addr +% 1, @truncate(ptr.value >> 8));
        }
        if (case.setup.addrPtr) |ptr| {
            system.busWrite(ptr.addr, @truncate(ptr.value));
            system.busWrite((ptr.addr & 0xff00) | ((ptr.addr +% 1) & 0x00ff), @truncate(ptr.value >> 8));
        }
        if (case.setup.read) |read| system.busWrite(read.addr, read.value);

        system.runInstruction();

        try testing.expectEqual(case.want.a orelse case.setup.a, system.cpu.a);
        try testing.expectEqual(case.want.x orelse case.setup.x, system.cpu.x);
        try testing.expectEqual(case.want.y orelse case.setup.y, system.cpu.y);
        try testing.expectEqual(case.want.sp orelse case.setup.sp, system.cpu.sp);
        try testing.expectEqual(case.want.flags orelse case.setup.flags, system.cpu.flags.toByte());
        if (case.want.mem) |mem| {
            try testing.expectEqual(mem.value, system.busRead(mem.addr));
        }
        const wantPc = case.want.pc orelse testPc + @as(u16, @intCast(1 + case.operand.len));
        try testing.expectEqual(wantPc, system.cpu.pc);
    }
}

test "system writes/reads internal ram" {
    var system: System = .{ .mapper = mapper.fromData(&[_]u8{0} ** 0x4000) };

    system.busWrite(0xff, 0xff);
    try testing.expectEqual(0, system.cpu.pc);
    try testing.expectEqual(0xff, system.busRead(0xff));
}

test "system mirrors internal ram" {
    const cases = [_]struct {
        addr: u16,
        value: u8,
    }{
        .{ .addr = 0, .value = 1 },
        .{ .addr = 1, .value = 2 },
        .{ .addr = 2, .value = 3 },
        .{ .addr = 4, .value = 4 },
    };

    for (cases) |case| {
        var system: System = .{ .mapper = mapper.fromData(&[_]u8{0} ** 0x4000) };
        system.busWrite(case.addr, case.value);
        for ([_]u16{ 0, 0x800, 0x1000, 0x1800 }) |mirror| {
            try testing.expectEqual(case.value, system.busRead(mirror + case.addr));
        }
    }
}
