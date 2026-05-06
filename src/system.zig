const std = @import("std");
const testing = std.testing;

const Cpu = @import("cpu.zig").Cpu;

const internalRamSize = 0x800; // 2KB

pub const System = struct {
    cpu: Cpu,
    internalRam: [internalRamSize]u8,

    pub fn init() System {
        return .{
            .cpu = Cpu.init(),
            .internalRam = [_]u8{0} ** (internalRamSize),
        };
        // TODO: set PC based on 0xfffc and 0xfffd
        // self.cpu.pc = self.busRead(0xfffc);
    }

    pub fn tick(self: *System) void {
        const opcode = self.busRead(self.cpu.pc);
        self.cpu.pc +%= 1;

        // TODO: decompose instructions into micro-ops and run until completion
        switch (opcode) {
            0xEA => {}, // Nop
            else => {
                std.debug.panic("{} is unimplemented", .{opcode});
            },
        }
    }

    pub fn busRead(self: *System, addr: u16) u8 {
        // TODO: dispatch to components
        switch (addr) {
            // mirrored internal ram.
            0x0000...0x07ff => return self.internalRam[addr],
            0x0800...0x0fff => return self.internalRam[addr - 0x0800],
            0x1000...0x17ff => return self.internalRam[addr - 0x1000],
            0x1800...0x1fff => return self.internalRam[addr - 0x1800],

            else => {
                std.debug.print("unimplemented read at addr: {x}", .{addr});
                return 0;
            },
        }
    }

    pub fn busWrite(self: *System, addr: u16, value: u8) void {
        switch (addr) {
            0x0000...0x07ff => self.internalRam[addr] = value,
            0x0800...0x0fff => self.internalRam[addr - 0x0800] = value,
            0x1000...0x17ff => self.internalRam[addr - 0x1000] = value,
            0x1800...0x1fff => self.internalRam[addr - 0x1800] = value,
            else => {
                std.debug.print("unimplemented write at addr: {x}", .{addr});
            },
        }
    }
};

test "system ticks NOP" {
    var system = System.init();
    system.busWrite(system.cpu.pc, 0xea);
    system.tick();
}

test "system writes/reads internal ram" {
    var system = System.init();

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
        var sys = System.init();
        sys.busWrite(case.addr, case.value);
        for ([_]u16{ 0, 0x800, 0x1000, 0x1800 }) |mirror| {
            try testing.expectEqual(case.value, sys.busRead(mirror + case.addr));
        }
    }
}
