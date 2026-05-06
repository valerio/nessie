//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const cpu = @import("cpu.zig");

test {
    _ = @import("cpu.zig");
    _ = @import("bus.zig");
    _ = @import("system.zig");
}
