const std = @import("std");
const buddy_mod = @import("buddy_allocator");
const BuddyAllocator = buddy_mod.BuddyAllocator;
const FileController = @import("./file_controller.zig").FileController;

/// Adapter that wraps BuddyAllocator to implement BlockController interface
pub const BlockController = struct {
    buddy_allocator: *BuddyAllocator,
    file_controller: *FileController,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, buddy_allocator: *BuddyAllocator, file_controller: *FileController) !*BlockController {
        const self = try allocator.create(BlockController);
        self.* = .{
            .buddy_allocator = buddy_allocator,
            .file_controller = file_controller,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *BlockController) void {
        self.allocator.destroy(self);
    }

    /// Write block data
    pub fn writeBlock(self: *BlockController, hash: [32]u8, data: []const u8) !void {
        // Allocate block in buddy allocator
        const metadata = try self.buddy_allocator.allocate(hash, data.len);

        // Calculate offset from metadata
        const offset = BuddyAllocator.getOffset(metadata);

        // Write data to file at offset
        try self.file_controller.write(offset, data);
    }

    /// Read block data
    pub fn readBlock(self: *BlockController, hash: [32]u8, allocator: std.mem.Allocator) ![]u8 {
        // Get block metadata
        const metadata = try self.buddy_allocator.getBlock(hash);

        // Calculate offset
        const offset = BuddyAllocator.getOffset(metadata);

        // Use actual data size, not block size
        const size = metadata.data_size;

        // Read data from file
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        try self.file_controller.read(offset, buffer);

        return buffer;
    }

    /// Delete block
    pub fn deleteBlock(self: *BlockController, hash: [32]u8) !void {
        try self.buddy_allocator.free(hash);
    }

    /// Потоковая запись блока из socket (socket → file через io_uring с буферами 4KB)
    pub fn writeBlockFromSocket(
        self: *BlockController,
        socket_fd: std.posix.fd_t,
        data_size: u64,
    ) ![32]u8 {
        // Создаём hasher для вычисления хеша на лету
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Выделяем блок в buddy allocator с временным хешем
        var temp_hash: [32]u8 = undefined;
        @memset(&temp_hash, 0);
        const metadata = try self.buddy_allocator.allocate(temp_hash, data_size);

        // Получаем offset для записи
        const offset = BuddyAllocator.getOffset(metadata);

        // Потоково читаем из socket и пишем в файл через буферы 4KB
        self.file_controller.streamSocketToFile(
            socket_fd,
            offset,
            data_size,
            &hasher,
        ) catch |err| {
            // Откатываем аллокацию при ошибке
            self.buddy_allocator.free(temp_hash) catch {};
            return err;
        };

        // Получаем финальный хеш
        var final_hash: [32]u8 = undefined;
        hasher.final(&final_hash);

        // Обновляем metadata с правильным хешем
        // TODO: Нужно добавить метод updateHash в BuddyAllocator
        // Пока что сделаем free старого и allocate нового
        self.buddy_allocator.free(temp_hash) catch {};
        _ = try self.buddy_allocator.allocate(final_hash, data_size);

        return final_hash;
    }

    /// Потоковое чтение блока в socket (file → socket через io_uring с буферами 4KB)
    pub fn readBlockToSocket(
        self: *BlockController,
        hash: [32]u8,
        socket_fd: std.posix.fd_t,
    ) !void {
        // Получаем metadata блока
        const metadata = try self.buddy_allocator.getBlock(hash);

        // Получаем offset и size (используем data_size, не block_size!)
        const offset = BuddyAllocator.getOffset(metadata);
        const size = metadata.data_size;

        // Потоково читаем из файла и пишем в socket через буферы 4KB
        try self.file_controller.streamFileToSocket(socket_fd, offset, size);
    }
};
