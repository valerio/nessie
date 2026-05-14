const std = @import("std");
const opcodes = @import("opcodes.zig");
const testing = std.testing;
const panic = std.debug.panic;

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

/// Represents a bus operation.
/// Instructions are broken down into separate stages, e.g.
/// LDA reads from memory -> stores in A -> done
/// At each stage, the instruction might perform a bus read/write or nothing.
/// Each step is typically 1 cpu cycle, and bus read/writes can trigger side-effects.
///
/// This enum is essentially representing what is done at a yield point in a CPU instruction.
pub const BusOp = union(enum) {
    /// A cycle where the instruction is waiting for a read
    read: u16,
    /// A cycle where the instruction is waiting for a write
    write: struct { addr: u16, value: u8 },
    /// A cycle where no bus operation is performed
    idle,
};

/// Implements instruction addressing resolution as a state machine.
/// In a 6502, the same instruction can get its operands in a variety of modes (see opcodes.AddrMode)
///
/// Some modes might require multiple cycles/bus reads to resolve the address, this FSM essentially
/// Allows the caller to run side-effects or emulation ticks in-between cycles.
///
/// TODO: convert to micro-ops?
const AddrResolver = struct {
    state: AddrState = .start,

    /// Some states carry additional data, especially when they work in tandem with other
    /// states, e.g. absolute addressing needs to read the low byte first, then pass it
    /// to the stage where the low byte is read, then combine them.
    ///
    /// start -> readOperandLow -> readOperandHigh (low) -> resolved (addr)
    const AddrState = union(enum) {
        start,
        readOperand,
        readOperandLow,
        readOperandHigh: struct { low: u8 },
        indexZeroPage: struct { addr: u8 },
        indexIndirectX: struct { zpAddr: u8 },
        readIndirectLow: struct { zpAddr: u8 },
        readIndirectHigh: struct { zpAddr: u8, low: u8 },
        dummyRead: struct { addr: u16 },
        resolved: struct { addr: u16 },
    };

    const AddrResult = union(enum) {
        pending: BusOp,
        done: u16,
    };

    fn step(self: *AddrResolver, opcode: opcodes.Opcode, cpu: *Cpu, input: ?u8) AddrResult {
        const mode = opcode.mode;
        switch (self.state) {
            .start => {
                const addr = cpu.pc;
                cpu.pc +%= 1;

                self.state = switch (mode) {
                    .immediate => .{ .resolved = .{ .addr = addr } },
                    .zeroPage, .zeroPageX, .zeroPageY, .indirectX, .indirectY => .readOperand,
                    .absolute, .absoluteX, .absoluteY => .readOperandLow,
                    else => panic("address mode {} is unimplemented", .{mode}),
                };

                return switch (mode) {
                    .immediate => .{ .done = addr },
                    else => .{ .pending = .{ .read = addr } },
                };
            },
            .readOperand => {
                const baseAddr = input orelse panic("expected read operand input", .{});

                switch (mode) {
                    .zeroPage => {
                        self.state = .{ .resolved = .{ .addr = baseAddr } };
                        return .{ .done = baseAddr };
                    },
                    .zeroPageX => {
                        self.state = .{ .indexZeroPage = .{ .addr = baseAddr +% cpu.x } };
                        return .{ .pending = .idle };
                    },
                    .zeroPageY => {
                        self.state = .{ .indexZeroPage = .{ .addr = baseAddr +% cpu.y } };
                        return .{ .pending = .idle };
                    },
                    .indirectX => {
                        self.state = .{ .indexIndirectX = .{ .zpAddr = baseAddr +% cpu.x } };
                        return .{ .pending = .idle };
                    },
                    .indirectY => {
                        self.state = .{ .readIndirectLow = .{ .zpAddr = baseAddr } };
                        return .{ .pending = .{ .read = baseAddr } };
                    },
                    else => panic("address mode {} does not apply to state {}", .{ mode, self.state }),
                }
            },
            .indexZeroPage => |state| {
                self.state = .{ .resolved = .{ .addr = state.addr } };
                return .{ .done = state.addr };
            },
            .indexIndirectX => |state| {
                self.state = .{ .readIndirectLow = .{ .zpAddr = state.zpAddr } };
                return .{ .pending = .{ .read = state.zpAddr } };
            },
            .readOperandLow => {
                const low = input orelse panic("expected read operand low input", .{});
                self.state = .{ .readOperandHigh = .{ .low = low } };
                const op: BusOp = .{ .read = cpu.pc };
                cpu.pc +%= 1;
                return .{ .pending = op };
            },
            .readOperandHigh => |state| {
                const highByte = input orelse panic("expected read operand high input", .{});
                const baseAddr =
                    (@as(u16, highByte) << 8) |
                    @as(u16, state.low);
                const index: u16 = switch (mode) {
                    .absolute => 0,
                    .absoluteX => cpu.x,
                    .absoluteY => cpu.y,
                    else => panic("address mode {} does not apply to state {}", .{ mode, self.state }),
                };
                const addr = baseAddr +% index;

                if (opcode.forceDummyRead or (index != 0 and pageCrossed(baseAddr, addr))) {
                    self.state = .{ .dummyRead = .{ .addr = addr } };
                    return .{ .pending = .{ .read = dummyReadAddr(baseAddr, addr) } };
                }

                self.state = .{ .resolved = .{ .addr = addr } };
                return .{ .done = addr };
            },
            .readIndirectLow => |state| {
                const low = input orelse panic("expected read indirect low input", .{});
                self.state = .{ .readIndirectHigh = .{ .zpAddr = state.zpAddr, .low = low } };
                return .{ .pending = .{ .read = state.zpAddr +% 1 } };
            },
            .readIndirectHigh => |state| {
                const highByte = input orelse panic("expected read indirect high input", .{});
                const baseAddr =
                    (@as(u16, highByte) << 8) |
                    @as(u16, state.low);
                switch (mode) {
                    .indirectX => {
                        self.state = .{ .resolved = .{ .addr = baseAddr } };
                        return .{ .done = baseAddr };
                    },
                    .indirectY => {
                        const addr = baseAddr +% cpu.y;
                        if (opcode.forceDummyRead or (cpu.y != 0 and pageCrossed(baseAddr, addr))) {
                            self.state = .{ .dummyRead = .{ .addr = addr } };
                            return .{ .pending = .{ .read = dummyReadAddr(baseAddr, addr) } };
                        }
                        self.state = .{ .resolved = .{ .addr = addr } };
                        return .{ .done = addr };
                    },
                    else => panic("address mode {} does not apply to state {}", .{ mode, self.state }),
                }
            },
            .dummyRead => |state| {
                self.state = .{ .resolved = .{ .addr = state.addr } };
                return .{ .done = state.addr };
            },
            .resolved => |state| return .{ .done = state.addr },
        }
    }

    fn pageCrossed(base: u16, addr: u16) bool {
        return (base & 0xff00) != (addr & 0xff00);
    }

    fn dummyReadAddr(base: u16, addr: u16) u16 {
        return (base & 0xff00) | (addr & 0x00ff);
    }
};

pub const Register8 = enum { a, x, y };

const StatusFlag = enum { c, i };

const MicroOp = union(enum) {
    dummyReadPc,
    resolveAddr,
    readValue,
    writeReg: Register8,
    loadRegSetNZ: Register8,
    transferRegSetNZ: struct { src: Register8, dst: Register8 },
    incrementReg: Register8,
    decrementReg: Register8,
    setFlag: struct { flag: StatusFlag, value: bool },
    done,
};

pub const Instruction = struct {
    ops: []const MicroOp,
    opStep: usize = 0,
    addr: u16 = 0,
    opcode: opcodes.Opcode,
    addrResolver: AddrResolver = .{},

    pub fn init(opcode: opcodes.Opcode) @This() {
        return .{ .opcode = opcode, .ops = switch (opcode.mnemonic) {
            .nop => impliedOps(.done),
            .lda => loadOps(.a),
            .ldx => loadOps(.x),
            .ldy => loadOps(.y),
            .sta => storeOps(.a),
            .stx => storeOps(.x),
            .sty => storeOps(.y),
            .tax => impliedOps(.{ .transferRegSetNZ = .{ .src = .a, .dst = .x } }),
            .txa => impliedOps(.{ .transferRegSetNZ = .{ .src = .x, .dst = .a } }),
            .tay => impliedOps(.{ .transferRegSetNZ = .{ .src = .a, .dst = .y } }),
            .tya => impliedOps(.{ .transferRegSetNZ = .{ .src = .y, .dst = .a } }),
            .inx => impliedOps(.{ .incrementReg = .x }),
            .dex => impliedOps(.{ .decrementReg = .x }),
            .iny => impliedOps(.{ .incrementReg = .y }),
            .dey => impliedOps(.{ .decrementReg = .y }),
            .clc => impliedOps(.{ .setFlag = .{ .flag = .c, .value = false } }),
            .sec => impliedOps(.{ .setFlag = .{ .flag = .c, .value = true } }),
            .cli => impliedOps(.{ .setFlag = .{ .flag = .i, .value = false } }),
            .sei => impliedOps(.{ .setFlag = .{ .flag = .i, .value = true } }),
            else => panic("unimplemented opcode: {}", .{opcode.mnemonic}),
        } };
    }

    pub fn step(self: *@This(), cpu: *Cpu, input: ?u8) ?BusOp {
        while (true) {
            const op = self.ops[self.opStep];
            var busOp: ?BusOp = null;
            var advance = true;

            switch (op) {
                .resolveAddr => switch (self.addrResolver.step(self.opcode, cpu, input)) {
                    .pending => |pending| {
                        busOp = pending;
                        advance = false;
                    },
                    .done => |addr| self.addr = addr,
                },
                .dummyReadPc => busOp = .{ .read = cpu.pc },
                .readValue => busOp = .{ .read = self.addr },
                .writeReg => |r| busOp = .{ .write = .{ .addr = self.addr, .value = readReg(r, cpu) } },
                .loadRegSetNZ => |r| setNZ(r, cpu, input orelse panic("stage {s} must have an input", .{@tagName(op)})),
                .transferRegSetNZ => |t| setNZ(t.dst, cpu, readReg(t.src, cpu)),
                .incrementReg => |r| setNZ(r, cpu, readReg(r, cpu) +% 1),
                .decrementReg => |r| setNZ(r, cpu, readReg(r, cpu) -% 1),
                .setFlag => |f| setStatusFlag(f.flag, cpu, f.value),
                .done => return null,
            }

            if (advance) self.opStep += 1;
            if (busOp) |bop| return bop;
        }
    }
};

/// the op sequence for implied instructions, i.e. ones where operands
/// are "implied" or known from the mnemonic itself.
/// Examples:
///   - nop: does nothing lol
///   - tax: transfer A to X (both known)
///   - clc: clear carry flag
///
/// Each of these performs a dummy read first.
fn impliedOps(comptime op: MicroOp) []const MicroOp {
    return &.{ .dummyReadPc, op, .done };
}

pub fn loadOps(comptime r: Register8) []const MicroOp {
    return &.{ .resolveAddr, .readValue, .{ .loadRegSetNZ = r }, .done };
}

pub fn storeOps(comptime r: Register8) []const MicroOp {
    return &.{ .resolveAddr, .{ .writeReg = r }, .done };
}

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
};

fn readReg(reg: Register8, self: *const Cpu) u8 {
    return switch (reg) {
        .a => self.a,
        .x => self.x,
        .y => self.y,
    };
}

fn setNZ(reg: Register8, self: *Cpu, value: u8) void {
    switch (reg) {
        .a => self.a = value,
        .x => self.x = value,
        .y => self.y = value,
    }
    self.flags.z = value == 0;
    self.flags.n = (value & 0x80) != 0;
}

fn setStatusFlag(flag: StatusFlag, self: *Cpu, value: bool) void {
    switch (flag) {
        .c => self.flags.c = value,
        .i => self.flags.i = value,
    }
}

test "cpu init" {
    const cpu = Cpu.init();
    try testing.expectEqual(0x24, cpu.flags.toByte());
    try testing.expectEqual(0xFD, cpu.sp);
}
