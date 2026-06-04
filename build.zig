const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("nessie", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const cliExe = b.addExecutable(.{
        .name = "nessie-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nessie", .module = mod },
            },
        }),
    });

    b.installArtifact(cliExe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(cliExe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = cliExe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    buildAccuracyCoinHarness(b, mod, target);
    buildRaylib(b, mod, target, optimize);
}

fn buildAccuracyCoinHarness(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    const acExe = b.addExecutable(.{
        .name = "nessie-accuracycoin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/accuracycoin/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "nessie", .module = mod },
            },
        }),
    });

    const runAc = b.addRunArtifact(acExe);
    b.step("accuracycoin", "Run AccuracyCoin harness").dependOn(&runAc.step);

    if (b.args) |args| {
        runAc.addArgs(args);
    }
}

fn buildRaylib(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const raylib_zig = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const rl_exe = b.addExecutable(.{
        .name = "nessie-rl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/raylib/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nessie", .module = mod },
                .{ .name = "raylib", .module = raylib_zig.module("raylib") },
            },
        }),
    });

    rl_exe.root_module.linkLibrary(raylib_zig.artifact("raylib"));
    const install_rl = b.addInstallArtifact(rl_exe, .{});

    const rl_build_step = b.step("raylib", "Build raylib app");
    rl_build_step.dependOn(&rl_exe.step);
    rl_build_step.dependOn(&install_rl.step);

    const rl_run_cmd = b.addRunArtifact(rl_exe);
    b.step("run-rl", "Run raylib app").dependOn(&rl_run_cmd.step);

    if (b.args) |args| {
        rl_run_cmd.addArgs(args);
    }
}
