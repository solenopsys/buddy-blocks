const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Подключаем зависимости
    const picozig = b.dependency("picozig", .{});

    // Экспортируем модуль
    const mod = b.addModule("http_file_ring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "picozig", .module = picozig.module("picozig") },
        },
    });

    // Создаем исполняемый файл
    const exe = b.addExecutable(.{
        .name = "http_file_ring",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_file_ring", .module = mod },
                .{ .name = "picozig", .module = picozig.module("picozig") },
            },
        }),
    });

    b.installArtifact(exe);

    // Шаг для запуска
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Тесты модуля
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Тесты исполняемого файла
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
