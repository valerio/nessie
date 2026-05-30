const std = @import("std");
const dmc_mod = @import("dmc.zig");

const Dmc = dmc_mod.Dmc;

const apuStepQuarter1 = 7_457;
const apuStepHalf2 = 14_913;
const apuStepQuarter3 = 22_371;
const apuMode0IrqStart = 29_828;
const apuMode0Clock = 29_829;
const apuMode1Clock = 37_281;

const nesCpuClock = 1_789_773;
const hostSampleRate = 44_100;

const lengthTable = [_]u8{
    10,  254, 20, 2,  40, 4,  80, 6,
    160, 8,   60, 10, 14, 12, 26, 14,
    12,  16,  24, 18, 48, 20, 96, 22,
    192, 24,  72, 26, 16, 28, 32, 30,
};

const dutyTable = [_]u8{
    0, 1, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 0, 0, 0,
    1, 0, 0, 1, 1, 1, 1, 1,
};

const triangleSequence = [_]u8{
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5,  4,  3,  2,  1,  0,
    0,  1,  2,  3,  4,  5,  6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

const noisePeriodTable = [_]u16{
    4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068,
};

const minPulseTimerPeriod = 8;
const maxSweepTarget = 0x7ff;
const dutySteps = 8;
const envelopeDecayMax = 15;

const statusPulse1: u8 = 0x01;
const statusPulse2: u8 = 0x02;
const statusTriangle: u8 = 0x04;
const statusNoise: u8 = 0x08;
const statusDmc: u8 = 0x10;
const statusOpenBus: u8 = 0x20;
const statusFrameIrq: u8 = 0x40;
const statusDmcIrq: u8 = 0x80;

const PulseChannel = enum(u1) {
    pulse1 = 0,
    pulse2 = 1,
};

const Pulse = struct {
    channel: PulseChannel = .pulse1,

    enabled: bool = false,
    lengthCounter: u8 = 0,
    lengthHalt: bool = false,

    duty: u2 = 0,
    dutyPos: u3 = 0,
    timerPeriod: u11 = 0,
    timerValue: u11 = 0,

    constantVolume: bool = false,
    volumeParam: u4 = 0,
    envelopeStart: bool = false,
    envelopeDivider: u4 = 0,
    envelopeDecay: u4 = 0,

    sweepEnabled: bool = false,
    sweepPeriod: u3 = 0,
    sweepNegate: bool = false,
    sweepShift: u3 = 0,
    sweepDivider: u3 = 0,
    sweepReload: bool = false,

    pub fn writeReg(self: *Pulse, reg: u2, value: u8) void {
        switch (reg) {
            0 => {
                self.duty = @truncate(value >> 6);
                self.lengthHalt = (value & 0x20) != 0;
                self.constantVolume = (value & 0x10) != 0;
                self.volumeParam = @truncate(value & 0x0f);
            },
            1 => {
                self.sweepEnabled = (value & 0x80) != 0;
                self.sweepPeriod = @truncate((value >> 4) & 0x07);
                self.sweepNegate = (value & 0x08) != 0;
                self.sweepShift = @truncate(value & 0x07);
                self.sweepReload = true;
            },
            2 => self.timerPeriod = (self.timerPeriod & 0x700) | @as(u11, value),
            3 => {
                if (self.enabled) self.lengthCounter = lengthTable[value >> 3];
                self.timerPeriod = (self.timerPeriod & 0x0ff) | (@as(u11, value & 0x07) << 8);
                self.envelopeStart = true;
                self.dutyPos = 0;
            },
        }
    }

    pub fn tickTimer(self: *Pulse) void {
        if (self.timerValue == 0) {
            self.timerValue = self.timerPeriod;
            self.dutyPos = @truncate((@as(u4, self.dutyPos) + 1) % dutySteps);
        } else {
            self.timerValue -= 1;
        }
    }

    pub fn tickSweep(self: *Pulse) void {
        const target = self.sweepTarget();
        const muting = isSweepMuting(self.timerPeriod, target);

        if (self.sweepDivider == 0 and self.sweepEnabled and self.sweepShift > 0 and !muting) {
            self.timerPeriod = @intCast(target);
        }
        if (self.sweepDivider == 0 or self.sweepReload) {
            self.sweepDivider = self.sweepPeriod;
            self.sweepReload = false;
        } else {
            self.sweepDivider -= 1;
        }
    }

    pub fn tickLength(self: *Pulse) void {
        if (!self.lengthHalt and self.lengthCounter > 0) self.lengthCounter -= 1;
    }

    pub fn output(self: *const Pulse) u8 {
        const target = self.sweepTarget();
        if (self.lengthCounter == 0 or
            dutyTable[(@as(usize, self.duty) << 3) | self.dutyPos] == 0 or
            isSweepMuting(self.timerPeriod, target))
        {
            return 0;
        }
        return if (self.constantVolume) self.volumeParam else self.envelopeDecay;
    }

    fn sweepTarget(self: *const Pulse) u12 {
        const delta: u11 = self.timerPeriod >> self.sweepShift;
        if (self.sweepNegate) {
            return switch (self.channel) {
                .pulse1 => @as(u12, self.timerPeriod) -| @as(u12, delta) -| 1,
                .pulse2 => @as(u12, self.timerPeriod) -| @as(u12, delta),
            };
        }
        return @as(u12, self.timerPeriod) + @as(u12, delta);
    }

    fn isSweepMuting(period: u11, target: u12) bool {
        return period < minPulseTimerPeriod or target > maxSweepTarget;
    }
};

const Triangle = struct {
    enabled: bool = false,
    lengthCounter: u8 = 0,
    lengthHalt: bool = false,

    timerPeriod: u11 = 0,
    timerValue: u11 = 0,
    sequencePos: u5 = 0,

    linearReload: u7 = 0,
    linearCounter: u7 = 0,
    linearReloadFlag: bool = false,

    pub fn writeReg(self: *Triangle, reg: u2, value: u8) void {
        switch (reg) {
            0 => {
                self.lengthHalt = (value & 0x80) != 0;
                self.linearReload = @truncate(value & 0x7f);
            },
            1 => {},
            2 => self.timerPeriod = (self.timerPeriod & 0x700) | @as(u11, value),
            3 => {
                self.timerPeriod = (self.timerPeriod & 0x00ff) | (@as(u11, value & 0x07) << 8);
                if (self.enabled) self.lengthCounter = lengthTable[value >> 3];
                self.linearReloadFlag = true;
            },
        }
    }

    pub fn tickTimer(self: *Triangle) void {
        if (self.timerValue == 0) {
            self.timerValue = self.timerPeriod;
            self.sequencePos +%= 1;
        } else {
            self.timerValue -= 1;
        }
    }

    pub fn tickLinearCounter(self: *Triangle) void {
        if (self.linearReloadFlag) {
            self.linearCounter = self.linearReload;
        } else if (self.linearCounter > 0) {
            self.linearCounter -= 1;
        }
        if (!self.lengthHalt) self.linearReloadFlag = false;
    }

    pub fn tickLength(self: *Triangle) void {
        if (!self.lengthHalt and self.lengthCounter > 0) self.lengthCounter -= 1;
    }

    pub fn output(self: *const Triangle) u8 {
        if (self.lengthCounter == 0 or self.linearCounter == 0 or self.timerPeriod < 2) return 0;
        return triangleSequence[self.sequencePos];
    }
};

const Noise = struct {
    enabled: bool = false,
    lengthCounter: u8 = 0,
    lengthHalt: bool = false,

    shortMode: bool = false,
    timerPeriod: u16 = noisePeriodTable[0],
    timerValue: u16 = 0,
    lfsr: u15 = 1,

    constantVolume: bool = false,
    volumeParam: u4 = 0,
    envelopeStart: bool = false,
    envelopeDivider: u4 = 0,
    envelopeDecay: u4 = 0,

    pub fn writeReg(self: *Noise, reg: u2, value: u8) void {
        switch (reg) {
            0 => {
                self.lengthHalt = (value & 0x20) != 0;
                self.constantVolume = (value & 0x10) != 0;
                self.volumeParam = @truncate(value & 0x0f);
            },
            1 => {},
            2 => {
                self.shortMode = (value & 0x80) != 0;
                self.timerPeriod = noisePeriodTable[value & 0x0f];
            },
            3 => {
                if (self.enabled) self.lengthCounter = lengthTable[value >> 3];
                self.envelopeStart = true;
            },
        }
    }

    pub fn tickTimer(self: *Noise) void {
        if (self.timerValue > 0) {
            self.timerValue -= 1;
            return;
        }

        self.timerValue = self.timerPeriod - 1;
        const bit0 = self.lfsr & 1;
        const otherBit = if (self.shortMode) (self.lfsr >> 6) & 1 else (self.lfsr >> 1) & 1;
        const feedback = bit0 ^ otherBit;
        self.lfsr = @truncate((@as(u16, self.lfsr) >> 1) | (@as(u16, feedback) << 14));
    }

    pub fn tickLength(self: *Noise) void {
        if (!self.lengthHalt and self.lengthCounter > 0) self.lengthCounter -= 1;
    }

    pub fn output(self: *const Noise) u8 {
        if (self.lengthCounter == 0 or (self.lfsr & 1) != 0) return 0;
        return if (self.constantVolume) self.volumeParam else self.envelopeDecay;
    }
};

const Filter = struct {
    kind: Kind = .lowPass,
    alpha: f32 = 0,
    prevIn: f32 = 0,
    prevOut: f32 = 0,

    const Kind = enum { highPass, lowPass };

    fn highPass(sample_rate: f32, cutoff: f32) Filter {
        const rc = 1.0 / (2.0 * std.math.pi * cutoff);
        const dt = 1.0 / sample_rate;
        return .{ .kind = .highPass, .alpha = rc / (rc + dt) };
    }

    fn lowPass(sample_rate: f32, cutoff: f32) Filter {
        const rc = 1.0 / (2.0 * std.math.pi * cutoff);
        const dt = 1.0 / sample_rate;
        return .{ .kind = .lowPass, .alpha = dt / (rc + dt) };
    }

    fn apply(self: *Filter, sample: f32) f32 {
        switch (self.kind) {
            .highPass => {
                const out = self.alpha * (self.prevOut + sample - self.prevIn);
                self.prevIn = sample;
                self.prevOut = out;
                return out;
            },
            .lowPass => {
                const out = self.prevOut + self.alpha * (sample - self.prevOut);
                self.prevOut = out;
                return out;
            },
        }
    }
};

pub const Apu = struct {
    pulse1: Pulse = .{ .channel = .pulse1 },
    pulse2: Pulse = .{ .channel = .pulse2 },
    triangle: Triangle = .{},
    noise: Noise = .{},
    dmc: Dmc = .{},

    cycles: u64 = 0,
    frameCounter: u16 = 0,
    frameMode5Step: bool = false,
    frameIrqInhibit: bool = false,
    frameIrqPending: bool = false,
    frameIrqCarry: bool = false,
    frameIrqBit6Visible: bool = false,
    pendingFrameMode5Step: bool = false,
    pendingFrameIrqInhibit: bool = false,
    frameResetDelay: ?u8 = null,

    sampleClock: u32 = 0,
    audioPhase: u1 = 0,
    lastSample: f32 = 0,
    hp1: Filter = Filter.highPass(hostSampleRate, 37),
    hp2: Filter = Filter.highPass(hostSampleRate, 440),
    lp: Filter = Filter.lowPass(hostSampleRate, 14_000),

    pub fn tickChannelTimers(self: *Apu, is_get_cycle: bool) void {
        self.triangle.tickTimer();
        self.dmc.tickTimer(is_get_cycle);
    }

    pub fn tickTimers(self: *Apu, is_get_cycle: bool) void {
        self.triangle.tickTimer();
        self.dmc.tickTimer(is_get_cycle);
        self.stepFrameCounter();
    }

    pub fn tickFrameCounter(self: *Apu) void {
        self.dmc.tickVisibleConflict();
        self.stepFrameCounter();
    }

    pub fn tickAudio(self: *Apu, cpu_cycles: u32) void {
        // TODO wire samples to the frontend audio sink instead of only retaining lastSample.
        for (0..cpu_cycles) |_| {
            if (self.audioPhase == 0) {
                self.pulse1.tickTimer();
                self.pulse2.tickTimer();
                self.noise.tickTimer();
            }
            self.sampleAudio();
            self.audioPhase +%= 1;
        }
    }

    fn sampleAudio(self: *Apu) void {
        self.sampleClock += hostSampleRate;
        if (self.sampleClock < nesCpuClock) return;
        self.sampleClock -= nesCpuClock;

        const mixed = mix(
            self.pulse1.output(),
            self.pulse2.output(),
            self.triangle.output(),
            self.noise.output(),
            self.dmc.outputLevel,
        );
        self.lastSample = self.lp.apply(self.hp2.apply(self.hp1.apply(mixed)));
    }

    fn stepFrameCounter(self: *Apu) void {
        defer self.cycles += 1;

        if (self.frameIrqBit6Visible and (self.cycles & 1) == 1) {
            self.frameIrqBit6Visible = false;
        }

        if (self.frameResetDelay) |*delay| {
            if (delay.* > 0) delay.* -= 1;
            if (delay.* == 0) {
                self.frameResetDelay = null;
                self.applyFrameReset();
                return;
            }
        }

        if (self.frameIrqCarry) {
            self.frameIrqCarry = false;
            if (!self.frameMode5Step and !self.frameIrqInhibit) {
                self.frameIrqBit6Visible = true;
                self.frameIrqPending = true;
            }
        }

        switch (self.frameCounter) {
            apuStepQuarter1, apuStepQuarter3 => self.clockQuarterFrame(),
            apuStepHalf2 => {
                self.clockQuarterFrame();
                self.clockHalfFrame();
            },
            apuMode0IrqStart => if (!self.frameMode5Step) {
                self.frameIrqBit6Visible = true;
                if (!self.frameIrqInhibit) self.frameIrqPending = true;
            },
            apuMode0Clock => if (!self.frameMode5Step) {
                self.frameIrqBit6Visible = true;
                if (!self.frameIrqInhibit) self.frameIrqPending = true;
                self.clockQuarterFrame();
                self.clockHalfFrame();
                self.frameIrqCarry = true;
                self.frameCounter = 0;
                return;
            },
            apuMode1Clock => if (self.frameMode5Step) {
                self.clockQuarterFrame();
                self.clockHalfFrame();
                self.frameCounter = 0;
                return;
            },
            else => {},
        }

        self.frameCounter += 1;
    }

    pub fn readStatus(self: *Apu, last_bus_value: u8) u8 {
        var status = last_bus_value & statusOpenBus;
        if (self.pulse1.lengthCounter > 0) status |= statusPulse1;
        if (self.pulse2.lengthCounter > 0) status |= statusPulse2;
        if (self.triangle.lengthCounter > 0) status |= statusTriangle;
        if (self.noise.lengthCounter > 0) status |= statusNoise;
        if (self.dmc.enabled and self.dmc.bytesRemaining > 0) status |= statusDmc;
        if (self.frameIrqPending or self.frameIrqBit6Visible) status |= statusFrameIrq;
        if (self.dmc.irqFlag) status |= statusDmcIrq;

        if (self.frameIrqPending) self.frameIrqBit6Visible = true;
        self.frameIrqPending = false;
        return status;
    }

    pub fn writeStatus(self: *Apu, value: u8, is_get_cycle: bool) void {
        self.pulse1.enabled = (value & statusPulse1) != 0;
        if (!self.pulse1.enabled) self.pulse1.lengthCounter = 0;

        self.pulse2.enabled = (value & statusPulse2) != 0;
        if (!self.pulse2.enabled) self.pulse2.lengthCounter = 0;

        self.triangle.enabled = (value & statusTriangle) != 0;
        if (!self.triangle.enabled) self.triangle.lengthCounter = 0;

        self.noise.enabled = (value & statusNoise) != 0;
        if (!self.noise.enabled) self.noise.lengthCounter = 0;

        self.dmc.irqFlag = false;
        if ((value & statusDmc) != 0) self.dmc.enable(is_get_cycle) else self.dmc.disable(is_get_cycle);
    }

    pub fn writeRegister(self: *Apu, addr: u16, value: u8) void {
        switch (addr) {
            0x4010...0x4013 => self.dmc.writeReg(@truncate(addr & 0x0003), value),
            0x4000...0x4003 => self.pulse1.writeReg(@truncate(addr & 0x0003), value),
            0x4004...0x4007 => self.pulse2.writeReg(@truncate(addr & 0x0003), value),
            0x4008...0x400b => self.triangle.writeReg(@truncate(addr & 0x0003), value),
            0x400c...0x400f => self.noise.writeReg(@truncate(addr & 0x0003), value),
            else => {},
        }
    }

    pub fn writeFrameCounter(self: *Apu, value: u8) void {
        const irqInhibit = (value & 0x40) != 0;
        if (irqInhibit) {
            self.frameIrqPending = false;
            self.frameIrqBit6Visible = false;
        }

        self.frameIrqInhibit = irqInhibit;
        self.pendingFrameMode5Step = (value & 0x80) != 0;
        self.pendingFrameIrqInhibit = irqInhibit;
        self.frameResetDelay = if ((self.cycles & 1) == 1) 2 else 3;
    }

    fn clockQuarterFrame(self: *Apu) void {
        tickEnvelopeStep(&self.pulse1);
        tickEnvelopeStep(&self.pulse2);
        self.triangle.tickLinearCounter();
        tickEnvelopeStep(&self.noise);
    }

    fn clockHalfFrame(self: *Apu) void {
        self.pulse1.tickLength();
        self.pulse1.tickSweep();
        self.pulse2.tickLength();
        self.pulse2.tickSweep();
        self.triangle.tickLength();
        self.noise.tickLength();
    }

    fn applyFrameReset(self: *Apu) void {
        self.frameMode5Step = self.pendingFrameMode5Step;
        self.frameIrqInhibit = self.pendingFrameIrqInhibit;
        if (self.frameIrqInhibit) {
            self.frameIrqPending = false;
            self.frameIrqBit6Visible = false;
        }
        self.frameCounter = 0;
        if (self.frameMode5Step) {
            self.clockQuarterFrame();
            self.clockHalfFrame();
        }
    }
};

fn tickEnvelopeStep(s: anytype) void {
    if (s.envelopeStart) {
        s.envelopeStart = false;
        s.envelopeDecay = envelopeDecayMax;
        s.envelopeDivider = s.volumeParam;
        return;
    }

    if (s.envelopeDivider > 0) {
        s.envelopeDivider -= 1;
        return;
    }

    s.envelopeDivider = s.volumeParam;
    if (s.envelopeDecay > 0) {
        s.envelopeDecay -= 1;
    } else if (s.lengthHalt) {
        s.envelopeDecay = envelopeDecayMax;
    }
}

fn mix(pulse1: u8, pulse2: u8, triangle: u8, noise: u8, dmc: u8) f32 {
    const pulseIndex = @as(usize, pulse1) + pulse2;
    const tndIndex = 3 * @as(usize, triangle) + 2 * @as(usize, noise) + dmc;
    const pulseOut = if (pulseIndex == 0) 0 else 95.52 / (8128.0 / @as(f32, @floatFromInt(pulseIndex)) + 100.0);
    const tndOut = if (tndIndex == 0) 0 else 163.67 / (24329.0 / @as(f32, @floatFromInt(tndIndex)) + 100.0);
    return pulseOut + tndOut;
}
