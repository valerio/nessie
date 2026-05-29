const std = @import("std");

const rateTable = [_]u16{ 428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54 };

const sampleAddressBase = 0xc000;
const sampleAddressWrapMin = 0x8000;
const sampleAddressWrapMax = 0xffff;
const outputMax = 127;
const outputStep = 2;
const bitsPerByte = 8;

pub const BusOp = enum {
    read,
    write,
    idle,
};

pub const PhantomPhase = enum {
    halt,
    dummy,
    alignPhase,
};

pub const DmaStep = union(enum) {
    none,
    wait,
    phantom: PhantomPhase,
    sample: u16,
};

pub const Kind = enum(u8) {
    idle = 0,
    reloadScheduled = 1,
    beforeScheduleDisable = 2,
    explicitAbortWindow = 3,
    implicitAbortWindow = 4,
    implicitAbortPending = 5,
    reloadScheduledAbortPending = 6,
    implicitAbortWindowAbortPending = 7,

    pendingLoad = 8,
    pendingLoadAfterDisable = 9,
    pendingLoadAfterImplicitAbort = 10,

    pendingReloadWaitStatus = 11,
    pendingReloadAlignTarget = 12,
    pendingReloadWaitHalt = 13,
    pendingReloadImplicitAbortWaitStatus = 14,
    pendingReloadImplicitAbortAlignTarget = 15,
    pendingReloadImplicitAbortWaitHalt = 16,
    pendingReloadAbortedWaitStatus = 17,
    pendingReloadAbortedAlignTarget = 18,
    pendingReloadAbortedWaitHalt = 19,
    pendingReloadAlignWaitStatus = 20,
    pendingReloadAlignAlignTarget = 21,
    pendingReloadAlignWaitHalt = 22,

    haltLoad = 23,
    haltReload = 24,
    haltImplicitAbort = 25,
    haltAborted = 26,
    dummyLoad = 27,
    dummyReload = 28,
    alignLoad = 29,
    alignReload = 30,
    read = 31,
};

const DmaState = struct {
    kind: Kind = .idle,
    pendingCycles: u16 = 0,
    cpuWriteDelayParity: u1 = 0,
    sampleAddr: u16 = 0,
};

pub const Dmc = struct {
    // $4010-$4013 register-visible state.
    enabled: bool = false,
    statusEnabled: bool = false,
    statusDelay: u8 = 0,
    irqEnabled: bool = false,
    irqFlag: bool = false,
    loopFlag: bool = false,
    rateIndex: u4 = 0,
    rateValue: u16 = 0,
    outputLevel: u8 = 0,
    sampleAddress: u16 = sampleAddressBase,
    sampleLength: u16 = 1,

    // Reader/output unit state.
    currentAddress: u16 = sampleAddressBase,
    bytesRemaining: u16 = 0,
    sampleBuffer: u8 = 0,
    sampleBufferEmpty: bool = true,
    shiftRegister: u8 = 0,
    bitsRemaining: u8 = 0,
    silenceFlag: bool = true,

    // DMA scheduler state.
    dma: DmaState = .{},
    implicitAbortPending: bool = false,
    cyclesSinceSampleEnd: u16 = std.math.maxInt(u16),
    loadDelay: ?u8 = null,
    reloadDelay: ?u8 = null,

    // CPU/APU register conflict visibility after a DMC sample read.
    conflictSampleAddr: u16 = 0,
    conflictSample: u8 = 0,
    conflictVisibleCpuOpsRemaining: u8 = 0,

    pub fn writeReg(self: *Dmc, reg: u2, value: u8) void {
        switch (reg) {
            0 => {
                self.irqEnabled = (value & 0x80) != 0;
                self.loopFlag = (value & 0x40) != 0;
                self.rateIndex = @truncate(value & 0x0f);
                if (!self.irqEnabled) self.irqFlag = false;
            },
            1 => self.outputLevel = value & 0x7f,
            2 => self.sampleAddress = sampleAddressBase + (@as(u16, value) * 64),
            3 => self.sampleLength = (@as(u16, value) * 16) + 1,
        }
    }

    pub fn enable(self: *Dmc, is_get_cycle: bool) void {
        const restartSampleOnEnable = self.bytesRemaining == 0;
        self.statusDelay = if (is_get_cycle) 4 else 3;

        if (restartSampleOnEnable) {
            self.currentAddress = self.sampleAddress;
            self.bytesRemaining = self.sampleLength;
            self.loadDelay = 2;
            if (self.dma.kind == .explicitAbortWindow) self.dma = .{};
        }

        const rateAligned = (self.rateValue == 70 and !is_get_cycle) or (self.rateValue == 71 and is_get_cycle);
        if (self.sampleBufferEmpty and self.bitsRemaining == 0 and rateAligned) {
            self.implicitAbortPending = true;
            switch (self.dma.kind) {
                .idle => self.dma = .{ .kind = .implicitAbortPending },
                .reloadScheduled => self.dma = .{ .kind = .reloadScheduledAbortPending },
                .implicitAbortWindow => self.dma = .{ .kind = .implicitAbortWindowAbortPending },
                else => {},
            }
        }
        self.enabled = true;
    }

    pub fn disable(self: *Dmc, is_get_cycle: bool) void {
        const kind = self.dma.kind;
        const loadPendAtEntry = self.loadDelay != null;
        const reloadPendAtEntry = self.reloadDelay != null;
        self.statusDelay = if (is_get_cycle) 3 else 2;
        self.loadDelay = null;

        if (@intFromEnum(kind) < @intFromEnum(Kind.pendingLoad) and
            !loadPendAtEntry and
            !reloadPendAtEntry and
            !self.sampleBufferEmpty and
            self.bytesRemaining > 0 and
            self.bitsRemaining == 1 and
            self.rateValue <= 1)
        {
            self.dma = .{ .kind = .explicitAbortWindow };
            self.enabled = false;
            return;
        }

        if (reloadPendAtEntry) {
            self.enabled = false;
            return;
        }

        const isPendReload = @intFromEnum(kind) >= @intFromEnum(Kind.pendingReloadWaitStatus) and
            @intFromEnum(kind) <= @intFromEnum(Kind.pendingReloadAlignWaitHalt);
        const isReloadTransfer = (@intFromEnum(kind) >= @intFromEnum(Kind.haltReload) and
            @intFromEnum(kind) <= @intFromEnum(Kind.haltAborted)) or
            kind == .dummyReload or kind == .alignReload;
        const isReloadMode = isPendReload or isReloadTransfer;

        if (!isReloadMode) {
            if (kind != .read) self.dma = .{ .kind = .beforeScheduleDisable };
            self.enabled = false;
            return;
        }

        if (isWaitHalt(kind) and self.dma.pendingCycles > 0) {
            self.enabled = false;
            return;
        }

        if (toAbortedKind(kind)) |aborted| {
            self.dma.kind = aborted;
            self.enabled = false;
            return;
        }

        if (kind == .haltReload or kind == .haltImplicitAbort) {
            self.dma.kind = .haltAborted;
            self.enabled = false;
            return;
        }

        self.enabled = false;
    }

    pub fn tickTimer(self: *Dmc, is_get_cycle: bool) void {
        self.tickSampleEndAge();
        self.tickLoadDmaTimer(is_get_cycle);
        self.tickReloadDmaTimer();
        self.tickStatusDelay();
        if (self.clockOutputUnit()) self.loadNextOutputByte();
    }

    pub fn tickDma(self: *Dmc, is_get_cycle: bool, op_type: BusOp, in_oam_dma: bool) DmaStep {
        switch (self.dma.kind) {
            .idle,
            .reloadScheduled,
            .beforeScheduleDisable,
            .explicitAbortWindow,
            .implicitAbortWindow,
            .implicitAbortPending,
            .reloadScheduledAbortPending,
            .implicitAbortWindowAbortPending,
            .read,
            => return .none,

            .pendingLoad,
            .pendingLoadAfterDisable,
            .pendingLoadAfterImplicitAbort,
            => return self.tickPendingLoad(is_get_cycle, op_type),

            .pendingReloadWaitStatus,
            .pendingReloadImplicitAbortWaitStatus,
            .pendingReloadAbortedWaitStatus,
            .pendingReloadAlignWaitStatus,
            => return self.tickPendingReloadWaitStatus(op_type),

            .pendingReloadAlignTarget,
            .pendingReloadImplicitAbortAlignTarget,
            .pendingReloadAbortedAlignTarget,
            .pendingReloadAlignAlignTarget,
            => return self.tickPendingReloadAlignTarget(is_get_cycle, op_type),

            .pendingReloadWaitHalt,
            .pendingReloadImplicitAbortWaitHalt,
            .pendingReloadAbortedWaitHalt,
            .pendingReloadAlignWaitHalt,
            => return self.tickPendingReloadWaitHalt(op_type),

            .haltAborted,
            .haltImplicitAbort,
            .haltLoad,
            .haltReload,
            => return self.tickHaltTransfer(),

            .dummyLoad,
            .dummyReload,
            => return self.tickDummyTransfer(is_get_cycle, in_oam_dma),

            .alignLoad,
            .alignReload,
            => return self.tickAlignTransfer(),
        }
    }

    pub fn completeDmaRead(self: *Dmc, byte: u8) void {
        const sampleAddr = self.dma.sampleAddr;
        self.dma = if (self.implicitAbortPending) .{ .kind = .implicitAbortPending } else .{};
        self.conflictSampleAddr = sampleAddr;
        self.conflictSample = byte;
        self.conflictVisibleCpuOpsRemaining = 1;
        self.sampleBuffer = byte;
        self.sampleBufferEmpty = false;
        self.currentAddress = if (self.currentAddress >= sampleAddressWrapMax) sampleAddressWrapMin else self.currentAddress + 1;

        var sampleEnded = false;
        if (self.bytesRemaining > 0) {
            self.bytesRemaining -= 1;
            sampleEnded = self.bytesRemaining == 0;
        }
        if (sampleEnded) {
            self.cyclesSinceSampleEnd = 0;
            if (self.loopFlag) {
                self.currentAddress = self.sampleAddress;
                self.bytesRemaining = self.sampleLength;
            } else if (self.irqEnabled) {
                self.irqFlag = true;
            }
        }
    }

    pub fn tickVisibleConflict(self: *Dmc) void {
        if (self.conflictVisibleCpuOpsRemaining > 0) self.conflictVisibleCpuOpsRemaining -= 1;
    }

    fn tickPendingLoad(self: *Dmc, is_get_cycle: bool, op_type: BusOp) DmaStep {
        if (!self.enabled and !self.statusEnabled) {
            self.dma = .{};
            return .none;
        }
        if (self.dma.pendingCycles == 0 and !is_get_cycle) {
            self.dma.pendingCycles += 1;
            return .wait;
        }
        if (op_type == .write) {
            self.dma.pendingCycles += 1;
            return .wait;
        }
        self.dma.kind = .haltLoad;
        return .{ .phantom = .halt };
    }

    fn tickPendingReloadWaitHalt(self: *Dmc, op_type: BusOp) DmaStep {
        if (op_type == .write) {
            const abortable = self.dma.kind == .pendingReloadAbortedWaitHalt or
                self.dma.kind == .pendingReloadImplicitAbortWaitHalt;
            if (abortable) {
                self.dma = .{};
                return .none;
            }
            self.dma.cpuWriteDelayParity = @truncate(self.dma.cpuWriteDelayParity ^ 1);
            self.dma.pendingCycles += 1;
            return .wait;
        }

        switch (self.dma.kind) {
            .pendingReloadWaitHalt, .pendingReloadAlignWaitHalt => {
                self.dma.kind = .haltReload;
                return .{ .phantom = .halt };
            },
            .pendingReloadImplicitAbortWaitHalt => {
                self.dma.kind = .haltImplicitAbort;
                return .{ .phantom = .halt };
            },
            .pendingReloadAbortedWaitHalt => {
                self.dma.kind = .haltAborted;
                return .{ .phantom = .halt };
            },
            else => unreachable,
        }
    }

    fn advanceToWaitHalt(self: *Dmc, pending_cycles: u16) void {
        self.dma.kind = toWaitHaltKind(self.dma.kind);
        self.dma.pendingCycles = pending_cycles;
    }

    fn tickPendingReloadWaitStatus(self: *Dmc, op_type: BusOp) DmaStep {
        if (self.enabled and !self.statusEnabled) {
            self.dma.pendingCycles += 1;
            return .wait;
        }
        self.advanceToWaitHalt(self.dma.pendingCycles);
        return self.tickPendingReloadWaitHalt(op_type);
    }

    fn tickPendingReloadAlignTarget(self: *Dmc, is_get_cycle: bool, op_type: BusOp) DmaStep {
        if (is_get_cycle) {
            const pendingCycles = self.dma.pendingCycles + 1;
            self.advanceToWaitHalt(pendingCycles);
            return .wait;
        }
        self.advanceToWaitHalt(self.dma.pendingCycles);
        return self.tickPendingReloadWaitHalt(op_type);
    }

    fn tickHaltTransfer(self: *Dmc) DmaStep {
        switch (self.dma.kind) {
            .haltAborted => {
                self.dma = .{};
                return .none;
            },
            .haltImplicitAbort => {
                if (self.bytesRemaining == 0) {
                    self.dma = .{};
                    return .none;
                }
                self.dma.kind = .dummyReload;
                return .{ .phantom = .dummy };
            },
            .haltLoad => {
                if (!self.enabled and !self.statusEnabled) {
                    self.dma = .{};
                    return .none;
                }
                self.dma.kind = .dummyLoad;
                return .{ .phantom = .dummy };
            },
            .haltReload => {
                self.dma.kind = .dummyReload;
                return .{ .phantom = .dummy };
            },
            else => unreachable,
        }
    }

    fn tickDummyTransfer(self: *Dmc, is_get_cycle: bool, in_oam_dma: bool) DmaStep {
        switch (self.dma.kind) {
            .dummyLoad => {
                if (!self.enabled and !self.statusEnabled) {
                    self.dma = .{};
                    return .none;
                }
                if (is_get_cycle) {
                    self.dma.kind = .read;
                    return .{ .sample = self.dma.sampleAddr };
                }
                self.dma.kind = .alignLoad;
                return .{ .phantom = .alignPhase };
            },
            .dummyReload => {
                const skipAlign = self.dma.cpuWriteDelayParity == 1 and !in_oam_dma;
                if (!in_oam_dma and (is_get_cycle or skipAlign)) {
                    self.dma.kind = .read;
                    return .{ .sample = self.dma.sampleAddr };
                }
                self.dma.kind = .alignReload;
                return .{ .phantom = .alignPhase };
            },
            else => unreachable,
        }
    }

    fn tickAlignTransfer(self: *Dmc) DmaStep {
        switch (self.dma.kind) {
            .alignLoad => {
                if (!self.enabled and !self.statusEnabled) {
                    self.dma = .{};
                    return .none;
                }
                self.dma.kind = .read;
                return .{ .sample = self.dma.sampleAddr };
            },
            .alignReload => {
                self.dma.kind = .read;
                return .{ .sample = self.dma.sampleAddr };
            },
            else => unreachable,
        }
    }

    fn tickSampleEndAge(self: *Dmc) void {
        if (self.cyclesSinceSampleEnd < std.math.maxInt(u16)) self.cyclesSinceSampleEnd += 1;
    }

    fn tickLoadDmaTimer(self: *Dmc, is_get_cycle: bool) void {
        if (is_get_cycle) tickDelay(&self.loadDelay);
        const loadReady = is_get_cycle and isDelayReady(self.loadDelay) and self.sampleBufferEmpty and self.bytesRemaining > 0;
        if (!loadReady) return;

        self.loadDelay = null;
        const sampleAddr = self.currentAddress;
        const kind: Kind = switch (self.dma.kind) {
            .beforeScheduleDisable => .pendingLoadAfterDisable,
            .implicitAbortPending => .pendingLoadAfterImplicitAbort,
            else => .pendingLoad,
        };
        self.dma = .{ .kind = kind, .pendingCycles = 0, .sampleAddr = sampleAddr };
    }

    fn tickReloadDmaTimer(self: *Dmc) void {
        tickDelay(&self.reloadDelay);
        const reloadKind = self.dma.kind;
        const reloadReady = isDelayReady(self.reloadDelay) and
            self.sampleBufferEmpty and
            (self.bytesRemaining > 0 or self.implicitAbortPending or hasReloadContext(reloadKind));
        if (!reloadReady) return;

        self.reloadDelay = null;
        const waitingForStatus = self.enabled and !self.statusEnabled;
        self.dma = .{
            .kind = self.selectPendingReloadKind(reloadKind, waitingForStatus),
            .pendingCycles = 0,
            .cpuWriteDelayParity = 0,
            .sampleAddr = self.currentAddress,
        };
    }

    fn tickStatusDelay(self: *Dmc) void {
        var statusJustExpired = false;
        if (self.statusDelay > 0) {
            self.statusDelay -= 1;
            statusJustExpired = self.statusDelay == 0;
        }
        if (statusJustExpired) {
            self.statusEnabled = self.enabled;
            if (!self.enabled) {
                self.abortPendingReloadOnStatusDisable(self.dma.kind);
                self.bytesRemaining = 0;
            }
        }
    }

    fn clockOutputUnit(self: *Dmc) bool {
        if (self.rateValue > 0) {
            self.rateValue -= 1;
            return false;
        }
        self.rateValue = rateTable[self.rateIndex] - 1;

        if (!self.silenceFlag) {
            const bit = self.shiftRegister & 1;
            if (bit == 1 and self.outputLevel <= outputMax - outputStep) {
                self.outputLevel += outputStep;
            } else if (bit == 0 and self.outputLevel >= outputStep) {
                self.outputLevel -= outputStep;
            }
        }
        self.shiftRegister >>= 1;
        if (self.bitsRemaining > 0) self.bitsRemaining -= 1;
        return self.bitsRemaining == 0;
    }

    fn loadNextOutputByte(self: *Dmc) void {
        self.bitsRemaining = bitsPerByte;
        if (self.sampleBufferEmpty) {
            self.silenceFlag = true;
            return;
        }
        self.shiftRegister = self.sampleBuffer;
        self.sampleBufferEmpty = true;
        self.silenceFlag = false;

        self.enterImplicitAbortWindowIfNeeded();
        self.scheduleReloadDma();
    }

    fn enterImplicitAbortWindowIfNeeded(self: *Dmc) void {
        if (self.bytesRemaining == 0 and
            !self.loopFlag and
            (self.enabled or self.statusEnabled) and
            self.cyclesSinceSampleEnd <= 2)
        {
            switch (self.dma.kind) {
                .idle, .beforeScheduleDisable => self.dma = .{ .kind = .implicitAbortWindow },
                .implicitAbortPending => self.dma = .{ .kind = .implicitAbortWindowAbortPending },
                else => {},
            }
        }
    }

    fn scheduleReloadDma(self: *Dmc) void {
        if (@intFromEnum(self.dma.kind) >= @intFromEnum(Kind.pendingLoad) or self.reloadDelay != null or self.loadDelay != null) return;

        const shouldSchedule = self.bytesRemaining > 0 or self.implicitAbortPending or isAbortWindow(self.dma.kind);
        if (!shouldSchedule) return;

        switch (self.dma.kind) {
            .idle, .beforeScheduleDisable => self.dma = .{ .kind = .reloadScheduled },
            .implicitAbortPending => self.dma = .{ .kind = .reloadScheduledAbortPending },
            .implicitAbortWindow, .implicitAbortWindowAbortPending, .explicitAbortWindow => {},
            else => {},
        }
        self.reloadDelay = 1;
    }

    fn selectPendingReloadKind(self: *Dmc, reload_kind: Kind, waiting_for_status: bool) Kind {
        if (self.isImplicitAbortContext(reload_kind)) {
            self.implicitAbortPending = false;
            return if (waiting_for_status) .pendingReloadImplicitAbortWaitStatus else .pendingReloadImplicitAbortWaitHalt;
        }
        if (reload_kind == .explicitAbortWindow) {
            return if (waiting_for_status) .pendingReloadAbortedWaitStatus else .pendingReloadAbortedWaitHalt;
        }
        if (waiting_for_status) {
            return if (self.needsReloadAlign(reload_kind)) .pendingReloadAlignWaitStatus else .pendingReloadWaitStatus;
        }
        return if (self.needsReloadAlign(reload_kind)) .pendingReloadAlignAlignTarget else .pendingReloadWaitHalt;
    }

    fn isImplicitAbortContext(self: *const Dmc, kind: Kind) bool {
        return kind == .implicitAbortWindow or kind == .implicitAbortWindowAbortPending or self.implicitAbortPending;
    }

    fn needsReloadAlign(self: *const Dmc, kind: Kind) bool {
        return !self.enabled and (kind == .reloadScheduled or kind == .reloadScheduledAbortPending);
    }

    fn abortPendingReloadOnStatusDisable(self: *Dmc, kind: Kind) void {
        if (isNormalPendingReload(kind) or isImplicitPendingReload(kind)) {
            self.dma.kind = toAbortedKind(kind) orelse self.dma.kind;
        } else if (kind != .explicitAbortWindow and @intFromEnum(kind) < @intFromEnum(Kind.pendingLoad) and kind != .beforeScheduleDisable) {
            self.dma = .{ .kind = .beforeScheduleDisable };
        }
    }
};

fn tickDelay(delay: *?u8) void {
    if (delay.*) |*value| {
        if (value.* > 0) value.* -= 1;
    }
}

fn isDelayReady(delay: ?u8) bool {
    return delay != null and delay.? == 0;
}

fn toWaitHaltKind(kind: Kind) Kind {
    return switch (kind) {
        .pendingReloadWaitStatus, .pendingReloadAlignTarget => .pendingReloadWaitHalt,
        .pendingReloadImplicitAbortWaitStatus, .pendingReloadImplicitAbortAlignTarget => .pendingReloadImplicitAbortWaitHalt,
        .pendingReloadAbortedWaitStatus, .pendingReloadAbortedAlignTarget => .pendingReloadAbortedWaitHalt,
        .pendingReloadAlignWaitStatus, .pendingReloadAlignAlignTarget => .pendingReloadAlignWaitHalt,
        else => unreachable,
    };
}

fn toAbortedKind(kind: Kind) ?Kind {
    return switch (kind) {
        .pendingReloadWaitStatus => .pendingReloadAbortedWaitStatus,
        .pendingReloadAlignTarget => .pendingReloadAbortedAlignTarget,
        .pendingReloadWaitHalt => .pendingReloadAbortedWaitHalt,
        .pendingReloadImplicitAbortWaitStatus => .pendingReloadAbortedWaitStatus,
        .pendingReloadImplicitAbortAlignTarget => .pendingReloadAbortedAlignTarget,
        .pendingReloadImplicitAbortWaitHalt => .pendingReloadAbortedWaitHalt,
        .pendingReloadAlignWaitStatus => .pendingReloadAbortedWaitStatus,
        .pendingReloadAlignAlignTarget => .pendingReloadAbortedAlignTarget,
        .pendingReloadAlignWaitHalt => .pendingReloadAbortedWaitHalt,
        else => null,
    };
}

fn isWaitHalt(kind: Kind) bool {
    return switch (kind) {
        .pendingReloadWaitHalt,
        .pendingReloadImplicitAbortWaitHalt,
        .pendingReloadAbortedWaitHalt,
        .pendingReloadAlignWaitHalt,
        => true,
        else => false,
    };
}

fn hasReloadContext(kind: Kind) bool {
    return switch (kind) {
        .reloadScheduled,
        .reloadScheduledAbortPending,
        .explicitAbortWindow,
        .implicitAbortWindow,
        .implicitAbortWindowAbortPending,
        => true,
        else => false,
    };
}

fn isImplicitPendingReload(kind: Kind) bool {
    return @intFromEnum(kind) >= @intFromEnum(Kind.pendingReloadImplicitAbortWaitStatus) and
        @intFromEnum(kind) <= @intFromEnum(Kind.pendingReloadImplicitAbortWaitHalt);
}

fn isNormalPendingReload(kind: Kind) bool {
    return @intFromEnum(kind) >= @intFromEnum(Kind.pendingReloadWaitStatus) and
        @intFromEnum(kind) <= @intFromEnum(Kind.pendingReloadWaitHalt);
}

fn isAbortWindow(kind: Kind) bool {
    return kind == .implicitAbortWindow or kind == .implicitAbortWindowAbortPending or kind == .explicitAbortWindow;
}
