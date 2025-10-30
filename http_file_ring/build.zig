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

    // Экспортируем модуль
    const mod = b.addModule("http_file_ring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "picozig", .module = picozig.module("picozig") },
        },
    });

    // Имя бинарника в зависимости от типа библиотеки
    const exe_name = if (musl) "http_file_ring-musl" else "http_file_ring-gnu";

    // Создаем исполняемый файл
    const exe = b.addExecutable(.{
        .name = exe_name,
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

    // Тест pipeline контроллера
    const pipeline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_file_ring", .module = mod },
                .{ .name = "picozig", .module = picozig.module("picozig") },
            },
        }),
    });

    const run_pipeline_tests = b.addRunArtifact(pipeline_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_pipeline_tests.step);

    // Отдельный шаг только для pipeline тестов
    const test_pipeline_step = b.step("test-pipeline", "Run pipeline tests only");
    test_pipeline_step.dependOn(&run_pipeline_tests.step);
}
