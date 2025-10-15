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

    /// Write block data (sync через pwrite)
    pub fn writeBlock(self: *BlockController, hash: [32]u8, data: []const u8) !void {
        // Allocate block in buddy allocator
        const metadata = try self.buddy_allocator.allocate(hash, data.len);

        // Calculate offset from metadata
        const offset = BuddyAllocator.getOffset(metadata);

        // Write data to file synchronously
        const written = try std.posix.pwrite(self.file_controller.fd, data, offset);
        if (written != data.len) {
            return error.IncompleteWrite;
        }
    }

    /// Read block data (sync через pread)
    pub fn readBlock(self: *BlockController, hash: [32]u8, allocator: std.mem.Allocator) ![]u8 {
        // Get block metadata
        const metadata = try self.buddy_allocator.getBlock(hash);

        // Calculate offset
        const offset = BuddyAllocator.getOffset(metadata);

        // Use actual data size, not block size
        const size = metadata.data_size;

        // Read data from file synchronously
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        const bytes_read = try std.posix.pread(self.file_controller.fd, buffer, offset);
        if (bytes_read != size) {
            allocator.free(buffer);
            return error.IncompleteRead;
        }

        return buffer;
    }

    /// Delete block
    pub fn deleteBlock(self: *BlockController, hash: [32]u8) !void {
        try self.buddy_allocator.free(hash);
    }
};
