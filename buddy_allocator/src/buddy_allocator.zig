const std = @import("std");
pub const lmdbx = @import("lmdbx");
pub const types = @import("types.zig");

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

        // Check if block already exists - if so, return existing metadata
        if (try self.db.get(self.allocator, &hash)) |existing| {
            defer self.allocator.free(existing);
            self.db.abortTransaction();
            return try BlockMetadata.decode(existing);
        }

        // Determine required block size
        const block_size = nextPowerOfTwo(data_length) catch |err| {
            std.debug.print("nextPowerOfTwo failed for data_length={d}: {any}\n", .{ data_length, err });
            return err;
        };

        // Allocate block
        var metadata = try self.allocateBlockInternal(block_size);

        // Set actual data size
        metadata.data_size = data_length;

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

    /// Update hash for an existing block (replace old hash with new hash)
    /// Used when converting from temporary hash to real content hash
    pub fn updateHash(self: *BuddyAllocator, old_hash: [32]u8, new_hash: [32]u8) !BlockMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.db.beginTransaction();
        errdefer self.db.abortTransaction();

        // Get metadata by old hash
        const data = try self.db.get(self.allocator, &old_hash) orelse {
            self.db.abortTransaction();
            return BuddyAllocatorError.BlockNotFound;
        };
        defer self.allocator.free(data);

        const metadata = try BlockMetadata.decode(data);

        // Delete old hash entry
        try self.db.delete(&old_hash);

        // Save metadata with new hash
        const encoded = metadata.encode();
        try self.db.put(&new_hash, &encoded);

        try self.db.commitTransaction();

        return metadata;
    }

    /// Free block by hash
    pub fn free(self: *BuddyAllocator, hash: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const has_txn = self.db.current_txn != null;
        if (!has_txn) {
            try self.db.beginTransaction();
            errdefer self.db.abortTransaction();
        }

        // Get metadata
        const data = try self.db.get(self.allocator, &hash) orelse {
            if (!has_txn) self.db.abortTransaction();
            return BuddyAllocatorError.BlockNotFound;
        };
        defer self.allocator.free(data);

        const metadata = try BlockMetadata.decode(data);

        // Delete metadata
        try self.db.delete(&hash);

        // Free block (with buddy merge)
        try self.freeBlockInternal(metadata);

        if (!has_txn) {
            try self.db.commitTransaction();
        }
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

    /// Move block from free-list to temp (crash-safe allocation)
    pub fn allocateToTemp(self: *BuddyAllocator, block_size: BlockSize) !BlockMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        const has_txn = self.db.current_txn != null;
        if (!has_txn) {
            try self.db.beginTransaction();
            errdefer self.db.abortTransaction();
        }

        // Use existing allocation logic (handles split, extend, etc.)
        const metadata = try self.allocateBlockInternal(block_size);

        // Delete from free-list (allocateBlockInternal already removed it)
        // Now add to temp: t_{size}_{block_num} = buddy_num
        var temp_key_buf: [64]u8 = undefined;
        const temp_key = try std.fmt.bufPrint(&temp_key_buf, "t_{s}_{d}", .{ metadata.block_size.toString(), metadata.block_num });

        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, metadata.buddy_num, .little);
        try self.db.put(temp_key, &value_buf);

        if (!has_txn) {
            try self.db.commitTransaction();
        }

        return metadata;
    }

    /// Move block from temp to hash-table (occupy with real data)
    pub fn occupyFromTemp(self: *BuddyAllocator, hash: [32]u8, metadata: BlockMetadata) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const has_txn = self.db.current_txn != null;
        if (!has_txn) {
            try self.db.beginTransaction();
            errdefer self.db.abortTransaction();
        }

        // Delete from temp: t_{size}_{block_num}
        var temp_key_buf: [64]u8 = undefined;
        const temp_key = try std.fmt.bufPrint(&temp_key_buf, "t_{s}_{d}", .{ metadata.block_size.toString(), metadata.block_num });
        try self.db.delete(temp_key);

        // Add to hash-table
        const encoded = metadata.encode();
        try self.db.put(&hash, &encoded);

        if (!has_txn) {
            try self.db.commitTransaction();
        }
    }

    /// Recover temp blocks back to free-list (called on startup)
    pub fn recoverTempBlocks(self: *BuddyAllocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.db.beginTransaction();
        errdefer self.db.abortTransaction();

        const cursor = try self.db.openCursor();
        defer lmdbx.Database.closeCursor(cursor);

        // Scan all keys with prefix "t_"
        var recovered: usize = 0;
        while (try cursor.seekPrefix(self.allocator, "t_")) |entry| {
            defer self.allocator.free(entry.key);
            defer self.allocator.free(entry.value);

            // Parse key: t_{size}_{block_num}
            if (entry.value.len != 8) continue;

            // Extract size and block_num from key
            // Key format: "t_4k_123"
            const key_str = entry.key;
            if (key_str.len < 4) continue; // Must be at least "t_4k_0"

            const size_start = 2; // After "t_"
            const size_end = std.mem.indexOfPos(u8, key_str, size_start, "_") orelse continue;
            const size_str = key_str[size_start..size_end];

            const block_num_str = key_str[size_end + 1 ..];
            const block_num = std.fmt.parseInt(u64, block_num_str, 10) catch continue;

            // Move to free-list: free_{size}_{block_num} = value (buddy_num)
            var free_key_buf: [64]u8 = undefined;
            const free_key = try std.fmt.bufPrint(&free_key_buf, "free_{s}_{d}", .{ size_str, block_num });
            try self.db.put(free_key, entry.value);

            // Delete temp entry
            try self.db.delete(entry.key);

            recovered += 1;
        }

        try self.db.commitTransaction();

        if (recovered > 0) {
            std.debug.print("BuddyAllocator: Recovered {d} temp blocks to free-list\n", .{recovered});
        }
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
                .data_size = 0, // Will be set by caller
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
                    .data_size = 0, // Will be set by caller
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

        const chunk_size: u64 = types.MACRO_BLOCK_SIZE * 128; // extend by 128 macro blocks at once
        try self.file_controller.extend(chunk_size);

        // Create free blocks across the entire chunk
        const block_512k_size: u64 = 524288;
        const blocks_in_chunk = chunk_size / block_512k_size;
        const base_block_num = current_size / block_512k_size;

        var key_buf: [64]u8 = undefined;

        var idx: u64 = 0;
        while (idx < blocks_in_chunk) : (idx += 1) {
            const block_num = base_block_num + idx;
            const buddy_num = if (block_num % 2 == 0) block_num + 1 else block_num - 1;

            const key = try makeFreeListKey(.size_512k, block_num, &key_buf);
            var value_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &value_buf, buddy_num, .little);
            try self.db.put(key, &value_buf);
        }
    }

    /// Split block into two smaller blocks (buddy split)
    fn splitBlock(self: *BuddyAllocator, parent: BlockMetadata) !BlockMetadata {
        const child_size = parent.block_size.split() orelse return error.CannotSplit;

        // First buddy (left) - return for use
        const first = BlockMetadata{
            .block_size = child_size,
            .block_num = parent.block_num * 2,
            .buddy_num = parent.block_num * 2 + 1,
            .data_size = parent.data_size, // Inherit from parent
        };

        // Second buddy (right) - add to free list
        const second = BlockMetadata{
            .block_size = child_size,
            .block_num = parent.block_num * 2 + 1,
            .buddy_num = parent.block_num * 2,
            .data_size = 0, // Not used for free blocks
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
                    .data_size = 0, // Not used for free blocks
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

// ============================================================================
// Tests
// ============================================================================

test "BuddyAllocator: allocate and free 4KB block" {
    const allocator = std.testing.allocator;

    // Open test database
    var db = try lmdbx.Database.open("/tmp/test-buddy-4kb.db");
    defer db.close();

    // Create simple file controller
    var file_controller = SimpleFileController.init();

    // Create buddy allocator
    var buddy = try BuddyAllocator.init(allocator, &db, file_controller.interface());
    defer buddy.deinit();

    // Test allocate 4KB block
    var hash: [32]u8 = undefined;
    @memset(&hash, 0xAA);

    const metadata = try buddy.allocate(hash, 4096);
    try std.testing.expectEqual(BlockSize.size_4k, metadata.block_size);
    try std.testing.expect(metadata.block_num >= 0);

    // Check block exists
    try std.testing.expect(try buddy.has(hash));

    // Free block
    try buddy.free(hash);

    // Check block no longer exists
    try std.testing.expect(!try buddy.has(hash));
}

test "BuddyAllocator: allocate multiple blocks" {
    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/test-buddy-multi.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    var buddy = try BuddyAllocator.init(allocator, &db, file_controller.interface());
    defer buddy.deinit();

    // Allocate 3 different sized blocks
    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0x11);
    const meta1 = try buddy.allocate(hash1, 4096);
    try std.testing.expectEqual(BlockSize.size_4k, meta1.block_size);

    var hash2: [32]u8 = undefined;
    @memset(&hash2, 0x22);
    const meta2 = try buddy.allocate(hash2, 8192);
    try std.testing.expectEqual(BlockSize.size_8k, meta2.block_size);

    var hash3: [32]u8 = undefined;
    @memset(&hash3, 0x33);
    const meta3 = try buddy.allocate(hash3, 5000); // Should round up to 8KB
    try std.testing.expectEqual(BlockSize.size_8k, meta3.block_size);

    // All should exist
    try std.testing.expect(try buddy.has(hash1));
    try std.testing.expect(try buddy.has(hash2));
    try std.testing.expect(try buddy.has(hash3));

    // Free all
    try buddy.free(hash1);
    try buddy.free(hash2);
    try buddy.free(hash3);

    // None should exist
    try std.testing.expect(!try buddy.has(hash1));
    try std.testing.expect(!try buddy.has(hash2));
    try std.testing.expect(!try buddy.has(hash3));
}
