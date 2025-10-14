const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Benchmark
    const benchmark_exe = b.addExecutable(.{
        .name = "buddy_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

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
}
