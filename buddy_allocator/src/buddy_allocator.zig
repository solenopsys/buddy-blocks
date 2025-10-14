const std = @import("std");
const lmdbx = @import("lmdbx_wrapper.zig");
const types = @import("types.zig");

const BlockSize = types.BlockSize;
const BlockMetadata = types.BlockMetadata;
const makeFreeListKey = types.makeFreeListKey;
const parseFreeListKey = types.parseFreeListKey;
const nextPowerOfTwo = types.nextPowerOfTwo;

pub const BuddyAllocatorError = error{
    BlockNotFound,
    BlockAlreadyExists,
    DatabaseError,
    FileError,
    OutOfMemory,
    InvalidMetadataSize,
};

/// File controller interface - only size management
/// Real data I/O goes through kernel and ring buffers
pub const IFileController = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        getSize: *const fn (ptr: *anyopaque) anyerror!u64,
        extend: *const fn (ptr: *anyopaque, bytes: u64) anyerror!void,
    };

    pub fn getSize(self: IFileController) !u64 {
        return self.vtable.getSize(self.ptr);
    }

    pub fn extend(self: IFileController, bytes: u64) !void {
        return self.vtable.extend(self.ptr, bytes);
    }
};

/// Simple file controller implementation for testing
pub const SimpleFileController = struct {
    size: u64,

    pub fn init() SimpleFileController {
        return .{ .size = 0 };
    }

    pub fn getSize(self: *SimpleFileController) !u64 {
        return self.size;
    }

    pub fn extendFile(self: *SimpleFileController, bytes: u64) !void {
        self.size += bytes;
    }

    pub fn interface(self: *SimpleFileController) IFileController {
        return .{
            .ptr = self,
            .vtable = &.{
                .getSize = getSizeImpl,
                .extend = extendImpl,
            },
        };
    }

    fn getSizeImpl(ptr: *anyopaque) anyerror!u64 {
        const self: *SimpleFileController = @ptrCast(@alignCast(ptr));
        return self.getSize();
    }

    fn extendImpl(ptr: *anyopaque, bytes: u64) anyerror!void {
        const self: *SimpleFileController = @ptrCast(@alignCast(ptr));
        return self.extendFile(bytes);
    }
};

/// Buddy allocator - manages block allocation using buddy algorithm
pub const BuddyAllocator = struct {
    allocator: std.mem.Allocator,
    db: *lmdbx.Database,
    file_controller: IFileController,
    mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        db: *lmdbx.Database,
        file_controller: IFileController,
    ) !*BuddyAllocator {
        const self = try allocator.create(BuddyAllocator);
        self.* = .{
            .allocator = allocator,
            .db = db,
            .file_controller = file_controller,
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *BuddyAllocator) void {
        self.allocator.destroy(self);
    }

    /// Allocate block for given data length
    /// Returns metadata with offset information
    pub fn allocate(self: *BuddyAllocator, hash: [32]u8, data_length: u64) !BlockMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.db.beginTransaction();
        errdefer self.db.abortTransaction();

        // Check if block already exists
        if (try self.db.get(self.allocator, &hash)) |existing| {
            defer self.allocator.free(existing);
            self.db.abortTransaction();
            return BuddyAllocatorError.BlockAlreadyExists;
        }

        // Determine required block size
        const block_size = nextPowerOfTwo(data_length) catch |err| {
            std.debug.print("nextPowerOfTwo failed for data_length={d}: {any}\n", .{ data_length, err });
            return err;
        };

        // Allocate block
        const metadata = try self.allocateBlockInternal(block_size);

        // Save metadata: hash -> BlockMetadata
        const encoded = metadata.encode();
        try self.db.put(&hash, &encoded);

        try self.db.commitTransaction();

        return metadata;
    }

    /// Get block metadata by hash
    pub fn getBlock(self: *BuddyAllocator, hash: [32]u8) !BlockMetadata {
        const data = try self.db.get(self.allocator, &hash) orelse return BuddyAllocatorError.BlockNotFound;
        defer self.allocator.free(data);

        return BlockMetadata.decode(data);
    }

    /// Free block by hash
    pub fn free(self: *BuddyAllocator, hash: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.db.beginTransaction();
        errdefer self.db.abortTransaction();

        // Get metadata
        const data = try self.db.get(self.allocator, &hash) orelse {
            self.db.abortTransaction();
            return BuddyAllocatorError.BlockNotFound;
        };
        defer self.allocator.free(data);

        const metadata = try BlockMetadata.decode(data);

        // Delete metadata
        try self.db.delete(&hash);

        // Free block (with buddy merge)
        try self.freeBlockInternal(metadata);

        try self.db.commitTransaction();
    }

    /// Check if block exists
    pub fn has(self: *BuddyAllocator, hash: [32]u8) !bool {
        const data = try self.db.get(self.allocator, &hash);
        if (data) |d| {
            self.allocator.free(d);
            return true;
        }
        return false;
    }

    /// Allocate block of given size (internal, assumes mutex is locked)
    fn allocateBlockInternal(self: *BuddyAllocator, block_size: BlockSize) !BlockMetadata {
        // Try to find free block with cursor range scan
        // Prefix is "free_4k" for size_4k, etc.
        var prefix_buf: [16]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "free_{s}", .{block_size.toString()});

        const cursor = try self.db.openCursor();
        defer lmdbx.Database.closeCursor(cursor);

        if (try cursor.seekPrefix(self.allocator, prefix)) |entry| {
            defer self.allocator.free(entry.key);
            defer self.allocator.free(entry.value);

            // Parse block number from key (e.g., "4k_15" -> 15)
            const parsed = try parseFreeListKey(entry.key);
            const block_num = parsed.block_num;

            // Get buddy_num from value (8 bytes)
            if (entry.value.len != 8) return BuddyAllocatorError.InvalidMetadataSize;
            const buddy_num = std.mem.readInt(u64, entry.value[0..8], .little);

            // Remove from free list
            try self.db.delete(entry.key);

            return BlockMetadata{
                .block_size = block_size,
                .block_num = block_num,
                .buddy_num = buddy_num,
            };
        }

        // No free block found, try to split larger block
        if (try self.findAndSplitLargerBlock(block_size)) |metadata| {
            return metadata;
        }

        // No suitable blocks, extend file
        try self.createNewMacroBlock();

        // Recursively try to allocate again
        return self.allocateBlockInternal(block_size);
    }

    /// Find a larger free block and split it down to required size
    fn findAndSplitLargerBlock(self: *BuddyAllocator, target_size: BlockSize) !?BlockMetadata {
        var current_size_opt = target_size.merge();

        while (current_size_opt) |current_size| : (current_size_opt = current_size.merge()) {
            var prefix_buf: [16]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "free_{s}", .{current_size.toString()});

            const cursor = try self.db.openCursor();
            defer lmdbx.Database.closeCursor(cursor);

            if (try cursor.seekPrefix(self.allocator, prefix)) |entry| {
                defer self.allocator.free(entry.key);
                defer self.allocator.free(entry.value);

                // Found larger block, split it down
                const parsed = try parseFreeListKey(entry.key);
                const block_num = parsed.block_num;

                // Remove from free list
                try self.db.delete(entry.key);

                // Create metadata for this block
                var parent_block = BlockMetadata{
                    .block_size = current_size,
                    .block_num = block_num,
                    .buddy_num = if (block_num % 2 == 0) block_num + 1 else block_num - 1,
                };

                // Split down to target size
                while (parent_block.block_size != target_size) {
                    parent_block = try self.splitBlock(parent_block);
                }

                return parent_block;
            }
        }

        return null;
    }

    /// Create new macro block (1MB) by extending file
    fn createNewMacroBlock(self: *BuddyAllocator) !void {
        const current_size = try self.file_controller.getSize();

        // Always extend file by 1MB (macro block)
        try self.file_controller.extend(types.MACRO_BLOCK_SIZE);

        // Create 2 free blocks of 512KB
        const block_512k_size: u64 = 524288;
        const base_block_num = current_size / block_512k_size;

        var key_buf: [64]u8 = undefined;

        // First 512KB block (block_num = base, buddy = base+1)
        const key1 = try makeFreeListKey(.size_512k, base_block_num, &key_buf);
        var value_buf1: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf1, base_block_num + 1, .little);
        try self.db.put(key1, &value_buf1);

        // Second 512KB block (block_num = base+1, buddy = base)
        const key2 = try makeFreeListKey(.size_512k, base_block_num + 1, &key_buf);
        var value_buf2: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf2, base_block_num, .little);
        try self.db.put(key2, &value_buf2);
    }

    /// Split block into two smaller blocks (buddy split)
    fn splitBlock(self: *BuddyAllocator, parent: BlockMetadata) !BlockMetadata {
        const child_size = parent.block_size.split() orelse return error.CannotSplit;

        // First buddy (left) - return for use
        const first = BlockMetadata{
            .block_size = child_size,
            .block_num = parent.block_num * 2,
            .buddy_num = parent.block_num * 2 + 1,
        };

        // Second buddy (right) - add to free list
        const second = BlockMetadata{
            .block_size = child_size,
            .block_num = parent.block_num * 2 + 1,
            .buddy_num = parent.block_num * 2,
        };

        var key_buf: [64]u8 = undefined;
        const key = try makeFreeListKey(second.block_size, second.block_num, &key_buf);

        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, second.buddy_num, .little);

        try self.db.put(key, &value_buf);

        return first;
    }

    /// Free block and try to merge with buddy (internal, assumes mutex is locked)
    fn freeBlockInternal(self: *BuddyAllocator, metadata: BlockMetadata) !void {
        // We have buddy_num in metadata - this is the buddy block number!
        const buddy_num = metadata.buddy_num;

        var key_buf: [64]u8 = undefined;
        const buddy_key = try makeFreeListKey(metadata.block_size, buddy_num, &key_buf);

        // Check if buddy is free
        if (try self.db.get(self.allocator, buddy_key)) |buddy_value| {
            defer self.allocator.free(buddy_value);

            // Buddy is free - merge!

            // Delete BOTH blocks from free list (current and buddy)
            var key_buf2: [64]u8 = undefined;
            const current_key = try makeFreeListKey(metadata.block_size, metadata.block_num, &key_buf2);
            self.db.delete(current_key) catch {}; // May not exist in free list yet
            try self.db.delete(buddy_key); // Buddy must exist

            // Create parent block (merge)
            if (metadata.block_size.merge()) |parent_size| {
                const parent_num = metadata.block_num / 2;

                // Calculate parent's buddy
                const parent_buddy = if (parent_num % 2 == 0) parent_num + 1 else parent_num - 1;

                const parent = BlockMetadata{
                    .block_size = parent_size,
                    .block_num = parent_num,
                    .buddy_num = parent_buddy,
                };

                // Recursively try to merge further
                return self.freeBlockInternal(parent);
            }
        }

        // Buddy is not free or this is max size (1MB) - just add to free list
        const key = try makeFreeListKey(metadata.block_size, metadata.block_num, &key_buf);
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, metadata.buddy_num, .little);
        try self.db.put(key, &value_buf);
    }

    /// Calculate offset for given metadata
    pub fn getOffset(metadata: BlockMetadata) u64 {
        return metadata.block_num * metadata.block_size.toBytes();
    }
};
