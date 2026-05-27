const std = @import("std");
const cart = @import("cart.zig");
const nrom = @import("mappers/nrom.zig");

pub const Mapper = union(enum) {
    nrom: nrom.Nrom,

    pub fn read(self: *const Mapper, addr: u16) u8 {
        return switch (self.*) {
            .nrom => |*m| m.read(addr),
        };
    }

    pub fn write(self: *Mapper, addr: u16, data: u8) void {
        switch (self.*) {
            .nrom => |*m| m.write(addr, data),
        }
    }
};

pub fn fromCart(c: *const cart.Cartridge) Mapper {
    return switch (c.mapper) {
        0 => .{ .nrom = nrom.fromCart(c) },
        else => std.debug.panic("unsupported mapper {}", .{c.mapper}),
    };
}

/// used in tests, returns an NROM-type mapper.
pub fn fromData(data: []const u8) Mapper {
    return .{ .nrom = .{ .prgRom = data, .chrRom = data } };
}
