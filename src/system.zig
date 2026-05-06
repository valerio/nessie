const std = @import("std");
const testing = std.testing;

const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;

pub const System = struct {
    cpu: Cpu,
    bus: Bus,

    pub fn init() System {
        return .{
            .cpu = Cpu.init(),
            .bus = Bus.init(),
        };
    }

    pub fn reset(self: *System) void {
        self.cpu = Cpu.init();
        self.cpu.pc = self.bus.read(0xfffc);
    }

    pub fn tick(self: *System) void {
        const opcode = self.bus.read(self.cpu.pc);
        self.cpu.pc +%= 1;

        switch (opcode) {
            0xEA => {}, // Nop
            else => {
                std.debug.panic("{} is unimplemented", .{opcode});
            },
        }
    }
};

test "system ticks NOP" {
    var system = System.init();
    system.bus.write(system.cpu.pc, 0xEA);
    system.tick();
}

test "system resets" {
    var system = System.init();
    system.bus.write(0xfffc, 0xff);
    system.reset();
    try testing.expectEqual(0xff, system.cpu.pc);
}
