const std = @import("std");

/// Block sizes - powers of 2 from 4KB to 1MB
pub const BlockSize = enum(u64) {
    size_4k = 4096,
    size_8k = 8192,
    size_16k = 16384,
    size_32k = 32768,
    size_64k = 65536,
    size_128k = 131072,
    size_256k = 262144,
    size_512k = 524288,
    size_1m = 1048576, // macro block

    pub fn fromBytes(size: u64) !BlockSize {
        return switch (size) {
            4096 => .size_4k,
            8192 => .size_8k,
            16384 => .size_16k,
            32768 => .size_32k,
            65536 => .size_64k,
            131072 => .size_128k,
            262144 => .size_256k,
            524288 => .size_512k,
            1048576 => .size_1m,
            else => error.InvalidBlockSize,
        };
    }

    pub fn toBytes(self: BlockSize) u64 {
        return @intFromEnum(self);
    }

    /// Returns the next smaller size (when splitting)
    pub fn split(self: BlockSize) ?BlockSize {
        return switch (self) {
            .size_1m => .size_512k,
            .size_512k => .size_256k,
            .size_256k => .size_128k,
            .size_128k => .size_64k,
            .size_64k => .size_32k,
            .size_32k => .size_16k,
            .size_16k => .size_8k,
            .size_8k => .size_4k,
            .size_4k => null,
        };
    }

    /// Returns the next larger size (when merging)
    pub fn merge(self: BlockSize) ?BlockSize {
        return switch (self) {
            .size_4k => .size_8k,
            .size_8k => .size_16k,
            .size_16k => .size_32k,
            .size_32k => .size_64k,
            .size_64k => .size_128k,
            .size_128k => .size_256k,
            .size_256k => .size_512k,
            .size_512k => .size_1m,
            .size_1m => null,
        };
    }

    /// Returns string representation for keys (e.g., "4k", "512k", "1m")
    pub fn toString(self: BlockSize) []const u8 {
        return switch (self) {
            .size_4k => "4k",
            .size_8k => "8k",
            .size_16k => "16k",
            .size_32k => "32k",
            .size_64k => "64k",
            .size_128k => "128k",
            .size_256k => "256k",
            .size_512k => "512k",
            .size_1m => "1m",
        };
    }
};

pub const MIN_BLOCK_SIZE: BlockSize = .size_4k; // 4KB
pub const MAX_BLOCK_SIZE: BlockSize = .size_1m; // 1MB
pub const MACRO_BLOCK_SIZE: u64 = 1048576; // 1MB

/// Block metadata stored in LMDBX
pub const BlockMetadata = struct {
    block_size: BlockSize,
    block_num: u64,
    buddy_num: u64,

    /// Encode metadata to 24 bytes for storage
    pub fn encode(self: BlockMetadata) [24]u8 {
        var result: [24]u8 = undefined;
        std.mem.writeInt(u64, result[0..8], self.block_size.toBytes(), .little);
        std.mem.writeInt(u64, result[8..16], self.block_num, .little);
        std.mem.writeInt(u64, result[16..24], self.buddy_num, .little);
        return result;
    }

    /// Decode metadata from 24 bytes
    pub fn decode(data: []const u8) !BlockMetadata {
        if (data.len != 24) return error.InvalidMetadataSize;

        const size_bytes = std.mem.readInt(u64, data[0..8], .little);
        const block_size = BlockSize.fromBytes(size_bytes) catch |err| {
            std.debug.print("BlockSize.fromBytes failed for size_bytes={d}: {any}\n", .{ size_bytes, err });
            return err;
        };
        return .{
            .block_size = block_size,
            .block_num = std.mem.readInt(u64, data[8..16], .little),
            .buddy_num = std.mem.readInt(u64, data[16..24], .little),
        };
    }
};

/// Helper to create free list key: "free_4k_123" -> block of size 4k with number 123
pub fn makeFreeListKey(block_size: BlockSize, block_num: u64, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "free_{s}_{d}", .{ block_size.toString(), block_num });
}

/// Helper to parse free list key: "free_4k_123" -> {size: 4k, block_num: 123}
pub fn parseFreeListKey(key: []const u8) !struct { size: BlockSize, block_num: u64 } {
    var iter = std.mem.splitScalar(u8, key, '_');

    const prefix = iter.next() orelse return error.InvalidKeyFormat;
    if (!std.mem.eql(u8, prefix, "free")) return error.InvalidKeyFormat;

    const size_str = iter.next() orelse return error.InvalidKeyFormat;
    const num_str = iter.next() orelse return error.InvalidKeyFormat;

    const size: BlockSize = blk: {
        if (std.mem.eql(u8, size_str, "4k")) break :blk .size_4k;
        if (std.mem.eql(u8, size_str, "8k")) break :blk .size_8k;
        if (std.mem.eql(u8, size_str, "16k")) break :blk .size_16k;
        if (std.mem.eql(u8, size_str, "32k")) break :blk .size_32k;
        if (std.mem.eql(u8, size_str, "64k")) break :blk .size_64k;
        if (std.mem.eql(u8, size_str, "128k")) break :blk .size_128k;
        if (std.mem.eql(u8, size_str, "256k")) break :blk .size_256k;
        if (std.mem.eql(u8, size_str, "512k")) break :blk .size_512k;
        if (std.mem.eql(u8, size_str, "1m")) break :blk .size_1m;
        std.debug.print("parseFreeListKey: invalid size_str='{s}' in key='{s}'\n", .{ size_str, key });
        return error.InvalidBlockSize;
    };

    const block_num = try std.fmt.parseInt(u64, num_str, 10);

    return .{ .size = size, .block_num = block_num };
}

/// Find next power of 2 greater than or equal to n (minimum 4KB, maximum 1MB)
pub fn nextPowerOfTwo(n: u64) !BlockSize {
    if (n == 0) return MIN_BLOCK_SIZE;
    if (n > MACRO_BLOCK_SIZE) return error.DataTooLarge;

    var power: u64 = MIN_BLOCK_SIZE.toBytes();
    while (power < n and power < MACRO_BLOCK_SIZE) {
        power *= 2;
    }

    return BlockSize.fromBytes(power);
}

// ============================================================================
// Tests
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
    };

    const encoded = original.encode();
    const decoded = try BlockMetadata.decode(&encoded);

    try std.testing.expectEqual(original.block_size, decoded.block_size);
    try std.testing.expectEqual(original.block_num, decoded.block_num);
    try std.testing.expectEqual(original.buddy_num, decoded.buddy_num);
}

test "makeFreeListKey and parseFreeListKey" {
    var buffer: [64]u8 = undefined;

    const key1 = try makeFreeListKey(.size_4k, 123, &buffer);
    try std.testing.expectEqualStrings("4k_123", key1);

    const parsed1 = try parseFreeListKey(key1);
    try std.testing.expectEqual(BlockSize.size_4k, parsed1.size);
    try std.testing.expectEqual(@as(u64, 123), parsed1.block_num);

    const key2 = try makeFreeListKey(.size_256k, 42, &buffer);
    try std.testing.expectEqualStrings("256k_42", key2);

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
