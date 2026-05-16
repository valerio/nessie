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
    const Setup = struct {
        a: u8 = 0,
        x: u8 = 0,
        y: u8 = 0,
        flags: u8 = 0x24,
        read: ?struct { addr: u16, value: u8 = 0x42 } = null,
        ptr: ?struct { addr: u8, value: u16 } = null,
        addrPtr: ?struct { addr: u16, value: u16 } = null,
    };
    const Want = struct {
        a: u8 = 0,
        x: u8 = 0,
        y: u8 = 0,
        flags: u8 = 0x24,
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
        .{ .opcode = 0xea, .setup = .{ .a = 0x11, .x = 0x22, .y = 0x33, .flags = 0x25 }, .want = .{ .a = 0x11, .x = 0x22, .y = 0x33, .flags = 0x25 } }, // nop
        .{ .opcode = 0xaa, .setup = .{ .a = 0x80, .x = 0x11 }, .want = .{ .a = 0x80, .x = 0x80, .flags = 0xa4 } }, // tax
        .{ .opcode = 0x8a, .setup = .{ .a = 0x42, .x = 0x80 }, .want = .{ .a = 0x80, .x = 0x80, .flags = 0xa4 } }, // txa
        .{ .opcode = 0xa8, .setup = .{ .a = 0x42, .y = 0x11 }, .want = .{ .a = 0x42, .y = 0x42 } }, // tay
        .{ .opcode = 0x98, .setup = .{ .a = 0x42, .y = 0x80 }, .want = .{ .a = 0x80, .y = 0x80, .flags = 0xa4 } }, // tya
        .{ .opcode = 0xe8, .setup = .{ .x = 0xff }, .want = .{ .x = 0x00, .flags = 0x26 } }, // inx wraps
        .{ .opcode = 0xca, .setup = .{ .x = 0x00 }, .want = .{ .x = 0xff, .flags = 0xa4 } }, // dex wraps
        .{ .opcode = 0xc8, .setup = .{ .y = 0x7f }, .want = .{ .y = 0x80, .flags = 0xa4 } }, // iny
        .{ .opcode = 0x88, .setup = .{ .y = 0x01 }, .want = .{ .y = 0x00, .flags = 0x26 } }, // dey
        .{ .opcode = 0x18, .setup = .{ .flags = 0x25 } }, // clc
        .{ .opcode = 0x38, .want = .{ .flags = 0x25 } }, // sec
        .{ .opcode = 0x58, .want = .{ .flags = 0x20 } }, // cli
        .{ .opcode = 0x78, .setup = .{ .flags = 0x20 }, .want = .{ .flags = 0x24 } }, // sei

        .{ .opcode = 0xa9, .operand = &.{0x42}, .want = .{ .a = 0x42 } }, // lda immediate
        .{ .opcode = 0xa2, .operand = &.{0x42}, .want = .{ .x = 0x42 } }, // ldx immediate
        .{ .opcode = 0xa0, .operand = &.{0x42}, .want = .{ .y = 0x42 } }, // ldy immediate
        .{ .opcode = 0xa5, .operand = &.{0x80}, .setup = .{ .read = .{ .addr = 0x0080 } }, .want = .{ .a = 0x42 } }, // lda
        .{ .opcode = 0xa6, .operand = &.{0x80}, .setup = .{ .read = .{ .addr = 0x0080 } }, .want = .{ .x = 0x42 } }, // ldx
        .{ .opcode = 0xa4, .operand = &.{0x80}, .setup = .{ .read = .{ .addr = 0x0080 } }, .want = .{ .y = 0x42 } }, // ldy
        .{ .opcode = 0xb5, .operand = &.{0x80}, .setup = .{ .x = 0x04, .read = .{ .addr = 0x0084 } }, .want = .{ .a = 0x42, .x = 0x04 } }, // lda zero page,x
        .{ .opcode = 0xb4, .operand = &.{0x80}, .setup = .{ .x = 0x04, .read = .{ .addr = 0x0084 } }, .want = .{ .x = 0x04, .y = 0x42 } }, // ldy zero page,x
        .{ .opcode = 0xb6, .operand = &.{0x80}, .setup = .{ .y = 0x04, .read = .{ .addr = 0x0084 } }, .want = .{ .x = 0x42, .y = 0x04 } }, // ldx zero page,y
        .{ .opcode = 0xb5, .operand = &.{0xff}, .setup = .{ .x = 0x01, .read = .{ .addr = 0x0000 } }, .want = .{ .a = 0x42, .x = 0x01 } }, // zero page,x wraps
        .{ .opcode = 0xad, .operand = &.{ 0x34, 0x12 }, .setup = .{ .read = .{ .addr = 0x1234 } }, .want = .{ .a = 0x42 } }, // lda absolute
        .{ .opcode = 0xae, .operand = &.{ 0x34, 0x12 }, .setup = .{ .read = .{ .addr = 0x1234 } }, .want = .{ .x = 0x42 } }, // ldx absolute
        .{ .opcode = 0xac, .operand = &.{ 0x34, 0x12 }, .setup = .{ .read = .{ .addr = 0x1234 } }, .want = .{ .y = 0x42 } }, // ldy absolute
        .{ .opcode = 0xbd, .operand = &.{ 0x30, 0x12 }, .setup = .{ .x = 0x04, .read = .{ .addr = 0x1234 } }, .want = .{ .a = 0x42, .x = 0x04 } }, // lda absolute,x
        .{ .opcode = 0xb9, .operand = &.{ 0xff, 0x12 }, .setup = .{ .y = 0x01, .read = .{ .addr = 0x1300 } }, .want = .{ .a = 0x42, .y = 0x01 } }, // lda absolute,y page-cross
        .{ .opcode = 0xbe, .operand = &.{ 0x30, 0x12 }, .setup = .{ .y = 0x04, .read = .{ .addr = 0x1234 } }, .want = .{ .x = 0x42, .y = 0x04 } }, // ldx absolute,y
        .{ .opcode = 0xbc, .operand = &.{ 0x30, 0x12 }, .setup = .{ .x = 0x04, .read = .{ .addr = 0x1234 } }, .want = .{ .x = 0x04, .y = 0x42 } }, // ldy absolute,x
        .{ .opcode = 0xa1, .operand = &.{0x80}, .setup = .{ .x = 0x04, .read = .{ .addr = 0x1234 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x42, .x = 0x04 } }, // lda (indirect,x)
        .{ .opcode = 0xa1, .operand = &.{0xff}, .setup = .{ .x = 0x01, .read = .{ .addr = 0x1234 }, .ptr = .{ .addr = 0x00, .value = 0x1234 } }, .want = .{ .a = 0x42, .x = 0x01 } }, // lda (indirect,x) wraps pointer
        .{ .opcode = 0xb1, .operand = &.{0x80}, .setup = .{ .y = 0x04, .read = .{ .addr = 0x1234 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x42, .y = 0x04 } }, // lda (indirect),y
        .{ .opcode = 0xb1, .operand = &.{0xff}, .setup = .{ .y = 0x01, .read = .{ .addr = 0x1300 }, .ptr = .{ .addr = 0xff, .value = 0x12ff } }, .want = .{ .a = 0x42, .y = 0x01 } }, // lda (indirect),y wraps pointer and page-crosses

        .{ .opcode = 0x29, .operand = &.{0x0f}, .setup = .{ .a = 0xf3 }, .want = .{ .a = 0x03 } }, // and immediate
        .{ .opcode = 0x25, .operand = &.{0x80}, .setup = .{ .a = 0xf0, .read = .{ .addr = 0x0080, .value = 0x0f } }, .want = .{ .a = 0x00, .flags = 0x26 } }, // and zero page sets z
        .{ .opcode = 0x35, .operand = &.{0x80}, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x80 } }, .want = .{ .a = 0x80, .x = 0x04, .flags = 0xa4 } }, // and zero page,x sets n
        .{ .opcode = 0x2d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0xf3, .read = .{ .addr = 0x1234, .value = 0x0f } }, .want = .{ .a = 0x03 } }, // and absolute
        .{ .opcode = 0x3d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x7f } }, .want = .{ .a = 0x7f, .x = 0x04 } }, // and absolute,x
        .{ .opcode = 0x39, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0xff, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x40 } }, .want = .{ .a = 0x40, .y = 0x01 } }, // and absolute,y page-cross
        .{ .opcode = 0x21, .operand = &.{0x80}, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x22 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x22, .x = 0x04 } }, // and (indirect,x)
        .{ .opcode = 0x31, .operand = &.{0x80}, .setup = .{ .a = 0xff, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x11 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x11, .y = 0x04 } }, // and (indirect),y

        .{ .opcode = 0x09, .operand = &.{0x0f}, .setup = .{ .a = 0xf0 }, .want = .{ .a = 0xff, .flags = 0xa4 } }, // ora immediate
        .{ .opcode = 0x05, .operand = &.{0x80}, .setup = .{ .a = 0x00, .read = .{ .addr = 0x0080, .value = 0x00 } }, .want = .{ .a = 0x00, .flags = 0x26 } }, // ora zero page sets z
        .{ .opcode = 0x15, .operand = &.{0x80}, .setup = .{ .a = 0x01, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x02 } }, .want = .{ .a = 0x03, .x = 0x04 } }, // ora zero page,x
        .{ .opcode = 0x0d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x10, .read = .{ .addr = 0x1234, .value = 0x02 } }, .want = .{ .a = 0x12 } }, // ora absolute
        .{ .opcode = 0x1d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0x40, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x80 } }, .want = .{ .a = 0xc0, .x = 0x04, .flags = 0xa4 } }, // ora absolute,x
        .{ .opcode = 0x19, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0x20, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x01 } }, .want = .{ .a = 0x21, .y = 0x01 } }, // ora absolute,y page-cross
        .{ .opcode = 0x01, .operand = &.{0x80}, .setup = .{ .a = 0x01, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x04 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x05, .x = 0x04 } }, // ora (indirect,x)
        .{ .opcode = 0x11, .operand = &.{0x80}, .setup = .{ .a = 0x01, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x08 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x09, .y = 0x04 } }, // ora (indirect),y

        .{ .opcode = 0x49, .operand = &.{0xff}, .setup = .{ .a = 0x0f }, .want = .{ .a = 0xf0, .flags = 0xa4 } }, // eor immediate
        .{ .opcode = 0x45, .operand = &.{0x80}, .setup = .{ .a = 0xaa, .read = .{ .addr = 0x0080, .value = 0xaa } }, .want = .{ .a = 0x00, .flags = 0x26 } }, // eor zero page sets z
        .{ .opcode = 0x55, .operand = &.{0x80}, .setup = .{ .a = 0x0f, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0xf0 } }, .want = .{ .a = 0xff, .x = 0x04, .flags = 0xa4 } }, // eor zero page,x
        .{ .opcode = 0x4d, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0xf0, .read = .{ .addr = 0x1234, .value = 0x0f } }, .want = .{ .a = 0xff, .flags = 0xa4 } }, // eor absolute
        .{ .opcode = 0x5d, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0xff, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x7f } }, .want = .{ .a = 0x80, .x = 0x04, .flags = 0xa4 } }, // eor absolute,x
        .{ .opcode = 0x59, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0xff, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0xfe } }, .want = .{ .a = 0x01, .y = 0x01 } }, // eor absolute,y page-cross
        .{ .opcode = 0x41, .operand = &.{0x80}, .setup = .{ .a = 0xf0, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x0f }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0xff, .x = 0x04, .flags = 0xa4 } }, // eor (indirect,x)
        .{ .opcode = 0x51, .operand = &.{0x80}, .setup = .{ .a = 0x0f, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x0e }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x01, .y = 0x04 } }, // eor (indirect),y

        .{ .opcode = 0xc9, .operand = &.{0x40}, .setup = .{ .a = 0x40 }, .want = .{ .a = 0x40, .flags = 0x27 } }, // cmp immediate equal
        .{ .opcode = 0xc5, .operand = &.{0x80}, .setup = .{ .a = 0x20, .read = .{ .addr = 0x0080, .value = 0x40 } }, .want = .{ .a = 0x20, .flags = 0xa4 } }, // cmp zero page less
        .{ .opcode = 0xd5, .operand = &.{0x80}, .setup = .{ .a = 0x50, .x = 0x04, .read = .{ .addr = 0x0084, .value = 0x40 } }, .want = .{ .a = 0x50, .x = 0x04, .flags = 0x25 } }, // cmp zero page,x greater
        .{ .opcode = 0xcd, .operand = &.{ 0x34, 0x12 }, .setup = .{ .a = 0x40, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .a = 0x40, .flags = 0x27 } }, // cmp absolute equal
        .{ .opcode = 0xdd, .operand = &.{ 0x30, 0x12 }, .setup = .{ .a = 0x50, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x40 } }, .want = .{ .a = 0x50, .x = 0x04, .flags = 0x25 } }, // cmp absolute,x
        .{ .opcode = 0xd9, .operand = &.{ 0xff, 0x12 }, .setup = .{ .a = 0x20, .y = 0x01, .read = .{ .addr = 0x1300, .value = 0x40 } }, .want = .{ .a = 0x20, .y = 0x01, .flags = 0xa4 } }, // cmp absolute,y page-cross
        .{ .opcode = 0xc1, .operand = &.{0x80}, .setup = .{ .a = 0x40, .x = 0x04, .read = .{ .addr = 0x1234, .value = 0x40 }, .ptr = .{ .addr = 0x84, .value = 0x1234 } }, .want = .{ .a = 0x40, .x = 0x04, .flags = 0x27 } }, // cmp (indirect,x)
        .{ .opcode = 0xd1, .operand = &.{0x80}, .setup = .{ .a = 0x50, .y = 0x04, .read = .{ .addr = 0x1234, .value = 0x40 }, .ptr = .{ .addr = 0x80, .value = 0x1230 } }, .want = .{ .a = 0x50, .y = 0x04, .flags = 0x25 } }, // cmp (indirect),y

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
        .{ .opcode = 0x6c, .operand = &.{ 0x34, 0x12 }, .setup = .{ .addrPtr = .{ .addr = 0x1234, .value = 0xabcd } }, .want = .{ .pc = 0xabcd } }, // jmp indirect
        .{ .opcode = 0x6c, .operand = &.{ 0xff, 0x13 }, .setup = .{ .addrPtr = .{ .addr = 0x13ff, .value = 0xabcd } }, .want = .{ .pc = 0xabcd } }, // jmp indirect wraps pointer high byte

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

        const romdata = [_]u8{0} ** 0x4000;
        var nrom = mappers.Nrom.init(romdata[0..]);
        var system = System.init(nrom.mapper());

        system.cpu.pc = testPc;
        system.cpu.a = case.setup.a;
        system.cpu.x = case.setup.x;
        system.cpu.y = case.setup.y;
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

        system.tick();

        try testing.expectEqual(case.want.a, system.cpu.a);
        try testing.expectEqual(case.want.x, system.cpu.x);
        try testing.expectEqual(case.want.y, system.cpu.y);
        try testing.expectEqual(case.want.flags, system.cpu.flags.toByte());
        if (case.want.mem) |mem| {
            try testing.expectEqual(mem.value, system.busRead(mem.addr));
        }
        const wantPc = case.want.pc orelse testPc + @as(u16, @intCast(1 + case.operand.len));
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
