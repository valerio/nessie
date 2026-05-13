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

// TODO: these should somehow scale up to all instrs or be private
// per-struct definition (comptime?)
pub const InstructionStage = enum {
    start,
    readOperand,
    readOperandLow,
    readOperandHigh,
    indexZeroPage,
    indexIndirectX,
    readIndirectLow,
    readIndirectHigh,
    dummyRead,
    readValue,
    done,
};

pub const Register8 = enum { a, x, y };

pub const Instruction = struct {
    opcode: opcodes.Opcode,
    stage: InstructionStage = .start,
    addr: u16 = 0,
    baseAddr: u16 = 0,
    lowByte: ?u8 = null,

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
        .start => {
            // TODO: make addressing generic
            const op: BusOp = .{ .read = cpu.pc };
            cpu.pc +%= 1;
            self.stage = switch (self.opcode.mode) {
                .immediate => .readValue,
                .zeroPage, .zeroPageX, .zeroPageY, .indirectX, .indirectY => .readOperand,
                .absolute, .absoluteX, .absoluteY => .readOperandLow,
                else => panic("load mode {} is unimplemented for {}", .{ self.opcode.mode, self.opcode.mnemonic }),
            };
            return op;
        },
        .readOperand => {
            const baseAddr = input orelse panic("expected read addr input", .{});
            self.addr = switch (self.opcode.mode) {
                .zeroPage => baseAddr,
                .zeroPageX => baseAddr +% cpu.x,
                .zeroPageY => baseAddr +% cpu.y,
                .indirectX => baseAddr +% cpu.x,
                .indirectY => baseAddr,
                else => panic("load mode {} does not apply to stage {}", .{ self.opcode.mode, self.stage }),
            };

            self.stage = switch (self.opcode.mode) {
                .zeroPage => .readValue,
                .zeroPageX, .zeroPageY => .indexZeroPage,
                .indirectX => .indexIndirectX,
                .indirectY => .readIndirectLow,
                else => panic("load mode {} does not apply to stage {}", .{ self.opcode.mode, self.stage }),
            };

            return switch (self.opcode.mode) {
                .zeroPage, .indirectY => .{ .read = self.addr },
                .zeroPageX, .zeroPageY, .indirectX => .idle,
                else => panic("load mode {} does not apply to stage {}", .{ self.opcode.mode, self.stage }),
            };
        },
        .indexZeroPage => {
            self.stage = .readValue;
            return .{ .read = self.addr };
        },
        .indexIndirectX => {
            self.stage = .readIndirectLow;
            return .{ .read = self.addr };
        },
        .readOperandLow => {
            self.lowByte = input orelse panic("expected read addr low input", .{});
            self.stage = .readOperandHigh;
            const op: BusOp = .{ .read = cpu.pc };
            cpu.pc +%= 1;
            return op;
        },
        .readOperandHigh => {
            const addrHigh = input orelse panic("expected read addr high input", .{});
            self.baseAddr =
                (@as(u16, addrHigh) << 8) |
                @as(u16, self.lowByte orelse panic("expected low addr bytes during read addr high", .{}));
            const index: u16 = switch (self.opcode.mode) {
                .absolute => 0,
                .absoluteX => cpu.x,
                .absoluteY => cpu.y,
                else => panic("load mode {} does not apply to stage {}", .{ self.opcode.mode, self.stage }),
            };
            self.addr = self.baseAddr +% index;

            if (index != 0 and pageCrossed(self.baseAddr, self.addr)) {
                self.stage = .dummyRead;
                return .{ .read = dummyReadAddr(self.baseAddr, self.addr) };
            }

            self.stage = .readValue;
            return .{ .read = self.addr };
        },
        .readIndirectLow => {
            self.lowByte = input orelse panic("expected read pointer low input", .{});
            self.stage = .readIndirectHigh;
            return .{ .read = (self.addr +% 1) & 0xff };
        },
        .readIndirectHigh => {
            const pointerHigh = input orelse panic("expected read pointer high input", .{});
            self.baseAddr =
                (@as(u16, pointerHigh) << 8) |
                @as(u16, self.lowByte orelse panic("expected low pointer byte during read pointer high", .{}));
            switch (self.opcode.mode) {
                .indirectX => {
                    self.addr = self.baseAddr;
                    self.stage = .readValue;
                    return .{ .read = self.addr };
                },
                .indirectY => {
                    self.addr = self.baseAddr +% cpu.y;
                    if (cpu.y != 0 and pageCrossed(self.baseAddr, self.addr)) {
                        self.stage = .dummyRead;
                        return .{ .read = dummyReadAddr(self.baseAddr, self.addr) };
                    }
                    self.stage = .readValue;
                    return .{ .read = self.addr };
                },
                else => panic("load mode {} does not apply to stage {}", .{ self.opcode.mode, self.stage }),
            }
        },
        .dummyRead => {
            self.stage = .readValue;
            return .{ .read = self.addr };
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

fn pageCrossed(base: u16, addr: u16) bool {
    return (base & 0xff00) != (addr & 0xff00);
}

fn dummyReadAddr(base: u16, addr: u16) u16 {
    return (base & 0xff00) | (addr & 0x00ff);
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
