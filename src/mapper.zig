const std = @import("std");

pub const Mapper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, addr: u16) u8,
        write: *const fn (ctx: *anyopaque, addr: u16, data: u8) void,
    };

    pub fn read(self: @This(), addr: u16) u8 {
        return self.vtable.read(self.ptr, addr);
    }

    pub fn write(self: @This(), addr: u16, data: u8) void {
        self.vtable.write(self.ptr, addr, data);
    }
};

/// Nrom, aka mapper 0.
pub const Nrom = struct {
    prgRom: []const u8,
    prgRam: [0x2000]u8 = [_]u8{0} ** 0x2000, // 8KiB

    const vtable: Mapper.VTable = .{
        .read = Nrom.read,
        .write = Nrom.write,
    };

    pub fn mapper(self: *Nrom) Mapper {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn init(prgRom: []const u8) Nrom {
        std.debug.assert(prgRom.len == 0x4000 or prgRom.len == 0x8000);
        return .{
            .prgRom = prgRom,
        };
    }

    fn asNrom(ctx: *anyopaque) *Nrom {
        return @ptrCast(@alignCast(ctx));
    }

    pub fn read(ctx: *anyopaque, addr: u16) u8 {
        const nrom = asNrom(ctx);

        switch (addr) {
            0x8000...0xffff => return nrom.prgRom[addr - 0x8000 & (nrom.prgRom.len - 1)],
            0x6000...0x7fff => return nrom.prgRam[addr & 0x1fff],
            else => return 0,
        }
    }

    pub fn write(ctx: *anyopaque, addr: u16, data: u8) void {
        const nrom = asNrom(ctx);

        switch (addr) {
            0x6000...0x7fff => nrom.prgRam[addr & 0x1fff] = data,
            else => {},
        }
    }
};

test "nrom reads and writes prg ram" {
    const prgRom = [_]u8{0} ** 0x4000;
    var nrom = Nrom.init(prgRom[0..]);
    const mapper = nrom.mapper();

    mapper.write(0x6002, 42);
    mapper.write(0x7ffe, 24);

    try std.testing.expectEqual(42, mapper.read(0x6002));
    try std.testing.expectEqual(24, mapper.read(0x7ffe));
}

test "nrom reads prg rom" {
    var prgRom = [_]u8{0} ** 0x4000;
    prgRom[0x0000] = 0x12;
    prgRom[0x3fff] = 0x34;

    var nrom = Nrom.init(prgRom[0..]);
    const mapper = nrom.mapper();

    try std.testing.expectEqual(0x12, mapper.read(0x8000));
    try std.testing.expectEqual(0x12, mapper.read(0xc000));
    try std.testing.expectEqual(0x34, mapper.read(0xbfff));
    try std.testing.expectEqual(0x34, mapper.read(0xffff));
}
