const std = @import("std");
const lmdbx = @import("lmdbx");
const types = @import("types");
const BuddyAllocator = @import("buddy_allocator").BuddyAllocator;
const SimpleFileController = @import("buddy_allocator").SimpleFileController;
const getOffset = @import("buddy_allocator").BuddyAllocator.getOffset;

const BlockSize = types.BlockSize;

fn cleanupTestFiles() void {
    std.fs.cwd().deleteFile("/tmp/buddy_test.db") catch {};
    std.fs.cwd().deleteFile("/tmp/buddy_test.db-lock") catch {};
}

test "BuddyAllocator: basic allocation and deallocation" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    // Allocate a 4KB block
    var hash1: [32]u8 = undefined;
    std.crypto.random.bytes(&hash1);

    const metadata1 = try buddy.allocate(hash1, 100); // 100 bytes -> 4KB block
    try std.testing.expectEqual(BlockSize.size_4k, metadata1.block_size);
    try std.testing.expectEqual(@as(u64, 0), getOffset(metadata1));

    // Allocate another 4KB block
    var hash2: [32]u8 = undefined;
    std.crypto.random.bytes(&hash2);

    const metadata2 = try buddy.allocate(hash2, 200); // 200 bytes -> 4KB block
    try std.testing.expectEqual(BlockSize.size_4k, metadata2.block_size);

    // Verify blocks exist
    try std.testing.expect(try buddy.has(hash1));
    try std.testing.expect(try buddy.has(hash2));

    // Free first block
    try buddy.free(hash1);
    try std.testing.expect(!try buddy.has(hash1));
    try std.testing.expect(try buddy.has(hash2));

    // Free second block
    try buddy.free(hash2);
    try std.testing.expect(!try buddy.has(hash2));
}

test "BuddyAllocator: different block sizes" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    const test_cases = [_]struct {
        data_length: u64,
        expected_size: BlockSize,
    }{
        .{ .data_length = 100, .expected_size = .size_4k },
        .{ .data_length = 4096, .expected_size = .size_4k },
        .{ .data_length = 4097, .expected_size = .size_8k },
        .{ .data_length = 5000, .expected_size = .size_8k },
        .{ .data_length = 20 * 1024, .expected_size = .size_32k },
        .{ .data_length = 100 * 1024, .expected_size = .size_128k },
    };

    for (test_cases) |case| {
        var hash: [32]u8 = undefined;
        std.crypto.random.bytes(&hash);

        const metadata = try buddy.allocate(hash, case.data_length);
        try std.testing.expectEqual(case.expected_size, metadata.block_size);

        // Clean up
        try buddy.free(hash);
    }
}

test "BuddyAllocator: buddy split - larger to smaller" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    // First allocation creates 1MB macro block and splits into 512KB blocks
    // Then one 512KB is split down to 4KB
    var hash1: [32]u8 = undefined;
    std.crypto.random.bytes(&hash1);

    const metadata1 = try buddy.allocate(hash1, 100); // 100 bytes -> 4KB
    try std.testing.expectEqual(BlockSize.size_4k, metadata1.block_size);

    // File should have been extended to 1MB
    const file_size = try file_controller.getSize();
    try std.testing.expectEqual(@as(u64, 1048576), file_size);

    // Second allocation should use another 4KB from the split
    var hash2: [32]u8 = undefined;
    std.crypto.random.bytes(&hash2);

    const metadata2 = try buddy.allocate(hash2, 100);
    try std.testing.expectEqual(BlockSize.size_4k, metadata2.block_size);

    // File size should still be 1MB (no new allocation)
    const file_size2 = try file_controller.getSize();
    try std.testing.expectEqual(@as(u64, 1048576), file_size2);

    // Clean up
    try buddy.free(hash1);
    try buddy.free(hash2);
}

test "BuddyAllocator: buddy merge - two 4KB into 8KB" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    // Allocate two 4KB blocks (they will be buddies)
    var hash1: [32]u8 = undefined;
    std.crypto.random.bytes(&hash1);

    const metadata1 = try buddy.allocate(hash1, 100);
    try std.testing.expectEqual(BlockSize.size_4k, metadata1.block_size);

    var hash2: [32]u8 = undefined;
    std.crypto.random.bytes(&hash2);

    const metadata2 = try buddy.allocate(hash2, 100);
    try std.testing.expectEqual(BlockSize.size_4k, metadata2.block_size);

    // Free first block
    try buddy.free(hash1);

    // Free second block - should merge with first into 8KB
    try buddy.free(hash2);

    // Now allocate 8KB block - should reuse merged block
    var hash3: [32]u8 = undefined;
    std.crypto.random.bytes(&hash3);

    const metadata3 = try buddy.allocate(hash3, 5000); // 5KB -> needs 8KB block
    try std.testing.expectEqual(BlockSize.size_8k, metadata3.block_size);

    // File size should still be 1MB (no new allocation)
    const file_size = try file_controller.getSize();
    try std.testing.expectEqual(@as(u64, 1048576), file_size);

    // Clean up
    try buddy.free(hash3);
}

test "BuddyAllocator: multiple allocations and deallocations" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    const NUM_BLOCKS = 50;
    var hashes: [NUM_BLOCKS][32]u8 = undefined;

    // Allocate 50 blocks
    for (0..NUM_BLOCKS) |i| {
        std.crypto.random.bytes(&hashes[i]);
        const metadata = try buddy.allocate(hashes[i], 100);
        try std.testing.expectEqual(BlockSize.size_4k, metadata.block_size);
    }

    // Verify all exist
    for (0..NUM_BLOCKS) |i| {
        try std.testing.expect(try buddy.has(hashes[i]));
    }

    // Free all blocks
    for (0..NUM_BLOCKS) |i| {
        try buddy.free(hashes[i]);
    }

    // Verify all freed
    for (0..NUM_BLOCKS) |i| {
        try std.testing.expect(!try buddy.has(hashes[i]));
    }

    // Allocate again - should reuse freed blocks
    var new_hashes: [NUM_BLOCKS][32]u8 = undefined;
    for (0..NUM_BLOCKS) |i| {
        std.crypto.random.bytes(&new_hashes[i]);
        const metadata = try buddy.allocate(new_hashes[i], 100);
        try std.testing.expectEqual(BlockSize.size_4k, metadata.block_size);
    }

    // Clean up
    for (0..NUM_BLOCKS) |i| {
        try buddy.free(new_hashes[i]);
    }
}

test "BuddyAllocator: getBlock returns correct metadata" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    var hash: [32]u8 = undefined;
    std.crypto.random.bytes(&hash);

    const metadata1 = try buddy.allocate(hash, 100);

    const metadata2 = try buddy.getBlock(hash);

    try std.testing.expectEqual(metadata1.block_size, metadata2.block_size);
    try std.testing.expectEqual(metadata1.block_num, metadata2.block_num);
    try std.testing.expectEqual(metadata1.buddy_num, metadata2.buddy_num);

    try buddy.free(hash);
}

test "BuddyAllocator: error on duplicate hash" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    var hash: [32]u8 = undefined;
    std.crypto.random.bytes(&hash);

    _ = try buddy.allocate(hash, 100);

    // Second allocation with same hash should fail
    try std.testing.expectError(error.BlockAlreadyExists, buddy.allocate(hash, 100));

    try buddy.free(hash);
}

test "BuddyAllocator: error on non-existent block" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    var hash: [32]u8 = undefined;
    std.crypto.random.bytes(&hash);

    try std.testing.expectError(error.BlockNotFound, buddy.getBlock(hash));
    try std.testing.expectError(error.BlockNotFound, buddy.free(hash));
}

test "BuddyAllocator: file expansion on multiple macro blocks" {
    cleanupTestFiles();
    defer cleanupTestFiles();

    const allocator = std.testing.allocator;

    var db = try lmdbx.Database.open("/tmp/buddy_test.db");
    defer db.close();

    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    var buddy = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy.deinit();

    // Allocate enough blocks to trigger multiple 1MB expansions
    // Each 1MB contains 256 blocks of 4KB
    const NUM_BLOCKS = 300;
    var hashes: [NUM_BLOCKS][32]u8 = undefined;

    for (0..NUM_BLOCKS) |i| {
        std.crypto.random.bytes(&hashes[i]);
        _ = try buddy.allocate(hashes[i], 100);
    }

    // File should be at least 2MB (2 macro blocks)
    const file_size = try file_controller.getSize();
    try std.testing.expect(file_size >= 2 * 1048576);

    // Clean up
    for (0..NUM_BLOCKS) |i| {
        try buddy.free(hashes[i]);
    }
}
