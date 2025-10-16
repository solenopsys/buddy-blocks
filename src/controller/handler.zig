const std = @import("std");
const messages = @import("../messaging/messages.zig");
const interfaces = @import("../messaging/interfaces.zig");
const IControllerHandler = interfaces.IControllerHandler;
const BuddyAllocator = @import("../infrastructure/buddy_allocator.zig").BuddyAllocator;
const types = @import("../infrastructure/types.zig");
const BlockSize = types.BlockSize;

/// Реальный обработчик сообщений для Controller'а (работает с BuddyAllocator)
pub const BuddyControllerHandler = struct {
    buddy_allocator: *BuddyAllocator,

    pub fn init(buddy_allocator: *BuddyAllocator) BuddyControllerHandler {
        return .{
            .buddy_allocator = buddy_allocator,
        };
    }

    pub fn interface(self: *BuddyControllerHandler) IControllerHandler {
        return .{
            .ptr = self,
            .vtable = &.{
                .handle_allocate = handleAllocateImpl,
                .handle_occupy = handleOccupyImpl,
                .handle_release = handleReleaseImpl,
                .handle_get_address = handleGetAddressImpl,
            },
        };
    }

    fn handleAllocateImpl(ptr: *anyopaque, msg: messages.AllocateRequest) !messages.AllocateResult {
        const self: *BuddyControllerHandler = @ptrCast(@alignCast(ptr));

        // Создаем временный "резервный" хеш из worker_id и request_id
        // Это позволит нам выделить блок и записать временный хеш в LMDBX
        // Позже в handleOccupy мы заменим его на реальный хеш
        var temp_hash: [32]u8 = [_]u8{0} ** 32;
        temp_hash[0] = 0xFF; // Маркер резервного хеша
        temp_hash[1] = msg.worker_id;
        std.mem.writeInt(u64, temp_hash[2..10], msg.request_id, .little);

        // Конвертируем data_size в bytes для allocate
        const block_size = try indexToBlockSize(msg.size);
        const data_size = @intFromEnum(block_size);

        // Выделяем блок с резервным хешом
        const metadata = try self.buddy_allocator.allocate(temp_hash, data_size);

        return .{
            .worker_id = msg.worker_id,
            .request_id = msg.request_id,
            .offset = BuddyAllocator.getOffset(metadata),
            .size = msg.size,
            .block_num = metadata.block_num,
        };
    }

    fn handleOccupyImpl(ptr: *anyopaque, msg: messages.OccupyRequest) !void {
        const self: *BuddyControllerHandler = @ptrCast(@alignCast(ptr));

        // NOTE: Текущая реализация просто вызывает allocate()
        // Это работает для совместимости со старым API
        // В будущем нужно будет:
        // 1. Найти резервный блок по worker_id+request_id
        // 2. Удалить резервный хеш
        // 3. Записать реальный хеш с теми же metadata
        _ = try self.buddy_allocator.allocate(msg.hash, msg.data_size);
    }

    fn handleReleaseImpl(ptr: *anyopaque, msg: messages.ReleaseRequest) !void {
        const self: *BuddyControllerHandler = @ptrCast(@alignCast(ptr));

        // Освобождаем блок
        try self.buddy_allocator.free(msg.hash);
    }

    fn handleGetAddressImpl(ptr: *anyopaque, msg: messages.GetAddressRequest) !messages.GetAddressResult {
        const self: *BuddyControllerHandler = @ptrCast(@alignCast(ptr));

        // Получаем metadata блока по хешу
        const metadata = try self.buddy_allocator.getBlock(msg.hash);

        return .{
            .worker_id = msg.worker_id,
            .request_id = msg.request_id,
            .offset = BuddyAllocator.getOffset(metadata),
            .size = @intFromEnum(metadata.block_size),
        };
    }

    fn indexToBlockSize(index: u8) !BlockSize {
        return switch (index) {
            0 => .size_4k,
            1 => .size_8k,
            2 => .size_16k,
            3 => .size_32k,
            4 => .size_64k,
            5 => .size_128k,
            6 => .size_256k,
            7 => .size_512k,
            8 => .size_1m,
            else => error.InvalidSize,
        };
    }
};

/// Mock обработчик для тестов
pub const MockControllerHandler = struct {
    allocate_response: ?messages.AllocateResult = null,
    get_address_response: ?messages.GetAddressResult = null,

    // Для проверки в тестах
    last_allocate: ?messages.AllocateRequest = null,
    last_occupy: ?messages.OccupyRequest = null,
    last_release: ?messages.ReleaseRequest = null,
    last_get_address: ?messages.GetAddressRequest = null,

    pub fn init() MockControllerHandler {
        return .{};
    }

    pub fn interface(self: *MockControllerHandler) IControllerHandler {
        return .{
            .ptr = self,
            .vtable = &.{
                .handle_allocate = handleAllocateImpl,
                .handle_occupy = handleOccupyImpl,
                .handle_release = handleReleaseImpl,
                .handle_get_address = handleGetAddressImpl,
            },
        };
    }

    fn handleAllocateImpl(ptr: *anyopaque, msg: messages.AllocateRequest) !messages.AllocateResult {
        const self: *MockControllerHandler = @ptrCast(@alignCast(ptr));
        self.last_allocate = msg;
        return self.allocate_response orelse error.NotConfigured;
    }

    fn handleOccupyImpl(ptr: *anyopaque, msg: messages.OccupyRequest) !void {
        const self: *MockControllerHandler = @ptrCast(@alignCast(ptr));
        self.last_occupy = msg;
    }

    fn handleReleaseImpl(ptr: *anyopaque, msg: messages.ReleaseRequest) !void {
        const self: *MockControllerHandler = @ptrCast(@alignCast(ptr));
        self.last_release = msg;
    }

    fn handleGetAddressImpl(ptr: *anyopaque, msg: messages.GetAddressRequest) !messages.GetAddressResult {
        const self: *MockControllerHandler = @ptrCast(@alignCast(ptr));
        self.last_get_address = msg;
        return self.get_address_response orelse error.NotConfigured;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "MockControllerHandler - allocate" {
    var handler = MockControllerHandler.init();
    handler.allocate_response = .{
        .worker_id = 1,
        .request_id = 100,
        .offset = 4096,
        .size = 0,
        .block_num = 1,
    };

    const iface = handler.interface();

    const request = messages.AllocateRequest{
        .worker_id = 1,
        .request_id = 100,
        .size = 0,
    };

    const result = try iface.handleAllocate(request);

    try testing.expectEqual(@as(u8, 1), result.worker_id);
    try testing.expectEqual(@as(u64, 100), result.request_id);
    try testing.expectEqual(@as(u64, 4096), result.offset);
    try testing.expectEqual(@as(u8, 0), result.size);
    try testing.expectEqual(@as(u64, 1), result.block_num);

    // Проверяем что запрос был записан
    try testing.expect(handler.last_allocate != null);
    try testing.expectEqual(@as(u8, 0), handler.last_allocate.?.size);
}

test "MockControllerHandler - occupy" {
    var handler = MockControllerHandler.init();
    const iface = handler.interface();

    const request = messages.OccupyRequest{
        .worker_id = 1,
        .request_id = 200,
        .hash = [_]u8{0xAA} ** 32,
        .data_size = 1024,
    };

    try iface.handleOccupy(request);

    // Проверяем что запрос был записан
    try testing.expect(handler.last_occupy != null);
    try testing.expectEqual(@as(u64, 200), handler.last_occupy.?.request_id);
    try testing.expectEqual(@as(u64, 1024), handler.last_occupy.?.data_size);
}

test "MockControllerHandler - release" {
    var handler = MockControllerHandler.init();
    const iface = handler.interface();

    const request = messages.ReleaseRequest{
        .worker_id = 1,
        .request_id = 300,
        .hash = [_]u8{0xBB} ** 32,
    };

    try iface.handleRelease(request);

    // Проверяем что запрос был записан
    try testing.expect(handler.last_release != null);
    try testing.expectEqual(@as(u64, 300), handler.last_release.?.request_id);
}

test "MockControllerHandler - get address" {
    var handler = MockControllerHandler.init();
    handler.get_address_response = .{
        .worker_id = 1,
        .request_id = 400,
        .offset = 8192,
        .size = 2048,
    };

    const iface = handler.interface();

    const request = messages.GetAddressRequest{
        .worker_id = 1,
        .request_id = 400,
        .hash = [_]u8{0xCC} ** 32,
    };

    const result = try iface.handleGetAddress(request);

    try testing.expectEqual(@as(u64, 8192), result.offset);
    try testing.expectEqual(@as(u64, 2048), result.size);

    // Проверяем что запрос был записан
    try testing.expect(handler.last_get_address != null);
    try testing.expectEqual(@as(u64, 400), handler.last_get_address.?.request_id);
}

test "Interface compatibility - both implementations work through same interface" {
    // Test Mock
    {
        var mock = MockControllerHandler.init();
        mock.allocate_response = .{
            .worker_id = 1,
            .request_id = 1,
            .offset = 0,
            .size = 0,
            .block_num = 1,
        };

        const iface = mock.interface();
        const request = messages.AllocateRequest{ .worker_id = 1, .request_id = 1, .size = 0 };
        const result = try iface.handleAllocate(request);

        try testing.expectEqual(@as(u64, 1), result.request_id);
    }

    // NOTE: BuddyControllerHandler test requires real BuddyAllocator instance
    // Will be tested in integration tests
}
