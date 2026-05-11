const std = @import("std");
const Io = std.Io;

const nessie = @import("nessie");

pub fn main() void {
    std.debug.print("Hello, {s}!\n", .{"world"});
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
