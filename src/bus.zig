const std = @import("std");
const testing = std.testing;

const addrSize = 0x10000;

pub const Bus = struct {
    mem: [addrSize]u8, // TODO: split ownership

    pub fn init() Bus {
        return .{
            .mem = [_]u8{0} ** (addrSize),
        };
    }

    pub fn read(self: *const Bus, addr: u16) u8 {
        return self.mem[addr];
    }

    pub fn write(self: *Bus, addr: u16, value: u8) void {
        self.mem[addr] = value;
    }
};

test "bus writes and reads" {
    var b = Bus.init();
    const addr = 0x1235;
    b.write(addr, 41);
    b.write(addr, 42);
    try testing.expectEqualDeep(42, b.read(addr));
}
