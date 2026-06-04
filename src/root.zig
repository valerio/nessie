//! By convention, root.zig is the root source file when making a package.

pub const cpu = @import("cpu.zig");
pub const apu = @import("apu.zig");
pub const dmc = @import("dmc.zig");
pub const input = @import("input.zig");
pub const system = @import("system.zig");
pub const ppu = @import("ppu.zig");

pub const System = system.System;

pub const screenWidth = ppu.screenWidth;
pub const screenHeight = ppu.screenHeight;
pub const paletteColorCount = ppu.paletteColorCount;
pub const paletteRgb = ppu.paletteRgb;
pub const audioSampleRate = apu.sampleRate;
pub const buttons = input.buttons;

test {
    _ = @import("cpu.zig");
    _ = @import("apu.zig");
    _ = @import("dmc.zig");
    _ = @import("input.zig");
    _ = @import("system.zig");
    _ = @import("mapper.zig");
    _ = @import("opcodes.zig");
    _ = @import("addressing.zig");
    _ = @import("instructions.zig");
    _ = @import("ppu.zig");
    _ = @import("cart.zig");
}
