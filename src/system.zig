const std = @import("std");
const mappers = @import("mapper.zig");
const cpu = @import("cpu.zig");
const opcodes = @import("opcodes.zig");
const Mapper = mappers.Mapper;

const testing = std.testing;

const Cpu = cpu.Cpu;
const Instruction = cpu.Instruction;
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

        while (true) {
            const busOp = instr.step(&self.cpu, input) orelse break;
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
    const testCases = [_]struct {
        opcode: u8,
        operand: []const u8 = &.{},
        valueAddr: ?u16 = null,
        pointerAddr: ?u8 = null,
        pointerValue: u16 = 0,
        a: u8 = 0,
        x: u8 = 0,
        y: u8 = 0,
        flags: u8 = 0x24,
        wantA: ?u8 = null,
        wantX: ?u8 = null,
        wantY: ?u8 = null,
        wantFlags: u8 = 0x24,
    }{
        .{ .opcode = 0xea }, // nop
        .{ .opcode = 0xaa, .a = 0x80, .wantX = 0x80, .wantFlags = 0b10100100 }, // tax
        .{ .opcode = 0x8a, .a = 0x42, .wantA = 0x00, .wantFlags = 0b00100110 }, // txa
        .{ .opcode = 0xa8, .a = 0x42, .wantY = 0x42 }, // tay
        .{ .opcode = 0x98, .y = 0x80, .wantA = 0x80, .wantFlags = 0b10100100 }, // tya
        .{ .opcode = 0xe8, .x = 0xff, .wantX = 0x00, .wantFlags = 0b00100110 }, // inx wraps
        .{ .opcode = 0xca, .x = 0x00, .wantX = 0xff, .wantFlags = 0b10100100 }, // dex wraps
        .{ .opcode = 0xc8, .y = 0x7f, .wantY = 0x80, .wantFlags = 0b10100100 }, // iny
        .{ .opcode = 0x88, .y = 0x01, .wantY = 0x00, .wantFlags = 0b00100110 }, // dey
        .{ .opcode = 0x18, .flags = 0x25 }, // clc
        .{ .opcode = 0x38, .wantFlags = 0b100101 }, // sec
        .{ .opcode = 0x58, .wantFlags = 0b100000 }, // cli
        .{ .opcode = 0x78 }, // sei

        .{ .opcode = 0xa9, .operand = &.{0x42}, .wantA = 0x42 }, // lda immediate
        .{ .opcode = 0xa2, .operand = &.{0x42}, .wantX = 0x42 }, // ldx immediate
        .{ .opcode = 0xa0, .operand = &.{0x42}, .wantY = 0x42 }, // ldy immediate
        .{ .opcode = 0xa5, .operand = &.{0x80}, .valueAddr = 0x0080, .wantA = 0x42 }, // lda
        .{ .opcode = 0xa6, .operand = &.{0x80}, .valueAddr = 0x0080, .wantX = 0x42 }, // ldx
        .{ .opcode = 0xa4, .operand = &.{0x80}, .valueAddr = 0x0080, .wantY = 0x42 }, // ldy
        .{ .opcode = 0xb5, .operand = &.{0x80}, .valueAddr = 0x0084, .x = 0x04, .wantA = 0x42 }, // lda zero page,x
        .{ .opcode = 0xb4, .operand = &.{0x80}, .valueAddr = 0x0084, .x = 0x04, .wantY = 0x42 }, // ldy zero page,x
        .{ .opcode = 0xb6, .operand = &.{0x80}, .valueAddr = 0x0084, .y = 0x04, .wantX = 0x42 }, // ldx zero page,y
        .{ .opcode = 0xb5, .operand = &.{0xff}, .valueAddr = 0x0000, .x = 0x01, .wantA = 0x42 }, // zero page,x wraps
        .{ .opcode = 0xad, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234, .wantA = 0x42 }, // lda absolute
        .{ .opcode = 0xae, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234, .wantX = 0x42 }, // ldx absolute
        .{ .opcode = 0xac, .operand = &.{ 0x34, 0x12 }, .valueAddr = 0x1234, .wantY = 0x42 }, // ldy absolute
        .{ .opcode = 0xbd, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .x = 0x04, .wantA = 0x42 }, // lda absolute,x
        .{ .opcode = 0xb9, .operand = &.{ 0xff, 0x12 }, .valueAddr = 0x1300, .y = 0x01, .wantA = 0x42 }, // lda absolute,y page-cross
        .{ .opcode = 0xbe, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .y = 0x04, .wantX = 0x42 }, // ldx absolute,y
        .{ .opcode = 0xbc, .operand = &.{ 0x30, 0x12 }, .valueAddr = 0x1234, .x = 0x04, .wantY = 0x42 }, // ldy absolute,x
        .{ .opcode = 0xa1, .operand = &.{0x80}, .valueAddr = 0x1234, .pointerAddr = 0x84, .pointerValue = 0x1234, .x = 0x04, .wantA = 0x42 }, // lda (indirect,x)
        .{ .opcode = 0xa1, .operand = &.{0xff}, .valueAddr = 0x1234, .pointerAddr = 0x00, .pointerValue = 0x1234, .x = 0x01, .wantA = 0x42 }, // lda (indirect,x) wraps pointer
        .{ .opcode = 0xb1, .operand = &.{0x80}, .valueAddr = 0x1234, .pointerAddr = 0x80, .pointerValue = 0x1230, .y = 0x04, .wantA = 0x42 }, // lda (indirect),y
        .{ .opcode = 0xb1, .operand = &.{0xff}, .valueAddr = 0x1300, .pointerAddr = 0xff, .pointerValue = 0x12ff, .y = 0x01, .wantA = 0x42 }, // lda (indirect),y wraps pointer and page-crosses
    };

    for (testCases) |case| {
        const romdata = [_]u8{0} ** 0x4000;
        var nrom = mappers.Nrom.init(romdata[0..]);
        var system = System.init(nrom.mapper());

        system.cpu.pc = testPc;
        system.cpu.a = case.a;
        system.cpu.x = case.x;
        system.cpu.y = case.y;
        system.cpu.flags = cpu.Flags.fromByte(case.flags);
        system.busWrite(testPc, case.opcode);
        for (case.operand, 0..) |byte, index| {
            const operandAddr: u16 = testPc + @as(u16, @intCast(1 + index));
            system.busWrite(operandAddr, byte);
        }
        if (case.pointerAddr) |pointerAddr| {
            system.busWrite(pointerAddr, @truncate(case.pointerValue));
            system.busWrite(pointerAddr +% 1, @truncate(case.pointerValue >> 8));
        }
        if (case.valueAddr) |valueAddr| system.busWrite(valueAddr, 0x42);

        system.tick();

        try testing.expectEqual(case.wantA orelse case.a, system.cpu.a);
        try testing.expectEqual(case.wantX orelse case.x, system.cpu.x);
        try testing.expectEqual(case.wantY orelse case.y, system.cpu.y);
        try testing.expectEqual(case.wantFlags, system.cpu.flags.toByte());
        const wantPc = testPc + @as(u16, @intCast(1 + case.operand.len));
        try testing.expectEqual(wantPc, system.cpu.pc);
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
