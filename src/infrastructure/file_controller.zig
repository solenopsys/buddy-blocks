const std = @import("std");
const os = std.os;
const linux = os.linux;
const buddy_mod = @import("buddy_allocator");
// Use IFileController from buddy_allocator module
pub const IFileController = buddy_mod.IFileController;

/// Контроллер для работы с файлами (только FD, без ring)
/// Ring теперь принадлежит Worker и используется асинхронно
pub const FileController = struct {
    fd: std.posix.fd_t,
    allocator: std.mem.Allocator,

    const PAGE_SIZE = 4096;
    const SSD_BLOCK_SIZE = 4096;

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

        return .{
            .fd = fd,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileController) void {
        std.posix.close(self.fd);
    }

    /// Увеличить размер файла максимально быстро
    pub fn growFile(self: *FileController, new_size: u64) !void {
        const current_size = try self.getSizeInternal();
        if (new_size <= current_size) return;

        // Выравниваем конечный размер по границам SSD блоков
        const aligned_size = std.mem.alignForward(u64, new_size, SSD_BLOCK_SIZE);
        const delta = aligned_size - current_size;
        if (delta == 0) return;

        // Расширяем только новый участок файла
        const result = linux.fallocate(
            self.fd,
            0, // режим: выделяем реальные блоки
            @intCast(current_size),
            @intCast(delta),
        );

        if (result != 0) {
            const err = std.posix.errno(result);
            switch (err) {
                .OPNOTSUPP, .NOSYS, .INVAL => try std.posix.ftruncate(self.fd, @intCast(aligned_size)),
                else => return error.FailedToGrowFile,
            }
        }
    }

    /// Получить текущий размер файла
    pub fn getSizeInternal(self: *FileController) !u64 {
        const stat = try std.posix.fstat(self.fd);
        return @intCast(stat.size);
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
