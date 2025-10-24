const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Добавляем zig-lmdbx модуль
    const lmdbx_module = b.addModule("lmdbx", .{
        .root_source_file = b.path("../../zig-lmdbx/src/lmdbx.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Экспортируем buddy_allocator как модуль
    const buddy_allocator_module = b.addModule("buddy_allocator", .{
        .root_source_file = b.path("src/buddy_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    buddy_allocator_module.addImport("lmdbx", lmdbx_module);

    // Добавляем include пути для lmdbx
    buddy_allocator_module.addIncludePath(b.path("../../zig-lmdbx/libs/libmdbx"));

    // Benchmark
    const benchmark_exe = b.addExecutable(.{
        .name = "buddy_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    benchmark_exe.root_module.addImport("lmdbx", lmdbx_module);

    // Линкуем с liblmdbx.so
    benchmark_exe.addLibraryPath(b.path("../../zig-lmdbx/zig-out/lib"));
    benchmark_exe.linkSystemLibrary("lmdbx");
    benchmark_exe.addIncludePath(b.path("../../zig-lmdbx/libs/libmdbx"));
    benchmark_exe.linkLibC();

    b.installArtifact(benchmark_exe);

    const benchmark_step = b.step("benchmark", "Run buddy allocator benchmark");
    const benchmark_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_step.dependOn(&benchmark_cmd.step);
    benchmark_cmd.step.dependOn(b.getInstallStep());

    // Tests
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/buddy_allocator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addImport("lmdbx", lmdbx_module);

    test_exe.addLibraryPath(b.path("../../zig-lmdbx/zig-out/lib"));
    test_exe.linkSystemLibrary("lmdbx");
    test_exe.addIncludePath(b.path("../../zig-lmdbx/libs/libmdbx"));
    test_exe.linkLibC();

    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run buddy allocator tests");
    test_step.dependOn(&run_test.step);
}
