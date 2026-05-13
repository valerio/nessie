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

    fn step(self: *AddrResolver, mode: opcodes.AddrMode, cpu: *Cpu, input: ?u8) AddrResult {
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

                if (index != 0 and pageCrossed(baseAddr, addr)) {
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
                        if (cpu.y != 0 and pageCrossed(baseAddr, addr)) {
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

pub const Instruction = struct {
    opcode: opcodes.Opcode,
    stage: InstructionStage = .resolveAddr,
    addrResolver: AddrResolver = .{},

    // TODO: these should somehow scale up to all instrs or be private
    // per-struct definition (comptime?)
    pub const InstructionStage = enum {
        resolveAddr,
        readValue,
        done,
    };

    pub fn init(opcode: opcodes.Opcode) Instruction {
        return .{ .opcode = opcode };
    }

    // TODO: dispatch based on opcode table
    pub fn step(self: *Instruction, cpu: *Cpu, input: ?u8) ?BusOp {
        return switch (self.opcode.mnemonic) {
            .lda => stepLoad(.a, self, cpu, input),
            .ldx => stepLoad(.x, self, cpu, input),
            .ldy => stepLoad(.y, self, cpu, input),
            else => panic("instruction {} is unimplemented", .{self.opcode.mnemonic}),
        };
    }
};

// TODO: Move these to their own file
// implements a state machine for all LD* instructions
fn stepLoad(comptime reg: Register8, self: *Instruction, cpu: *Cpu, input: ?u8) ?BusOp {
    switch (self.stage) {
        .resolveAddr => {
            switch (self.addrResolver.step(self.opcode.mode, cpu, input)) {
                .pending => |op| return op,
                .done => |addr| {
                    self.stage = .readValue;
                    return .{ .read = addr };
                },
            }
        },
        .readValue => {
            const value = input orelse panic("expected load read input", .{});
            setNZ(reg, cpu, value);
            self.stage = .done;
            return null;
        },
        .done => unreachable,
    }
    unreachable;
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

fn setNZ(comptime reg: Register8, self: *Cpu, value: u8) void {
    switch (reg) {
        .a => self.a = value,
        .x => self.x = value,
        .y => self.y = value,
    }
    self.flags.z = value == 0;
    self.flags.n = (value & 0x80) != 0;
}

test "cpu init" {
    const cpu = Cpu.init();
    try testing.expectEqual(0x24, cpu.flags.toByte());
    try testing.expectEqual(0xFD, cpu.sp);
}
