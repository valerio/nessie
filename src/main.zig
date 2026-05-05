const std = @import("std");
const Io = std.Io;

const nes_zig_spike = @import("nes_zig_spike");

/// A 16 bit register
const Register = struct {
    /// the inner value of the register
    value: u16,
};

const IRQ = enum {
    none,
    nmi,
    vblank,
};

const irqs: []const IRQ = &[_]IRQ{
    .none,
    .nmi,
    .vblank,
};

// 8kB VRAM zero initialized
const vram = [_]u8{0} ** 8192;

const Vram = struct {
    data: [128]u8,
};

pub fn main() void {
    const vroom = Vram{
        .data = [_]u8{0} ** 128,
    };

    std.debug.print("x: {}, y: {}, z: {}\n", .{ irqs[0], irqs[1], irqs[2] });

    std.debug.print("Hello, {s}!\n", .{"world"});
    std.debug.print("Hello, {}!\n", .{vroom});
}

fn fib(n: i32) i32 {
    if (n <= 1) {
        return 1;
    }
    return n + fib(n - 1);
}

test "simple test" {
    try std.testing.expectEqual(2, 2);
}

test fib {
    try std.testing.expectEqual(3, fib(2));
}
