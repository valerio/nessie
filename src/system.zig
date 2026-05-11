const std = @import("std");
const mappers = @import("mapper.zig");
const cpu = @import("cpu.zig");
const opcodes = @import("opcodes.zig");
const Mapper = mappers.Mapper;

const testing = std.testing;

const Cpu = cpu.Cpu;
const Instruction = cpu.Instruction;
const MicroOp = cpu.MicroOp;

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
                .internal => {},
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

    system.busWrite(0x0000, 0xa9);
    system.busWrite(0x0001, 0x80);
    system.tick();

    try testing.expectEqual(0x80, system.cpu.a);
    try testing.expect(!system.cpu.flags.z);
    try testing.expect(system.cpu.flags.n);
    try testing.expectEqual(0x0002, system.cpu.pc);
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
