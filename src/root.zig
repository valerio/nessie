//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const cpu = @import("cpu.zig");
pub const System = @import("system.zig").System;

test {
    _ = @import("cpu.zig");
    _ = @import("system.zig");
    _ = @import("mapper.zig");
    _ = @import("opcodes.zig");
    _ = @import("addressing.zig");
}
