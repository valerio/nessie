const std = @import("std");
const mappers = @import("mapper.zig");
const cpu = @import("cpu.zig");
const opcodes = @import("opcodes.zig");
const Mapper = mappers.Mapper;

const testing = std.testing;

const Cpu = cpu.Cpu;
const Instruction = cpu.Instruction;
const Instr2 = cpu.Instr2;
const BusOp = cpu.BusOp;

const internalRamSize = 0x800; // 2KB

pub const System = struct {
    cpu: Cpu,
    internalRam: [internalRamSize]u8,
    mapper: Mapper,

    pub fn init(mapper: Mapper) System {
        return .{
            .cpu = Cpu.init(),
            .internalRam = [_]u8{0} ** (internalRamSize),
            .mapper = mapper,
        };
        // TODO: set PC based on 0xfffc and 0xfffd
        // self.cpu.pc = self.busRead(0xfffc);
    }

    pub fn tick(self: *System) void {
        const opcode = opcodes.table[self.busRead(self.cpu.pc)];
        self.cpu.pc +%= 1;
        var instr = Instruction.init(opcode);
        var input: ?u8 = null;

        while (instr.stage != .done) {
            const busOp = instr.step(&self.cpu, input) orelse {
                input = null;
                continue;
            };
            switch (busOp) {
                .read => |addr| input = self.busRead(addr),
                .write => |write| self.busWrite(write.addr, write.value),
                .idle => input = null,
            }
        }
    }

    pub fn busRead(self: *System, addr: u16) u8 {
        switch (addr) {
            // $0000-$1fff: 2KB internal RAM mirrored 4 times (every $0800)
            0x0000...0x1fff => return self.internalRam[addr & 0x07ff],

            // $2000-$3fff: PPU registers, mirrored every 8 bytes
            // $4000-$4013: APU and I/O registers
            // $4014: OAM DMA register
            // $4015: APU status register
            // $4016-$4017: controller and APU frame counter registers
            // $4018-$401f: APU/I/O functionality

            // $4020-$5fff: cart expansion area
            // $6000-$7fff: cart PRG-RAM
            // $8000-$ffff: cart PRG-ROM
            0x4020...0xffff => return self.mapper.read(addr),

            else => {
                std.debug.print("unimplemented read at addr: {x}", .{addr});
                return 0;
            },
        }
    }

    pub fn busWrite(self: *System, addr: u16, value: u8) void {
        switch (addr) {
            // same mappings as above
            0x0000...0x1fff => self.internalRam[addr & 0x07ff] = value,
            0x4020...0xffff => self.mapper.write(addr, value),
            else => {
                std.debug.print("unimplemented write at addr: {x}", .{addr});
            },
        }
    }
};

test "system executes LDA immediate" {
    const romdata = [_]u8{0} ** 0x4000;
    var nrom = mappers.Nrom.init(romdata[0..]);
    var system = System.init(nrom.mapper());
    const testPc: u16 = 0x0200;

    system.cpu.pc = testPc;
    system.busWrite(testPc, 0xa9);
    system.busWrite(testPc + 1, 0x80);
    system.tick();

    try testing.expectEqual(0x80, system.cpu.a);
    try testing.expect(!system.cpu.flags.z);
    try testing.expect(system.cpu.flags.n);
    try testing.expectEqual(testPc + 2, system.cpu.pc);
}

test "instructions execution" {
    const testPc: u16 = 0x0200;
    const cases = [_]struct {
        opcode: u8,
        register: cpu.Register8,
        operand: []const u8,
        valueAddr: u16,
        pointerAddr: ?u8 = null,
        pointerValue: u16 = 0,
        x: u8 = 0,
        y: u8 = 0,
    }{
        .{ .opcode = 0xa5, .register = .a, .operand = &.{0x80}, .valueAddr = 0x0080 }, // lda
        .{ .opcode = 0xa6, .register = .x, .operand = &.{0x80}, .valueAddr = 0x0080 }, // ldx
        .{ .opcode = 0xa4, .register = .y, .operand = &.{0x80}, .valueAddr = 0x0080 }, // ldy
        .{ .opcode = 0xb5, .register = .a, .operand = &.{0x80}, .valueAddr = 0x0084, .x = 0x04 }, // lda zero page,x
        .{ .opcode = 0xb4, .register = .y, .operand = &.{0x80}, .valueAddr = 0x0084, .x = 0x04 }, // ldy zero page,x
        .{ .opcode = 0xb6, .register = .x, .operand = &.{0x80}, .valueAddr = 0x0084, .y = 0x04 }, // ldx zero page,y
        .{ .opcode = 0xb5, .register = .a, .operand = &.{0xff}, .valueAddr = 0x0000, .x = 0x01 }, // zero page,x wraps
        .{ .opcode = 0xad, .register = .a, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234 }, // lda absolute
        .{ .opcode = 0xae, .register = .x, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234 }, // ldx absolute
        .{ .opcode = 0xac, .register = .y, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234 }, // ldy absolute
        .{ .opcode = 0xbd, .register = .a, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .x = 0x04 }, // lda absolute,x
        .{ .opcode = 0xb9, .register = .a, .operand = &.{ 0xff, 0x12 }, .valueAddr = 0x1300, .y = 0x01 }, // lda absolute,y page-cross
        .{ .opcode = 0xbe, .register = .x, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .y = 0x04 }, // ldx absolute,y
        .{ .opcode = 0xbc, .register = .y, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .x = 0x04 }, // ldy absolute,x
        .{ .opcode = 0xa1, .register = .a, .operand = &.{0x80}, .valueAddr = 0x1234, .pointerAddr = 0x84, .pointerValue = 0x1234, .x = 0x04 }, // lda (indirect,x)
        .{ .opcode = 0xa1, .register = .a, .operand = &.{0xff}, .valueAddr = 0x1234, .pointerAddr = 0x00, .pointerValue = 0x1234, .x = 0x01 }, // lda (indirect,x) wraps pointer
        .{ .opcode = 0xb1, .register = .a, .operand = &.{0x80}, .valueAddr = 0x1234, .pointerAddr = 0x80, .pointerValue = 0x1230, .y = 0x04 }, // lda (indirect),y
        .{ .opcode = 0xb1, .register = .a, .operand = &.{0xff}, .valueAddr = 0x1300, .pointerAddr = 0xff, .pointerValue = 0x12ff, .y = 0x01 }, // lda (indirect),y wraps pointer and page-crosses
    };

    for (cases) |case| {
        const romdata = [_]u8{0} ** 0x4000;
        var nrom = mappers.Nrom.init(romdata[0..]);
        var system = System.init(nrom.mapper());

        system.cpu.pc = testPc;
        system.cpu.x = case.x;
        system.cpu.y = case.y;
        system.busWrite(testPc, case.opcode);
        for (case.operand, 0..) |byte, index| {
            const operandAddr: u16 = testPc + @as(u16, @intCast(1 + index));
            system.busWrite(operandAddr, byte);
        }
        if (case.pointerAddr) |pointerAddr| {
            system.busWrite(pointerAddr, @truncate(case.pointerValue));
            system.busWrite(pointerAddr +% 1, @truncate(case.pointerValue >> 8));
        }
        system.busWrite(case.valueAddr, 0x42);

        system.tick();

        switch (case.register) {
            .a => try testing.expectEqual(0x42, system.cpu.a),
            .x => try testing.expectEqual(0x42, system.cpu.x),
            .y => try testing.expectEqual(0x42, system.cpu.y),
        }
        try testing.expect(!system.cpu.flags.z);
        try testing.expect(!system.cpu.flags.n);
        const expectedPc = testPc + @as(u16, @intCast(1 + case.operand.len));
        try testing.expectEqual(expectedPc, system.cpu.pc);
    }
}

test "micro-op instructions execution" {
    const testPc: u16 = 0x0200;
    const cases = [_]struct {
        opcode: u8,
        register: cpu.Register8,
        operand: []const u8,
        valueAddr: u16,
        pointerAddr: ?u8 = null,
        pointerValue: u16 = 0,
        x: u8 = 0,
        y: u8 = 0,
    }{
        .{ .opcode = 0xa5, .register = .a, .operand = &.{0x80}, .valueAddr = 0x0080 }, // lda
        .{ .opcode = 0xa6, .register = .x, .operand = &.{0x80}, .valueAddr = 0x0080 }, // ldx
        .{ .opcode = 0xa4, .register = .y, .operand = &.{0x80}, .valueAddr = 0x0080 }, // ldy
        .{ .opcode = 0xb5, .register = .a, .operand = &.{0x80}, .valueAddr = 0x0084, .x = 0x04 }, // lda zero page,x
        .{ .opcode = 0xb4, .register = .y, .operand = &.{0x80}, .valueAddr = 0x0084, .x = 0x04 }, // ldy zero page,x
        .{ .opcode = 0xb6, .register = .x, .operand = &.{0x80}, .valueAddr = 0x0084, .y = 0x04 }, // ldx zero page,y
        .{ .opcode = 0xb5, .register = .a, .operand = &.{0xff}, .valueAddr = 0x0000, .x = 0x01 }, // zero page,x wraps
        .{ .opcode = 0xad, .register = .a, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234 }, // lda absolute
        .{ .opcode = 0xae, .register = .x, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234 }, // ldx absolute
        .{ .opcode = 0xac, .register = .y, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234 }, // ldy absolute
        .{ .opcode = 0xbd, .register = .a, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .x = 0x04 }, // lda absolute,x
        .{ .opcode = 0xb9, .register = .a, .operand = &.{ 0xff, 0x12 }, .valueAddr = 0x1300, .y = 0x01 }, // lda absolute,y page-cross
        .{ .opcode = 0xbe, .register = .x, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .y = 0x04 }, // ldx absolute,y
        .{ .opcode = 0xbc, .register = .y, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .x = 0x04 }, // ldy absolute,x
        .{ .opcode = 0xa1, .register = .a, .operand = &.{0x80}, .valueAddr = 0x1234, .pointerAddr = 0x84, .pointerValue = 0x1234, .x = 0x04 }, // lda (indirect,x)
        .{ .opcode = 0xa1, .register = .a, .operand = &.{0xff}, .valueAddr = 0x1234, .pointerAddr = 0x00, .pointerValue = 0x1234, .x = 0x01 }, // lda (indirect,x) wraps pointer
        .{ .opcode = 0xb1, .register = .a, .operand = &.{0x80}, .valueAddr = 0x1234, .pointerAddr = 0x80, .pointerValue = 0x1230, .y = 0x04 }, // lda (indirect),y
        .{ .opcode = 0xb1, .register = .a, .operand = &.{0xff}, .valueAddr = 0x1300, .pointerAddr = 0xff, .pointerValue = 0x12ff, .y = 0x01 }, // lda (indirect),y wraps pointer and page-crosses
    };

    for (cases) |case| {
        const romdata = [_]u8{0} ** 0x4000;
        var nrom = mappers.Nrom.init(romdata[0..]);
        var system = System.init(nrom.mapper());

        system.cpu.pc = testPc;
        system.cpu.x = case.x;
        system.cpu.y = case.y;
        system.busWrite(testPc, case.opcode);
        for (case.operand, 0..) |byte, index| {
            const operandAddr: u16 = testPc + @as(u16, @intCast(1 + index));
            system.busWrite(operandAddr, byte);
        }
        if (case.pointerAddr) |pointerAddr| {
            system.busWrite(pointerAddr, @truncate(case.pointerValue));
            system.busWrite(pointerAddr +% 1, @truncate(case.pointerValue >> 8));
        }
        system.busWrite(case.valueAddr, 0x42);

        const opcode = opcodes.table[system.busRead(system.cpu.pc)];
        system.cpu.pc +%= 1;
        var instr = Instr2.init(opcode);
        var input: ?u8 = null;

        while (true) {
            const busOp = instr.step(&system.cpu, input) orelse break;
            switch (busOp) {
                .read => |addr| input = system.busRead(addr),
                .write => |write| system.busWrite(write.addr, write.value),
                .idle => input = null,
            }
        }

        switch (case.register) {
            .a => try testing.expectEqual(0x42, system.cpu.a),
            .x => try testing.expectEqual(0x42, system.cpu.x),
            .y => try testing.expectEqual(0x42, system.cpu.y),
        }
        try testing.expect(!system.cpu.flags.z);
        try testing.expect(!system.cpu.flags.n);
        const expectedPc = testPc + @as(u16, @intCast(1 + case.operand.len));
        try testing.expectEqual(expectedPc, system.cpu.pc);
    }
}

test "system writes/reads internal ram" {
    const romdata = [_]u8{0} ** 0x4000;
    var nrom = mappers.Nrom.init(romdata[0..]);
    var system = System.init(nrom.mapper());

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
        const romdata = [_]u8{0} ** 0x4000;
        var nrom = mappers.Nrom.init(romdata[0..]);
        var sys = System.init(nrom.mapper());
        sys.busWrite(case.addr, case.value);
        for ([_]u16{ 0, 0x800, 0x1000, 0x1800 }) |mirror| {
            try testing.expectEqual(case.value, sys.busRead(mirror + case.addr));
        }
    }
}
