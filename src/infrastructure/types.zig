/// HTTP and infrastructure specific types
/// Block-related types are imported from buddy_allocator module

const std = @import("std");
const picozig = @import("picozig").picozig;

// HTTP Handler types
pub const HandlerError = error{
    OutOfMemory,
    InvalidRequest,
    HandlerNotFound,
    InternalError,
};

pub const HandlerFn = *const fn (picozig.HttpRequest, std.mem.Allocator) anyerror![]const u8;

pub const ProtocolHandler = struct {
    pathPrefix: []const u8,
    method: []const u8,
    handleFn: HandlerFn,
};

// Re-export block types from buddy_allocator module
const buddy_mod = @import("buddy_allocator");
pub const BlockSize = buddy_mod.types.BlockSize;
pub const BlockMetadata = buddy_mod.types.BlockMetadata;
pub const makeFreeListKey = buddy_mod.types.makeFreeListKey;
pub const parseFreeListKey = buddy_mod.types.parseFreeListKey;
pub const nextPowerOfTwo = buddy_mod.types.nextPowerOfTwo;
pub const MACRO_BLOCK_SIZE = buddy_mod.types.MACRO_BLOCK_SIZE;
pub const MIN_BLOCK_SIZE = buddy_mod.types.MIN_BLOCK_SIZE;
pub const MAX_BLOCK_SIZE = buddy_mod.types.MAX_BLOCK_SIZE;

// ============================================================================
// Tests - proxy tests to ensure re-exported types work correctly
// ============================================================================

test "BlockSize: toBytes and fromBytes" {
    try std.testing.expectEqual(@as(u64, 4096), BlockSize.size_4k.toBytes());
    try std.testing.expectEqual(@as(u64, 8192), BlockSize.size_8k.toBytes());
    try std.testing.expectEqual(@as(u64, 1048576), BlockSize.size_1m.toBytes());

    try std.testing.expectEqual(BlockSize.size_4k, try BlockSize.fromBytes(4096));
    try std.testing.expectEqual(BlockSize.size_8k, try BlockSize.fromBytes(8192));
    try std.testing.expectEqual(BlockSize.size_1m, try BlockSize.fromBytes(1048576));

    try std.testing.expectError(error.InvalidBlockSize, BlockSize.fromBytes(1234));
}

test "BlockSize: split and merge" {
    // Split tests
    try std.testing.expectEqual(BlockSize.size_512k, BlockSize.size_1m.split().?);
    try std.testing.expectEqual(BlockSize.size_256k, BlockSize.size_512k.split().?);
    try std.testing.expectEqual(BlockSize.size_4k, BlockSize.size_8k.split().?);
    try std.testing.expect(BlockSize.size_4k.split() == null);

    // Merge tests
    try std.testing.expectEqual(BlockSize.size_8k, BlockSize.size_4k.merge().?);
    try std.testing.expectEqual(BlockSize.size_16k, BlockSize.size_8k.merge().?);
    try std.testing.expectEqual(BlockSize.size_1m, BlockSize.size_512k.merge().?);
    try std.testing.expect(BlockSize.size_1m.merge() == null);
}

test "BlockSize: toString" {
    try std.testing.expectEqualStrings("4k", BlockSize.size_4k.toString());
    try std.testing.expectEqualStrings("256k", BlockSize.size_256k.toString());
    try std.testing.expectEqualStrings("1m", BlockSize.size_1m.toString());
}

test "BlockMetadata: encode and decode" {
    const original = BlockMetadata{
        .block_size = .size_64k,
        .block_num = 123,
        .buddy_num = 122,
        .data_size = 50000,
    };

    const encoded = original.encode();
    const decoded = try BlockMetadata.decode(&encoded);

    try std.testing.expectEqual(original.block_size, decoded.block_size);
    try std.testing.expectEqual(original.block_num, decoded.block_num);
    try std.testing.expectEqual(original.buddy_num, decoded.buddy_num);
    try std.testing.expectEqual(original.data_size, decoded.data_size);
}

test "makeFreeListKey and parseFreeListKey" {
    var buffer: [64]u8 = undefined;

    const key1 = try makeFreeListKey(.size_4k, 123, &buffer);
    try std.testing.expectEqualStrings("free_4k_123", key1);

    const parsed1 = try parseFreeListKey(key1);
    try std.testing.expectEqual(BlockSize.size_4k, parsed1.size);
    try std.testing.expectEqual(@as(u64, 123), parsed1.block_num);

    const key2 = try makeFreeListKey(.size_256k, 42, &buffer);
    try std.testing.expectEqualStrings("free_256k_42", key2);

    const parsed2 = try parseFreeListKey(key2);
    try std.testing.expectEqual(BlockSize.size_256k, parsed2.size);
    try std.testing.expectEqual(@as(u64, 42), parsed2.block_num);
}

test "nextPowerOfTwo" {
    try std.testing.expectEqual(BlockSize.size_4k, try nextPowerOfTwo(0));
    try std.testing.expectEqual(BlockSize.size_4k, try nextPowerOfTwo(1));
    try std.testing.expectEqual(BlockSize.size_4k, try nextPowerOfTwo(4095));
    try std.testing.expectEqual(BlockSize.size_4k, try nextPowerOfTwo(4096));
    try std.testing.expectEqual(BlockSize.size_8k, try nextPowerOfTwo(4097));
    try std.testing.expectEqual(BlockSize.size_8k, try nextPowerOfTwo(8000));
    try std.testing.expectEqual(BlockSize.size_32k, try nextPowerOfTwo(20 * 1024));
    try std.testing.expectEqual(BlockSize.size_1m, try nextPowerOfTwo(1048576));
    try std.testing.expectError(error.DataTooLarge, nextPowerOfTwo(1048577));
}
