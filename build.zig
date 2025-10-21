const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Подключаем зависимости
    const libxev = b.dependency("libxev", .{});
    const picozig = b.dependency("picozig", .{});
    const buddy_allocator_dep = b.dependency("buddy_allocator", .{
        .target = target,
        .optimize = optimize,
    });
    const spsc_queue = b.dependency("spsc_queue", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("buddy-blocks", .{
        .root_source_file = b.path("src/root.zig"),

        .target = target,
        .imports = &.{
            .{ .name = "spsc_queue", .module = spsc_queue.module("spsc_queue") },
            .{ .name = "buddy_allocator", .module = buddy_allocator_dep.module("buddy_allocator") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "buddy-blocks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "buddy-blocks", .module = mod },
                .{ .name = "xev", .module = libxev.module("xev") },
                .{ .name = "picozig", .module = picozig.module("picozig") },
                .{ .name = "buddy_allocator", .module = buddy_allocator_dep.module("buddy_allocator") },
            },
        }),
    });

    // Линкуем с liblmdbx.so
    exe.addObjectFile(b.path("../zig-lmdbx/zig-out/lib/liblmdbx-x86_64-gnu.so"));
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
