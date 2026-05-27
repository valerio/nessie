//! By convention, root.zig is the root source file when making a package.

pub const cpu = @import("cpu.zig");
pub const system = @import("system.zig");
pub const ppu = @import("ppu.zig");

pub const System = system.System;

pub const screenWidth = ppu.screenWidth;
pub const screenHeight = ppu.screenHeight;
pub const paletteColorCount = ppu.paletteColorCount;
pub const paletteRgb = ppu.paletteRgb;

test {
    _ = @import("cpu.zig");
    _ = @import("system.zig");
    _ = @import("mapper.zig");
    _ = @import("opcodes.zig");
    _ = @import("addressing.zig");
    _ = @import("instructions.zig");
    _ = @import("ppu.zig");
    _ = @import("cart.zig");
}
