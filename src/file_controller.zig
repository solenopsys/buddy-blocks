const std = @import("std");
const os = std.os;
const linux = os.linux;
const buddy_mod = @import("buddy_allocator");
const IFileController = buddy_mod.IFileController;

/// Контроллер для быстрой работы с файлами через io_uring
pub const FileController = struct {
    fd: std.posix.fd_t,
    ring: linux.IoUring,
    allocator: std.mem.Allocator,

    const PAGE_SIZE = 4096;
    const SSD_BLOCK_SIZE = 4096;
    const BUFFER_SIZE = 4096;
    const QUEUE_DEPTH = 64;

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileController {
        // Открываем или создаём файл с флагами для прямого I/O
        const fd = try std.posix.open(
            path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .DIRECT = true, // O_DIRECT для bypass кэша
            },
            0o644,
        );
        errdefer std.posix.close(fd);

        // Инициализируем io_uring
        var ring = try linux.IoUring.init(QUEUE_DEPTH, 0);
        errdefer ring.deinit();

        return .{
            .fd = fd,
            .ring = ring,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileController) void {
        self.ring.deinit();
        std.posix.close(self.fd);
    }

    /// Увеличить размер файла максимально быстро
    pub fn growFile(self: *FileController, new_size: u64) !void {
        // Выравниваем размер по границам SSD блоков
        const aligned_size = std.mem.alignForward(u64, new_size, SSD_BLOCK_SIZE);

        // Используем fallocate для быстрого выделения места
        const result = linux.fallocate(
            self.fd,
            0, // mode: FALLOC_FL_KEEP_SIZE не устанавливаем - хотим реальный размер
            0, // offset
            @intCast(aligned_size),
        );

        if (result != 0) {
            return error.FailedToGrowFile;
        }
    }

    /// Записать данные через io_uring с выровненным буфером
    pub fn writeAligned(self: *FileController, offset: u64, data: []const u8) !void {
        // Выравниваем offset по границам страниц
        const aligned_offset = std.mem.alignBackward(u64, offset, PAGE_SIZE);
        const page_offset = offset - aligned_offset;

        // Создаём выровненный буфер
        const aligned_buffer = try self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(PAGE_SIZE), BUFFER_SIZE);
        defer self.allocator.free(aligned_buffer);

        // Копируем данные с учётом смещения
        const write_size = @min(data.len, BUFFER_SIZE - page_offset);
        @memcpy(aligned_buffer[page_offset..][0..write_size], data[0..write_size]);

        // Подготавливаем запрос на запись
        const sqe = try self.ring.write(
            0, // user_data
            self.fd,
            aligned_buffer,
            aligned_offset,
        );
        _ = sqe;

        // Отправляем запрос
        _ = try self.ring.submit();

        // Ждём завершения
        const cqe = try self.ring.copy_cqe();
        if (cqe.res < 0) {
            return error.WriteError;
        }
    }

    /// Потоковая запись через 4KB буферы
    pub fn streamWrite(self: *FileController, offset: u64, data: []const u8) !void {
        var current_offset = std.mem.alignForward(u64, offset, PAGE_SIZE);
        var remaining = data;
        var buffer_index: usize = 0;

        // Создаём пул выровненных буферов
        var buffers: [4][]align(PAGE_SIZE) u8 = undefined;
        for (&buffers) |*buf| {
            buf.* = try self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(PAGE_SIZE), BUFFER_SIZE);
        }
        defer for (buffers) |buf| self.allocator.free(buf);

        while (remaining.len > 0) {
            const chunk_size = @min(remaining.len, BUFFER_SIZE);
            const buf = buffers[buffer_index % buffers.len];

            // Копируем данные в выровненный буфер
            @memcpy(buf[0..chunk_size], remaining[0..chunk_size]);
            if (chunk_size < BUFFER_SIZE) {
                @memset(buf[chunk_size..], 0);
            }

            // Готовим запрос
            const sqe = try self.ring.write(
                buffer_index,
                self.fd,
                buf[0..BUFFER_SIZE],
                current_offset,
            );
            _ = sqe;

            current_offset += BUFFER_SIZE;
            remaining = remaining[chunk_size..];
            buffer_index += 1;

            // Отправляем пакет запросов
            if (buffer_index % buffers.len == 0 or remaining.len == 0) {
                _ = try self.ring.submit();

                // Собираем результаты
                for (0..@min(buffer_index, buffers.len)) |_| {
                    const cqe = try self.ring.copy_cqe();
                    if (cqe.res < 0) {
                        return error.StreamWriteError;
                    }
                }

                if (remaining.len > 0) {
                    buffer_index = 0;
                }
            }
        }
    }

    /// Получить текущий размер файла
    pub fn getSizeInternal(self: *FileController) !u64 {
        const stat = try std.posix.fstat(self.fd);
        return @intCast(stat.size);
    }

    /// Простой метод для записи данных (без io_uring, для начала)
    pub fn write(self: *FileController, offset: u64, data: []const u8) !void {
        // Используем streamWrite для записи
        try self.streamWrite(offset, data);
    }

    /// Простой метод для чтения данных
    pub fn read(self: *FileController, offset: u64, buffer: []u8) !void {
        const read_buffer = try self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(PAGE_SIZE), buffer.len);
        defer self.allocator.free(read_buffer);

        const sqe = try self.ring.read(
            0,
            self.fd,
            .{ .buffer = read_buffer },
            offset,
        );
        _ = sqe;

        _ = try self.ring.submit();
        const cqe = try self.ring.copy_cqe();

        if (cqe.res < 0) {
            return error.ReadError;
        }

        const bytes_read: usize = @intCast(cqe.res);
        @memcpy(buffer[0..@min(buffer.len, bytes_read)], read_buffer[0..@min(buffer.len, bytes_read)]);
    }

    /// Расширить файл на указанное количество байтов
    pub fn extendFile(self: *FileController, bytes: u64) !void {
        const current_size = try self.getSizeInternal();
        try self.growFile(current_size + bytes);
    }

    /// Создать IFileController интерфейс для BuddyAllocator
    pub fn interface(self: *FileController) IFileController {
        return .{
            .ptr = self,
            .vtable = &.{
                .getSize = getSizeImpl,
                .extend = extendImpl,
            },
        };
    }

    fn getSizeImpl(ptr: *anyopaque) anyerror!u64 {
        const self: *FileController = @ptrCast(@alignCast(ptr));
        return self.getSizeInternal();
    }

    fn extendImpl(ptr: *anyopaque, bytes: u64) anyerror!void {
        const self: *FileController = @ptrCast(@alignCast(ptr));
        return self.extendFile(bytes);
    }
};

// ============================================================================
// Тесты
// ============================================================================

test "FileController: init and deinit" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test_file_controller_init.dat";

    // Удаляем файл если существует
    std.posix.unlink(test_path) catch {};

    var controller = try FileController.init(allocator, test_path);
    defer controller.deinit();
    defer std.posix.unlink(test_path) catch {};

    // Проверяем что файл создан
    const size = try controller.getSizeInternal();
    try std.testing.expectEqual(@as(u64, 0), size);
}

test "FileController: growFile" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test_file_controller_grow.dat";

    std.posix.unlink(test_path) catch {};

    var controller = try FileController.init(allocator, test_path);
    defer controller.deinit();
    defer std.posix.unlink(test_path) catch {};

    // Увеличиваем файл до 1MB
    try controller.growFile(1024 * 1024);

    const size = try controller.getSizeInternal();
    try std.testing.expect(size >= 1024 * 1024);

    // Увеличиваем ещё раз до 2MB
    try controller.growFile(2 * 1024 * 1024);

    const new_size = try controller.getSizeInternal();
    try std.testing.expect(new_size >= 2 * 1024 * 1024);
}

test "FileController: streamWrite and read back" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test_file_controller_stream.dat";

    std.posix.unlink(test_path) catch {};

    var controller = try FileController.init(allocator, test_path);
    defer controller.deinit();
    defer std.posix.unlink(test_path) catch {};

    // Подготавливаем данные для записи (16KB)
    const data_size = 16 * 1024;
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    // Заполняем тестовыми данными
    for (test_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    // Расширяем файл
    try controller.growFile(data_size);

    // Записываем данные через streamWrite
    try controller.streamWrite(0, test_data);

    // Читаем обратно через прямой read
    const read_buffer = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), data_size);
    defer allocator.free(read_buffer);

    const sqe = try controller.ring.read(
        0,
        controller.fd,
        .{ .buffer = read_buffer },
        0,
    );
    _ = sqe;

    _ = try controller.ring.submit();
    const cqe = try controller.ring.copy_cqe();

    try std.testing.expect(cqe.res > 0);

    const bytes_read: usize = @intCast(cqe.res);
    try std.testing.expect(bytes_read >= test_data.len);

    // Проверяем что данные совпадают
    try std.testing.expectEqualSlices(u8, test_data, read_buffer[0..test_data.len]);
}

test "FileController: multiple writes at different offsets" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/test_file_controller_offsets.dat";

    std.posix.unlink(test_path) catch {};

    var controller = try FileController.init(allocator, test_path);
    defer controller.deinit();
    defer std.posix.unlink(test_path) catch {};

    // Расширяем файл до 64KB
    try controller.growFile(64 * 1024);

    // Пишем блок A на offset 0
    const block_a = "AAAA" ** 1024; // 4KB
    try controller.streamWrite(0, block_a);

    // Пишем блок B на offset 8KB
    const block_b = "BBBB" ** 1024; // 4KB
    try controller.streamWrite(8 * 1024, block_b);

    // Читаем блок A
    const buffer_a = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
    defer allocator.free(buffer_a);

    _ = try controller.ring.read(0, controller.fd, .{ .buffer = buffer_a }, 0);
    _ = try controller.ring.submit();
    var cqe = try controller.ring.copy_cqe();
    try std.testing.expect(cqe.res > 0);

    // Читаем блок B
    const buffer_b = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
    defer allocator.free(buffer_b);

    _ = try controller.ring.read(1, controller.fd, .{ .buffer = buffer_b }, 8 * 1024);
    _ = try controller.ring.submit();
    cqe = try controller.ring.copy_cqe();
    try std.testing.expect(cqe.res > 0);

    // Проверяем что данные правильные
    try std.testing.expectEqualSlices(u8, block_a, buffer_a[0..block_a.len]);
    try std.testing.expectEqualSlices(u8, block_b, buffer_b[0..block_b.len]);
}
