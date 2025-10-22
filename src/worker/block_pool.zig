const std = @import("std");
const interfaces = @import("../messaging/interfaces.zig");
const IBlockPool = interfaces.IBlockPool;
const BlockInfo = interfaces.BlockInfo;

/// Простой пул блоков для Worker'а
pub const SimpleBlockPool = struct {
    size: u8, // Размер блока (enum index 0-7)
    target_free: usize, // Целевое количество свободных блоков в пуле
    free_blocks: std.ArrayList(BlockInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: u8, target_free: usize) !SimpleBlockPool {
        return .{
            .size = size,
            .target_free = target_free,
            .free_blocks = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SimpleBlockPool) void {
        self.free_blocks.deinit(self.allocator);
    }

    pub fn interface(self: *SimpleBlockPool) IBlockPool {
        return .{
            .ptr = self,
            .vtable = &.{
                .acquire = acquireImpl,
                .release = releaseImpl,
                .needs_refill = needsRefillImpl,
                .get_size = getSizeImpl,
            },
        };
    }

    /// Добавить блок в пул (вызывается когда Controller выделил блок)
    pub fn addBlock(self: *SimpleBlockPool, block: BlockInfo) !void {
        try self.free_blocks.append(self.allocator, block);
    }

    fn acquireImpl(ptr: *anyopaque) ?BlockInfo {
        const self: *SimpleBlockPool = @ptrCast(@alignCast(ptr));
        if (self.free_blocks.items.len == 0) return null;
        return self.free_blocks.pop();
    }

    fn releaseImpl(ptr: *anyopaque, block: BlockInfo) void {
        const self: *SimpleBlockPool = @ptrCast(@alignCast(ptr));
        self.free_blocks.append(self.allocator, block) catch {};
    }

    fn needsRefillImpl(ptr: *anyopaque) bool {
        const self: *SimpleBlockPool = @ptrCast(@alignCast(ptr));
        return self.free_blocks.items.len < self.target_free;
    }

    fn getSizeImpl(ptr: *anyopaque) u8 {
        const self: *SimpleBlockPool = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

/// Mock пул для тестов
pub const MockBlockPool = struct {
    size: u8,
    blocks_to_return: std.ArrayList(BlockInfo),
    needs_refill_response: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: u8) MockBlockPool {
        return .{
            .size = size,
            .blocks_to_return = .{},
            .needs_refill_response = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockBlockPool) void {
        self.blocks_to_return.deinit(self.allocator);
    }

    pub fn interface(self: *MockBlockPool) IBlockPool {
        return .{
            .ptr = self,
            .vtable = &.{
                .acquire = acquireImpl,
                .release = releaseImpl,
                .needs_refill = needsRefillImpl,
                .get_size = getSizeImpl,
            },
        };
    }

    /// Добавить блок для возврата в тестах
    pub fn addBlock(self: *MockBlockPool, block: BlockInfo) !void {
        try self.blocks_to_return.append(self.allocator, block);
    }

    fn acquireImpl(ptr: *anyopaque) ?BlockInfo {
        const self: *MockBlockPool = @ptrCast(@alignCast(ptr));
        if (self.blocks_to_return.items.len == 0) return null;
        return self.blocks_to_return.pop();
    }

    fn releaseImpl(ptr: *anyopaque, block: BlockInfo) void {
        const self: *MockBlockPool = @ptrCast(@alignCast(ptr));
        self.blocks_to_return.append(self.allocator, block) catch {};
    }

    fn needsRefillImpl(ptr: *anyopaque) bool {
        const self: *MockBlockPool = @ptrCast(@alignCast(ptr));
        return self.needs_refill_response;
    }

    fn getSizeImpl(ptr: *anyopaque) u8 {
        const self: *MockBlockPool = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "SimpleBlockPool - basic acquire/release" {
    var pool = try SimpleBlockPool.init(testing.allocator, 0, 5);
    defer pool.deinit();

    const iface = pool.interface();

    // Пул пустой
    try testing.expect(iface.acquire() == null);
    try testing.expect(iface.needsRefill());
    try testing.expectEqual(@as(u8, 0), iface.getSize());

    // Добавляем блок
    const block1 = BlockInfo{
        .size = 0,
        .block_num = 1,
    };
    try pool.addBlock(block1);

    // Берем блок
    const acquired = iface.acquire().?;
    try testing.expectEqual(@as(u64, 4096), acquired.getOffset());
    try testing.expectEqual(@as(u8, 0), acquired.size);
    try testing.expectEqual(@as(u64, 1), acquired.block_num);

    // Пул снова пустой
    try testing.expect(iface.acquire() == null);
}

test "SimpleBlockPool - needsRefill logic" {
    var pool = try SimpleBlockPool.init(testing.allocator, 0, 3);
    defer pool.deinit();

    const iface = pool.interface();

    // target_free = 3, currently 0 -> needs refill
    try testing.expect(iface.needsRefill());

    // Добавляем 1 блок
    try pool.addBlock(.{ .size = 0, .block_num = 1 });
    try testing.expect(iface.needsRefill()); // still < 3

    // Добавляем еще 2 блока
    try pool.addBlock(.{ .size = 0, .block_num = 2 });
    try pool.addBlock(.{ .size = 0, .block_num = 3 });
    try testing.expect(!iface.needsRefill()); // now == 3, no refill needed

    // Берем один блок
    _ = iface.acquire();
    try testing.expect(iface.needsRefill()); // now < 3, needs refill again
}

test "SimpleBlockPool - release returns block to pool" {
    var pool = try SimpleBlockPool.init(testing.allocator, 0, 5);
    defer pool.deinit();

    const iface = pool.interface();

    const block = BlockInfo{
        .size = 0,
        .block_num = 99,
    };

    // Освобождаем блок
    iface.release(block);

    // Можем забрать его обратно
    const acquired = iface.acquire().?;
    try testing.expectEqual(@as(u64, 405504), acquired.getOffset()); // 99 * 4096
    try testing.expectEqual(@as(u64, 99), acquired.block_num);
}

test "MockBlockPool - configurable behavior" {
    var pool = MockBlockPool.init(testing.allocator, 2);
    defer pool.deinit();

    const iface = pool.interface();

    // Настраиваем needsRefill
    pool.needs_refill_response = true;
    try testing.expect(iface.needsRefill());

    pool.needs_refill_response = false;
    try testing.expect(!iface.needsRefill());

    // Настраиваем блоки для возврата
    try pool.addBlock(.{ .size = 2, .block_num = 10 });
    try pool.addBlock(.{ .size = 2, .block_num = 20 });

    const b1 = iface.acquire().?;
    try testing.expectEqual(@as(u64, 327680), b1.getOffset()); // LIFO порядок (stack) - 20 * 16384

    const b2 = iface.acquire().?;
    try testing.expectEqual(@as(u64, 163840), b2.getOffset()); // 10 * 16384

    try testing.expect(iface.acquire() == null);
}

test "MockBlockPool - getSize" {
    var pool = MockBlockPool.init(testing.allocator, 5);
    defer pool.deinit();

    const iface = pool.interface();
    try testing.expectEqual(@as(u8, 5), iface.getSize());
}

test "Interface compatibility - Simple and Mock work the same" {
    // Test с SimpleBlockPool
    {
        var pool = try SimpleBlockPool.init(testing.allocator, 0, 5);
        defer pool.deinit();

        try pool.addBlock(.{ .size = 0, .block_num = 1 });

        const iface = pool.interface();
        const block = iface.acquire().?;
        try testing.expectEqual(@as(u64, 4096), block.getOffset()); // 1 * 4096
    }

    // Тот же тест с MockBlockPool
    {
        var pool = MockBlockPool.init(testing.allocator, 0);
        defer pool.deinit();

        try pool.addBlock(.{ .size = 0, .block_num = 1 });

        const iface = pool.interface();
        const block = iface.acquire().?;
        try testing.expectEqual(@as(u64, 4096), block.getOffset()); // 1 * 4096
    }
}
