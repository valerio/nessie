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
        // TODO: handle mirroring
        // TODO: dispatch to components
        if (addr >= 0x800) {
            std.debug.print("unimplemeted read at addr: {x}\n", .{addr});
            return 0;
        }

        return self.internalRam[addr];
    }

    pub fn busWrite(self: *System, addr: u16, value: u8) void {
        if (addr >= 0x800) {
            std.debug.print("unimplemeted write at addr: {x}\n", .{addr});
            return;
        }

        self.internalRam[addr] = value;
    }
};

test "system ticks NOP" {
    var system = System.init();
    system.busWrite(system.cpu.pc, 0xEA);
    system.tick();
}

test "system writes/reads internal ram" {
    var system = System.init();

    system.busWrite(0xff, 0xff);
    try testing.expectEqual(0, system.cpu.pc);
    try testing.expectEqual(0xff, system.busRead(0xff));
}
