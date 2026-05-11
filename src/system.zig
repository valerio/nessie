const std = @import("std");
const mappers = @import("mapper.zig");
const opcodes = @import("opcodes.zig");
const Mapper = mappers.Mapper;

const testing = std.testing;

const Cpu = @import("cpu.zig").Cpu;

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
        const opcode = self.busRead(self.cpu.pc);
        self.cpu.pc +%= 1;

        // const instr = opcodes.table[opcode];
        // TODO:
        // - fetch operands
        // - decompose into micro-ops
        // - execute micro-ops

        // TODO: decompose instructions into micro-ops and run until completion
        switch (opcode) {
            0xEA => {}, // Nop
            else => {
                std.debug.panic("{} is unimplemented", .{opcode});
            },
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

test "system ticks NOP" {
    const romdata = [_]u8{0} ** 0x4000;
    var nrom = mappers.Nrom.init(romdata[0..]);
    var system = System.init(nrom.mapper());
    system.busWrite(system.cpu.pc, 0xea);
    system.tick();
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
