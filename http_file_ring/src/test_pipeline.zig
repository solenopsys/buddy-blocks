const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("uring.zig").Ring;
const FileStorage = @import("file.zig").FileStorage;
const PipelineController = @import("pipeline_controller.zig").PipelineController;
const HashSocketPool = @import("hash_socket_pool.zig").HashSocketPool;
const interfaces = @import("interfaces.zig");

test "pipeline controller - basic tee and splice" {
    const allocator = std.testing.allocator;

    // Создаем io_uring
    var ring = try Ring.init(64);
    defer ring.deinit();

    // Создаем временный файл для storage
    const storage_path = "/tmp/test_pipeline_controller.dat";
    var file_storage = try FileStorage.init(&ring, storage_path);
    defer file_storage.deinit();
    defer posix.unlink(storage_path) catch {};

    // Создаем pipeline контроллер
    var controller = PipelineController.init(allocator, &ring, &file_storage);

    // Создаем hash socket pool
    var hash_pool = HashSocketPool.init(allocator);
    defer hash_pool.deinit();

    const hash_socket = try hash_pool.acquire();
    defer hash_pool.release(hash_socket);

    // Создаем pipes
    const pipes1 = try posix.pipe();
    const pipes2 = try posix.pipe();

    // Увеличиваем размер pipe буферов
    const F_SETPIPE_SZ: i32 = 1031;
    const pipe_size: i32 = 524288; // 512 KB
    _ = linux.fcntl(pipes1[0], F_SETPIPE_SZ, pipe_size);
    _ = linux.fcntl(pipes1[1], F_SETPIPE_SZ, pipe_size);
    _ = linux.fcntl(pipes2[0], F_SETPIPE_SZ, pipe_size);
    _ = linux.fcntl(pipes2[1], F_SETPIPE_SZ, pipe_size);

    // Тестовые данные - 64 KB
    const data_size: usize = 64 * 1024;
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    // Заполняем данные паттерном
    for (test_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    // Вычисляем ожидаемый хеш
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(test_data);
    var expected_hash: [32]u8 = undefined;
    hasher.final(&expected_hash);

    // Записываем данные в pipe1
    const written = try posix.write(pipes1[1], test_data);
    try std.testing.expectEqual(data_size, written);
    posix.close(pipes1[1]); // Закрываем write-конец после записи

    // Сохраняем дескрипторы для закрытия в конце
    const pipe1_read = pipes1[0];
    const pipe2_read = pipes2[0];
    const pipe2_write = pipes2[1];

    // Запускаем pipeline
    const file_offset: u64 = 0;
    const conn_fd: i32 = -1; // Для теста
    const block_info = interfaces.BlockInfo{ .block_num = 0 };
    const state = try controller.startPipeline(
        pipe1_read,
        pipe2_read,
        pipe2_write,
        hash_socket,
        file_offset,
        data_size,
        conn_fd,
        block_info,
    );

    // Обрабатываем completion events до полного завершения pipeline
    var pipeline_completed = false;
    while (!pipeline_completed) {
        const cqe = try ring.waitCqe();

        if (cqe.user_data == 0) continue; // Пропускаем вспомогательные операции

        const ctx = @as(*interfaces.OpContext, @ptrFromInt(cqe.user_data));
        const result = try controller.handlePipelineCompletion(ctx, cqe.res);

        if (result.should_cleanup) {
            allocator.destroy(ctx);
        }

        if (result.status == .failed) {
            std.debug.print("Pipeline operation failed!\n", .{});
            return error.PipelineFailed;
        }

        if (result.status == .completed) {
            pipeline_completed = true;
        }
    }

    // Проверяем что pipeline завершился
    try std.testing.expect(state.isComplete());
    try std.testing.expect(state.hash_ready);

    // Проверяем хеш
    try std.testing.expectEqualSlices(u8, &expected_hash, &state.hash);

    // Проверяем что данные записались в файл
    const read_buffer = try allocator.alloc(u8, data_size);
    defer allocator.free(read_buffer);

    const bytes_read = try posix.pread(file_storage.fd, read_buffer, file_offset);
    try std.testing.expectEqual(data_size, bytes_read);
    try std.testing.expectEqualSlices(u8, test_data, read_buffer);

    // Cleanup
    state.cleanup();
    allocator.destroy(state);

    std.debug.print("✓ Pipeline test passed: data written to file and hash calculated correctly\n", .{});
}

test "pipeline controller - chunked data transfer" {
    const allocator = std.testing.allocator;

    var ring = try Ring.init(64);
    defer ring.deinit();

    const storage_path = "/tmp/test_pipeline_chunked.dat";
    var file_storage = try FileStorage.init(&ring, storage_path);
    defer file_storage.deinit();
    defer posix.unlink(storage_path) catch {};

    var controller = PipelineController.init(allocator, &ring, &file_storage);

    var hash_pool = HashSocketPool.init(allocator);
    defer hash_pool.deinit();

    const hash_socket = try hash_pool.acquire();
    defer hash_pool.release(hash_socket);

    const pipes1 = try posix.pipe();
    const pipes2 = try posix.pipe();

    const F_SETPIPE_SZ: i32 = 1031;
    const pipe_size: i32 = 524288;
    _ = linux.fcntl(pipes1[0], F_SETPIPE_SZ, pipe_size);
    _ = linux.fcntl(pipes1[1], F_SETPIPE_SZ, pipe_size);
    _ = linux.fcntl(pipes2[0], F_SETPIPE_SZ, pipe_size);
    _ = linux.fcntl(pipes2[1], F_SETPIPE_SZ, pipe_size);

    // Большие данные - 128 KB
    const data_size: usize = 128 * 1024;
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    for (test_data, 0..) |*byte, i| {
        byte.* = @intCast((i * 7) % 256);
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(test_data);
    var expected_hash: [32]u8 = undefined;
    hasher.final(&expected_hash);

    const pipe1_read = pipes1[0];
    const pipe2_read = pipes2[0];
    const pipe2_write = pipes2[1];

    // Запускаем pipeline
    const conn_fd: i32 = -1; // Для теста
    const block_info = interfaces.BlockInfo{ .block_num = 0 };
    const state = try controller.startPipeline(
        pipe1_read,
        pipe2_read,
        pipe2_write,
        hash_socket,
        0,
        data_size,
        conn_fd,
        block_info,
    );

    // Симулируем медленную запись данных порциями (как прокси)
    const WriterThread = struct {
        fn write(pipe_fd: i32, data: []const u8) void {
            const chunk_size: usize = 8192; // 8 KB chunks
            var written_total: usize = 0;

            while (written_total < data.len) {
                const to_write = @min(chunk_size, data.len - written_total);
                const written = posix.write(pipe_fd, data[written_total .. written_total + to_write]) catch {
                    std.debug.print("Write to pipe failed\n", .{});
                    return;
                };
                written_total += written;

                // Небольшая задержка между chunks
                std.Thread.sleep(5 * std.time.ns_per_ms);
            }

            posix.close(pipe_fd);
        }
    };

    const writer_thread = try std.Thread.spawn(.{}, WriterThread.write, .{ pipes1[1], test_data });

    // Обрабатываем события до полного завершения pipeline
    var pipeline_completed = false;
    while (!pipeline_completed) {
        const cqe = try ring.waitCqe();
        if (cqe.user_data == 0) continue;

        const ctx = @as(*interfaces.OpContext, @ptrFromInt(cqe.user_data));
        const result = try controller.handlePipelineCompletion(ctx, cqe.res);

        if (result.should_cleanup) {
            allocator.destroy(ctx);
        }

        if (result.status == .failed) {
            return error.PipelineFailed;
        }

        if (result.status == .completed) {
            pipeline_completed = true;
        }
    }

    writer_thread.join();

    // Проверки
    try std.testing.expect(state.isComplete());
    try std.testing.expect(state.hash_ready);

    // Проверяем данные в файле СНАЧАЛА
    const read_buffer = try allocator.alloc(u8, data_size);
    defer allocator.free(read_buffer);

    const bytes_read = try posix.pread(file_storage.fd, read_buffer, 0);
    try std.testing.expectEqual(data_size, bytes_read);

    std.debug.print("Checking file data...\n", .{});
    try std.testing.expectEqualSlices(u8, test_data, read_buffer);
    std.debug.print("File data OK!\n", .{});

    // Вычисляем хеш от прочитанных данных для отладки
    var hasher2 = std.crypto.hash.sha2.Sha256.init(.{});
    hasher2.update(read_buffer);
    var file_data_hash: [32]u8 = undefined;
    hasher2.final(&file_data_hash);
    std.debug.print("Expected hash from test_data: {any}\n", .{expected_hash});
    std.debug.print("Hash from file data:          {any}\n", .{file_data_hash});
    std.debug.print("Hash from AF_ALG:             {any}\n", .{state.hash});

    try std.testing.expectEqualSlices(u8, &expected_hash, &state.hash);

    // Cleanup
    state.cleanup();
    allocator.destroy(state);

    std.debug.print("✓ Chunked pipeline test passed\n", .{});
}
