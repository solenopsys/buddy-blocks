const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Подключаем зависимости
    const libxev = b.dependency("libxev", .{});
    const picozig = b.dependency("picozig", .{});

    const mod = b.addModule("fastblock", .{
        .root_source_file = b.path("src/root.zig"),

        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "fastblock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "fastblock", .module = mod },
                .{ .name = "xev", .module = libxev.module("xev") },
                .{ .name = "picozig", .module = picozig.module("picozig") },
            },
        }),
    });

    // Линкуем с liblmdbx.so
    exe.addLibraryPath(b.path("../zig-lmdbx/zig-out/lib"));
    exe.linkSystemLibrary("lmdbx");
    exe.addIncludePath(b.path("../zig-lmdbx/libs/libmdbx"));
    exe.linkLibC();

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
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
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
