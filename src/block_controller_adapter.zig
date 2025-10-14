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

        // Calculate size from block_size
        const size = metadata.block_size.toBytes();

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
};
