const std = @import("std");

const testing = std.testing;

pub const MirrorMode = enum(u1) {
    horizontal = 0,
    vertical = 1,
};

pub const Cartridge = struct {
    data: []u8 = &[_]u8{},
    prgRom: []const u8 = &[_]u8{},
    prgBanks: u8 = 0,
    chrRom: []const u8 = &[_]u8{},
    chrBanks: u8 = 0,
    mapper: u8 = 0,
    mirrorMode: MirrorMode = .horizontal,
    hasChrRam: bool = false,
    hasBattery: bool = false,
};

pub const RomError = error{
    TooShort,
    InvalidMagic,
    EmptyPrgRom,
    UnsupportedMapper,
    UnexpectedSize,
};

pub const LoadError = RomError || std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError;

pub const inesHeaderSize = 16;
pub const prgBankSize = 16384;
pub const chrBankSize = 8192;

const inesMagic = [_]u8{ 0x4E, 0x45, 0x53, 0x1A };

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Cartridge {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    errdefer allocator.free(data);

    return parseINESData(data);
}

pub fn parseINESData(data: []u8) LoadError!Cartridge {
    if (data.len < inesHeaderSize) return error.TooShort;

    for (inesMagic, 0..) |byte, i| {
        if (data[i] != byte) return error.InvalidMagic;
    }

    const prgBanks = data[4];
    const chrBanks = data[5];
    const flags6 = data[6];

    if (prgBanks == 0) return error.EmptyPrgRom;

    const mapper = flags6 >> 4;
    if (mapper != 0) return error.UnsupportedMapper; // TODO add more mappers

    const prgSize = @as(usize, prgBanks) * prgBankSize;
    const chrSize = @as(usize, chrBanks) * chrBankSize;
    const prgStart = inesHeaderSize;
    const chrStart = prgStart + prgSize;
    const expectedSize = chrStart + chrSize;

    if (data.len < expectedSize) return error.UnexpectedSize;

    return .{
        .data = data,
        .prgRom = data[prgStart..chrStart],
        .prgBanks = prgBanks,
        .chrRom = if (chrSize > 0) data[chrStart..expectedSize] else &[_]u8{},
        .chrBanks = chrBanks,
        .mapper = mapper,
        .mirrorMode = @enumFromInt(flags6 & 1),
        .hasChrRam = chrBanks == 0,
        .hasBattery = flags6 & 0x02 != 0,
    };
}

pub fn deinit(cart: *Cartridge, allocator: std.mem.Allocator) void {
    allocator.free(cart.data);

    cart.* = .{
        .data = &[_]u8{},
        .prgRom = &[_]u8{},
        .prgBanks = 0,
        .chrRom = &[_]u8{},
        .chrBanks = 0,
        .mapper = 0,
        .mirrorMode = .horizontal,
        .hasChrRam = false,
        .hasBattery = false,
    };
}

test "cart parsing" {
    const romSize = inesHeaderSize + prgBankSize + chrBankSize;
    var rom = [_]u8{0} ** romSize;
    rom[0] = inesMagic[0];
    rom[1] = inesMagic[1];
    rom[2] = inesMagic[2];
    rom[3] = inesMagic[3];
    rom[4] = 1;
    rom[5] = 1;
    rom[6] = 0x03;
    rom[inesHeaderSize] = 0x12;
    rom[inesHeaderSize + prgBankSize] = 0x34;

    const allocator = testing.allocator;
    var cart = try parseINESData(try allocator.dupe(u8, &rom));
    defer deinit(&cart, allocator);

    try testing.expectEqual(1, cart.prgBanks);
    try testing.expectEqual(1, cart.chrBanks);
    try testing.expectEqual(0, cart.mapper);
    try testing.expectEqual(MirrorMode.vertical, cart.mirrorMode);
    try testing.expect(cart.hasBattery);
    try testing.expect(!cart.hasChrRam);
    try testing.expectEqual(prgBankSize, cart.prgRom.len);
    try testing.expectEqual(chrBankSize, cart.chrRom.len);
    try testing.expectEqual(0x12, cart.prgRom[0]);
    try testing.expectEqual(0x34, cart.chrRom[0]);
}
