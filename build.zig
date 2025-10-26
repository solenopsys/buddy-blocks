const std = @import("std");

pub fn build(b: *std.Build) void {
    // Option to build for musl (Alpine)
    const musl = b.option(bool, "musl", "Build for musl (Alpine Linux)") orelse false;

    const target = if (musl)
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl })
    else
        b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Подключаем зависимости
    const picozig = b.dependency("picozig", .{});
    const buddy_allocator_dep = b.dependency("buddy_allocator", .{
        .target = target,
        .optimize = optimize,
    });
    const http_file_ring_dep = b.dependency("http_file_ring", .{
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
            .{ .name = "http_file_ring", .module = http_file_ring_dep.module("http_file_ring") },
        },
    });

    // Имя бинарника в зависимости от типа библиотеки
    const exe_name = if (musl) "buddy-blocks-musl" else "buddy-blocks-gnu";

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "buddy-blocks", .module = mod },
                .{ .name = "picozig", .module = picozig.module("picozig") },
                .{ .name = "buddy_allocator", .module = buddy_allocator_dep.module("buddy_allocator") },
                .{ .name = "http_file_ring", .module = http_file_ring_dep.module("http_file_ring") },
            },
        }),
    });

    // Линкуем с liblmdbx.so (выбираем правильную версию)
    const lmdbx_lib = if (musl)
        "../zig-lmdbx/zig-out/lib/liblmdbx-x86_64-musl.so"
    else
        "../zig-lmdbx/zig-out/lib/liblmdbx-x86_64-gnu.so";

    exe.addObjectFile(b.path(lmdbx_lib));
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
    mod_tests.addObjectFile(b.path(lmdbx_lib));
    mod_tests.addIncludePath(b.path("../zig-lmdbx/libs/libmdbx"));
    mod_tests.linkLibC();

    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.setEnvironmentVariable("LD_LIBRARY_PATH", "../zig-lmdbx/zig-out/lib");

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.addObjectFile(b.path(lmdbx_lib));
    exe_tests.addIncludePath(b.path("../zig-lmdbx/libs/libmdbx"));
    exe_tests.linkLibC();

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setEnvironmentVariable("LD_LIBRARY_PATH", "../zig-lmdbx/zig-out/lib");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
