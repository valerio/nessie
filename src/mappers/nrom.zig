const std = @import("std");
const cart = @import("../cart.zig");

pub const prgRamSize = 8192;
pub const chrRamSize = cart.chrBankSize;

pub fn fromCart(c: *const cart.Cartridge) Nrom {
    return .{
        .prgRom = c.prgRom,
        .chrRom = c.chrRom,
        .hasChrRam = c.hasChrRam,
    };
}

pub fn fromData(data: []const u8) Nrom {
    return .{
        .prgRom = data,
        .chrRom = data,
        .hasChrRam = false,
    };
}

pub const Nrom = struct {
    prgRom: []const u8,
    chrRom: []const u8,
    prgRam: [prgRamSize]u8 = @splat(0),
    chrRam: [chrRamSize]u8 = @splat(0),
    hasChrRam: bool = false,

    pub fn read(self: *const Nrom, addr: u16) u8 {
        switch (addr) {
            0x0000...0x1fff => {
                if (self.hasChrRam) return self.chrRam[addr & 0x1fff];
                if (self.chrRom.len > 0) return self.chrRom[addr & 0x1fff];
                return 0;
            },
            0x6000...0x7fff => return self.prgRam[addr & 0x1fff],
            0x8000...0xffff => return self.prgRom[(addr - 0x8000) & (self.prgRom.len - 1)],
            else => return 0,
        }
    }

    pub fn write(self: *Nrom, addr: u16, data: u8) void {
        switch (addr) {
            0x0000...0x1fff => {
                if (self.hasChrRam) self.chrRam[addr & 0x1fff] = data;
            },
            0x6000...0x7fff => self.prgRam[addr & 0x1fff] = data,
            else => {},
        }
    }
};
