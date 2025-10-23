const std = @import("std");
const posix = std.posix;
const Ring = @import("uring.zig").Ring;

pub const FileStorage = struct {
    ring: *Ring,
    fd: posix.fd_t,

    pub fn init(ring: *Ring, file_path: []const u8) !FileStorage {
        const fd = try posix.open(file_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644);

        return FileStorage{
            .ring = ring,
            .fd = fd,
        };
    }

    pub fn deinit(self: *FileStorage) void {
        posix.close(self.fd);
    }

    /// Записать через splice из pipe в файл
    pub fn queueSplice(self: *FileStorage, pipe_fd: i32, offset: u64, len: u32, user_data: u64) !void {
        try self.ring.queueSplice(pipe_fd, -1, self.fd, @intCast(offset), len, user_data);
    }

    /// Прочитать из файла
    pub fn queueRead(self: *FileStorage, buffer: []u8, offset: u64, user_data: u64) !void {
        try self.ring.queueRead(self.fd, buffer, offset, user_data);
    }
};
