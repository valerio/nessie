const std = @import("std");
const opcodes = @import("opcodes.zig");
const addressing = @import("addressing.zig");

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

const StatusFlag = enum { n, v, b, d, i, z, c };

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

pub fn exec(c: *Cpu, ctx: anytype) void {
    const opcode = opcodes.table[ctx.read(c.pc)];
    c.pc +%= 1;

    // addressing
    // TODO: could optional addressing be done without the unwrapping (.?) below?
    const addr: ?u16 = switch (opcode.mode) {
        .implied => null,
        .immediate => addressing.immediate(c),
        .zeroPage => addressing.zeroPage(c, ctx, null),
        .zeroPageX => addressing.zeroPage(c, ctx, .x),
        .zeroPageY => addressing.zeroPage(c, ctx, .y),
        .absolute => addressing.absolute(c, ctx, null),
        .absoluteX => addressing.absolute(c, ctx, .x),
        .absoluteY => addressing.absolute(c, ctx, .y),
        .indirect => addressing.indirect(c, ctx),
        .indirectX => addressing.indirectIndexed(c, ctx, .x),
        .indirectY => addressing.indirectIndexed(c, ctx, .y),
        .relative => addressing.relative(c, ctx),
    };

    // execution
    switch (opcode.mnemonic) {
        .nop => _ = ctx.read(c.pc),
        .lda => c.setRegNZ(.a, ctx.read(addr.?)),
        .ldx => c.setRegNZ(.x, ctx.read(addr.?)),
        .ldy => c.setRegNZ(.y, ctx.read(addr.?)),
        .sta => ctx.write(addr.?, c.a),
        .stx => ctx.write(addr.?, c.x),
        .sty => ctx.write(addr.?, c.y),
        .@"and" => c.setRegNZ(.a, c.aluA(.@"and", ctx.read(addr.?))),
        .ora => c.setRegNZ(.a, c.aluA(.ora, ctx.read(addr.?))),
        .eor => c.setRegNZ(.a, c.aluA(.eor, ctx.read(addr.?))),
        .cmp => c.compare(c.a, ctx.read(addr.?)),
        .cpx => c.compare(c.x, ctx.read(addr.?)),
        .cpy => c.compare(c.y, ctx.read(addr.?)),
        .jmp => c.pc = addr.?,
        .bcc => branch(c, ctx, addr.?, .c, false),
        .bcs => branch(c, ctx, addr.?, .c, true),
        .beq => branch(c, ctx, addr.?, .z, true),
        .bne => branch(c, ctx, addr.?, .z, false),
        .bpl => branch(c, ctx, addr.?, .n, false),
        .bmi => branch(c, ctx, addr.?, .n, true),
        .bvc => branch(c, ctx, addr.?, .v, false),
        .bvs => branch(c, ctx, addr.?, .v, true),
        .tax => transfer(c, ctx, .a, .x),
        .txa => transfer(c, ctx, .x, .a),
        .tay => transfer(c, ctx, .a, .y),
        .tya => transfer(c, ctx, .y, .a),
        .tsx => transfer(c, ctx, .sp, .x),
        .txs => transfer(c, ctx, .x, .sp),
        .inx => increment(c, ctx, .x),
        .dex => decrement(c, ctx, .x),
        .iny => increment(c, ctx, .y),
        .dey => decrement(c, ctx, .y),
        .clc => setFlag(c, ctx, .c, false),
        .sec => setFlag(c, ctx, .c, true),
        .cli => setFlag(c, ctx, .i, false),
        .sei => setFlag(c, ctx, .i, true),
        .cld => setFlag(c, ctx, .d, false),
        .sed => setFlag(c, ctx, .d, true),
        .clv => setFlag(c, ctx, .v, false),
        .pha => push(c, ctx, c.a),
        .php => push(c, ctx, c.flags.toByte() | 0x10),
        .pla => pullReg(c, ctx, .a),
        .plp => pullFlags(c, ctx),
        else => @panic("boom"),
    }

    ctx.afterInstruction();
}

// TODO move this somewhere else?
fn branch(c: *Cpu, ctx: anytype, addr: u16, flag: StatusFlag, set: bool) void {
    if (c.getStatusFlag(flag) != set) return;

    const base = c.pc;
    _ = ctx.read(base);
    if ((base & 0xff00) != (addr & 0xff00)) {
        _ = ctx.read((base & 0xff00) | (addr & 0x00ff));
    }
    c.pc = addr;
}

fn transfer(c: *Cpu, ctx: anytype, src: Register8, dst: Register8) void {
    _ = ctx.read(c.pc);
    c.setReg(dst, c.readReg(src));
    if (dst != .sp) c.setNZ(c.readReg(src));
}

fn increment(c: *Cpu, ctx: anytype, reg: Register8) void {
    _ = ctx.read(c.pc);
    c.setRegNZ(reg, c.readReg(reg) +% 1);
}

fn decrement(c: *Cpu, ctx: anytype, reg: Register8) void {
    _ = ctx.read(c.pc);
    c.setRegNZ(reg, c.readReg(reg) -% 1);
}

fn setFlag(c: *Cpu, ctx: anytype, flag: StatusFlag, value: bool) void {
    _ = ctx.read(c.pc);
    c.setStatusFlag(flag, value);
}

fn push(c: *Cpu, ctx: anytype, value: u8) void {
    _ = ctx.read(c.pc);
    ctx.write(c.stackAddr(), value);
    c.sp -%= 1;
}

fn pullReg(c: *Cpu, ctx: anytype, reg: Register8) void {
    _ = ctx.read(c.pc);
    _ = ctx.read(c.stackAddr());
    c.sp +%= 1;
    c.setRegNZ(reg, ctx.read(c.stackAddr()));
}

fn pullFlags(c: *Cpu, ctx: anytype) void {
    _ = ctx.read(c.pc);
    _ = ctx.read(c.stackAddr());
    c.sp +%= 1;
    c.flags = Flags.fromByte(ctx.read(c.stackAddr()));
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

fn pageCrossed(base: u16, addr: u16) bool {
    return (base & 0xff00) != (addr & 0xff00);
}

fn dummyReadAddr(base: u16, addr: u16) u16 {
    return (base & 0xff00) | (addr & 0x00ff);
}

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

        // JMP indirect has a hardware bug: pointer high byte wraps within the same page.
        readJumpTargetLow: u16,
        readJumpTargetHigh: u8,

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
                    .absolute, .absoluteX, .absoluteY, .indirect => .readOperandLow,
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

                // special case for JMP indirect addressing, it reads a 16 target address.
                if (mode == .indirect) {
                    self.state = .{ .readJumpTargetLow = baseAddr };
                    return .{ .pending = .{ .read = baseAddr } };
                }

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
            .readJumpTargetLow => |ptr| {
                const low = input.?;
                const highAddr = if ((ptr & 0x00ff) == 0x00ff) ptr & 0xff00 else ptr +% 1;
                self.state = .{ .readJumpTargetHigh = low };
                return .{ .pending = .{ .read = highAddr } };
            },
            .readJumpTargetHigh => |low| {
                const highByte = input.?;
                const addr = (@as(u16, highByte) << 8) | @as(u16, low);
                self.state = .{ .resolved = .{ .addr = addr } };
                return .{ .done = addr };
            },
            .dummyRead => |state| {
                self.state = .{ .resolved = .{ .addr = state.addr } };
                return .{ .done = state.addr };
            },
            .resolved => |state| return .{ .done = state.addr },
        }
    }
};

const BranchCondition = struct {
    flag: StatusFlag,
    set: bool,
};

const BranchResolver = struct {
    state: State = .start,

    const State = union(enum) {
        start,
        check,
        taken: u16,
        pageCross: u16,
        done,
    };

    pub fn step(self: *BranchResolver, condition: BranchCondition, cpu: *Cpu, input: ?u8) ?BusOp {
        switch (self.state) {
            .start => {
                const addr = cpu.pc;
                cpu.pc +%= 1;
                self.state = .check;
                return .{ .read = addr };
            },
            .check => {
                const offset = input.?;

                if (cpu.getStatusFlag(condition.flag) != condition.set) {
                    self.state = .done;
                    return null;
                }

                const base = cpu.pc;
                const target = branchTarget(base, offset);
                self.state = .{ .taken = target };
                return .{ .read = base };
            },
            .taken => |target| {
                const base = cpu.pc;
                if (pageCrossed(base, target)) {
                    self.state = .{ .pageCross = target };
                    return .{ .read = dummyReadAddr(base, target) };
                }

                cpu.pc = target;
                self.state = .done;
                return null;
            },
            .pageCross => |target| {
                cpu.pc = target;
                self.state = .done;
                return null;
            },
            .done => return null,
        }
    }

    fn branchTarget(base: u16, offset: u8) u16 {
        if (offset < 0x80) return base +% offset;
        return base -% (0x100 - @as(u16, offset));
    }
};

const AluOp = enum {
    @"and",
    ora,
    eor,
};

const StackTarget = union(enum) { reg: Register8, flags };

const MicroOp = union(enum) {
    dummyReadPc,
    resolveAddr,
    readValue,

    writeReg: Register8,
    pushStack: StackTarget,
    popStack: struct { peek: bool },
    loadStack: StackTarget, // after a pop, stores the read result into target
    loadReg: Register8,
    transferReg: struct { src: Register8, dst: Register8 },
    incrementReg: Register8,
    decrementReg: Register8,
    compareReg: Register8,

    aluA: AluOp,
    branch: BranchCondition,
    jump,

    setFlag: struct { flag: StatusFlag, value: bool },
    done,
};

pub const Instruction = struct {
    ops: []const MicroOp,
    opStep: usize = 0,
    addr: u16 = 0,
    opcode: opcodes.Opcode,
    addrResolver: AddrResolver = .{},
    branchResolver: BranchResolver = .{},

    pub fn init(opcode: opcodes.Opcode) @This() {
        return .{ .opcode = opcode, .ops = switch (opcode.mnemonic) {
            .nop => impliedOps(.done),
            .lda => loadOps(.a),
            .ldx => loadOps(.x),
            .ldy => loadOps(.y),
            .sta => storeOps(.a),
            .stx => storeOps(.x),
            .sty => storeOps(.y),
            .@"and" => aluAOps(.@"and"),
            .ora => aluAOps(.ora),
            .eor => aluAOps(.eor),
            .cmp => compareOps(.a),
            .cpx => compareOps(.x),
            .cpy => compareOps(.y),
            .jmp => jumpOps(),
            .bcc => branchOps(.c, false),
            .bcs => branchOps(.c, true),
            .beq => branchOps(.z, true),
            .bne => branchOps(.z, false),
            .bpl => branchOps(.n, false),
            .bmi => branchOps(.n, true),
            .bvc => branchOps(.v, false),
            .bvs => branchOps(.v, true),
            .tax => impliedOps(.{ .transferReg = .{ .src = .a, .dst = .x } }),
            .txa => impliedOps(.{ .transferReg = .{ .src = .x, .dst = .a } }),
            .tay => impliedOps(.{ .transferReg = .{ .src = .a, .dst = .y } }),
            .tya => impliedOps(.{ .transferReg = .{ .src = .y, .dst = .a } }),
            .tsx => impliedOps(.{ .transferReg = .{ .src = .sp, .dst = .x } }),
            .txs => impliedOps(.{ .transferReg = .{ .src = .x, .dst = .sp } }),
            .inx => impliedOps(.{ .incrementReg = .x }),
            .dex => impliedOps(.{ .decrementReg = .x }),
            .iny => impliedOps(.{ .incrementReg = .y }),
            .dey => impliedOps(.{ .decrementReg = .y }),
            .clc => impliedOps(.{ .setFlag = .{ .flag = .c, .value = false } }),
            .sec => impliedOps(.{ .setFlag = .{ .flag = .c, .value = true } }),
            .cli => impliedOps(.{ .setFlag = .{ .flag = .i, .value = false } }),
            .sei => impliedOps(.{ .setFlag = .{ .flag = .i, .value = true } }),
            .cld => impliedOps(.{ .setFlag = .{ .flag = .d, .value = false } }),
            .sed => impliedOps(.{ .setFlag = .{ .flag = .d, .value = true } }),
            .clv => impliedOps(.{ .setFlag = .{ .flag = .v, .value = false } }),
            .pha => pushOps(.{ .reg = .a }),
            .php => pushOps(.flags),
            .pla => pullOps(.{ .reg = .a }),
            .plp => pullOps(.flags),
            else => panic("unimplemented opcode: {}", .{opcode.mnemonic}),
        } };
    }

    pub fn step(self: *@This(), cpu: *Cpu, input: ?u8) ?BusOp {
        while (true) {
            const op = self.ops[self.opStep];
            var busOp: ?BusOp = null;
            // TODO: restructure addressing so it loops separately before the actual instruction.
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
                .writeReg => |r| busOp = .{ .write = .{ .addr = self.addr, .value = cpu.readReg(r) } },
                .pushStack => |target| {
                    busOp = switch (target) {
                        .reg => |r| cpu.push(cpu.readReg(r)),
                        .flags => cpu.push(cpu.flags.toByte() | 0x10),
                    };
                },
                .popStack => |arg| {
                    if (!arg.peek) cpu.sp +%= 1;
                    busOp = .{ .read = cpu.stackAddr() };
                },
                .loadStack => |target| switch (target) {
                    .reg => |r| cpu.setRegNZ(r, input.?),
                    .flags => cpu.flags = Flags.fromByte(input.?),
                },
                .loadReg => |r| cpu.setRegNZ(r, input.?),
                .transferReg => |t| {
                    cpu.setReg(t.dst, cpu.readReg(t.src));
                    if (t.dst != .sp) { // txs doesn't affect flags.
                        cpu.setNZ(cpu.readReg(t.src));
                    }
                },
                .incrementReg => |r| cpu.setRegNZ(r, cpu.readReg(r) +% 1),
                .decrementReg => |r| cpu.setRegNZ(r, cpu.readReg(r) -% 1),
                .compareReg => |r| cpu.compare(cpu.readReg(r), input.?),
                .aluA => |aluOp| cpu.setRegNZ(.a, cpu.aluA(aluOp, input.?)),
                .branch => |condition| {
                    busOp = self.branchResolver.step(condition, cpu, input);
                    advance = busOp == null;
                },
                .jump => cpu.pc = self.addr,
                .setFlag => |f| cpu.setStatusFlag(f.flag, f.value),
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
    return &.{ .resolveAddr, .readValue, .{ .loadReg = r }, .done };
}

pub fn storeOps(comptime r: Register8) []const MicroOp {
    return &.{ .resolveAddr, .{ .writeReg = r }, .done };
}

pub fn aluAOps(comptime op: AluOp) []const MicroOp {
    return &.{ .resolveAddr, .readValue, .{ .aluA = op }, .done };
}

pub fn compareOps(comptime r: Register8) []const MicroOp {
    return &.{ .resolveAddr, .readValue, .{ .compareReg = r }, .done };
}

pub fn branchOps(comptime flag: StatusFlag, comptime set: bool) []const MicroOp {
    return &.{ .{ .branch = .{ .flag = flag, .set = set } }, .done };
}

pub fn jumpOps() []const MicroOp {
    return &.{ .resolveAddr, .jump, .done };
}

pub fn pushOps(comptime tgt: StackTarget) []const MicroOp {
    return &.{ .dummyReadPc, .{ .pushStack = tgt }, .done };
}

pub fn pullOps(comptime tgt: StackTarget) []const MicroOp {
    return &.{ .dummyReadPc, .{ .popStack = .{ .peek = true } }, .{ .popStack = .{ .peek = false } }, .{ .loadStack = tgt }, .done };
}

pub const Register8 = enum { a, x, y, sp };

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

    pub fn readReg(self: *const Cpu, reg: Register8) u8 {
        return switch (reg) {
            .a => self.a,
            .x => self.x,
            .y => self.y,
            .sp => self.sp,
        };
    }

    pub fn setReg(self: *Cpu, reg: Register8, value: u8) void {
        switch (reg) {
            .a => self.a = value,
            .x => self.x = value,
            .y => self.y = value,
            .sp => self.sp = value,
        }
    }

    pub fn setNZ(self: *Cpu, value: u8) void {
        self.flags.z = value == 0;
        self.flags.n = (value & 0x80) != 0;
    }

    pub fn setRegNZ(self: *Cpu, reg: Register8, value: u8) void {
        self.setReg(reg, value);
        self.setNZ(value);
    }

    pub fn stackAddr(self: *const Cpu) u16 {
        return 0x0100 | @as(u16, self.sp);
    }

    pub fn push(self: *Cpu, value: u8) BusOp {
        const op: BusOp = .{ .write = .{ .addr = self.stackAddr(), .value = value } };
        self.sp -%= 1;
        return op;
    }

    // TODO: probably refactor/simplify this.
    pub fn setStatusFlag(self: *Cpu, flag: StatusFlag, value: bool) void {
        switch (flag) {
            .c => self.flags.c = value,
            .i => self.flags.i = value,
            .d => self.flags.d = value,
            .b => self.flags.b = value,
            .z => self.flags.z = value,
            .n => self.flags.n = value,
            .v => self.flags.v = value,
        }
    }

    pub fn getStatusFlag(self: *Cpu, flag: StatusFlag) bool {
        return switch (flag) {
            .c => self.flags.c,
            .i => self.flags.i,
            .d => self.flags.d,
            .b => self.flags.b,
            .z => self.flags.z,
            .n => self.flags.n,
            .v => self.flags.v,
        };
    }

    pub fn aluA(self: *Cpu, op: AluOp, value: u8) u8 {
        return switch (op) {
            .@"and" => self.a & value,
            .ora => self.a | value,
            .eor => self.a ^ value,
        };
    }

    pub fn compare(self: *Cpu, reg: u8, value: u8) void {
        self.flags.z = reg == value;
        self.flags.c = reg >= value;
        self.flags.n = ((reg -% value) & 0x80) != 0;
    }
};

test "cpu init" {
    const cpu = Cpu.init();
    try testing.expectEqual(0x24, cpu.flags.toByte());
    try testing.expectEqual(0xFD, cpu.sp);
}
