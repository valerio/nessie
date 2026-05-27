const std = @import("std");
const nessie = @import("nessie");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("usage: nessie-cli <rom.nes> [frames]\n", .{});
        return;
    }

    const path = args[1];
    var frames: u64 = 1;
    if (args.len >= 3) {
        frames = try std.fmt.parseInt(u64, args[2], 10);
    }

    var sys = try nessie.System.initFromFile(allocator, init.io, path);
    defer sys.deinit(allocator);
    std.debug.print(
        "loaded {s}: pc ${x:0>4}, mapper {d}\n",
        .{ path, sys.cpu.pc, sys.cartridge.mapper },
    );

    while (sys.frameCounter < frames) {
        sys.runFrame();

        if (sys.frameCounter % 100 == 0) {
            std.debug.print("... {d} frames\n", .{sys.frameCounter});
        }
    }

    std.debug.print("ran {d} frame(s), pc ${x:0>4}, frame counter {d}\n", .{
        frames,
        sys.cpu.pc,
        sys.frameCounter,
    });
}
