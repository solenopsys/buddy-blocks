const std = @import("std");
const messages = @import("messages.zig");
const interfaces = @import("interfaces.zig");
const IMessageQueue = interfaces.IMessageQueue;
const spsc = @import("spsc_queue");

/// Реальная SPSC очередь (обертка над lock-free очередью)
pub const RealMessageQueue = struct {
    queue: spsc.SpscQueue(messages.Message, true), // enforce_po2 = true для скорости

    pub fn init(allocator: std.mem.Allocator) !RealMessageQueue {
        return .{
            .queue = try spsc.SpscQueue(messages.Message, true).initCapacity(allocator, 4096),
        };
    }

    pub fn deinit(self: *RealMessageQueue) void {
        self.queue.deinit();
    }

    pub fn interface(self: *RealMessageQueue) IMessageQueue {
        return .{
            .ptr = self,
            .vtable = &.{
                .push = pushImpl,
                .pop = popImpl,
                .len = lenImpl,
            },
        };
    }

    fn pushImpl(ptr: *anyopaque, msg: messages.Message) bool {
        const self: *RealMessageQueue = @ptrCast(@alignCast(ptr));
        return self.queue.tryPush(msg);
    }

    fn popImpl(ptr: *anyopaque, out: *messages.Message) bool {
        const self: *RealMessageQueue = @ptrCast(@alignCast(ptr));
        if (self.queue.front()) |item_ptr| {
            out.* = item_ptr.*;
            self.queue.pop();
            return true;
        }
        return false;
    }

    fn lenImpl(ptr: *anyopaque) usize {
        const self: *RealMessageQueue = @ptrCast(@alignCast(ptr));
        return self.queue.size();
    }
};

/// Mock очередь для тестов (синхронный ArrayList)
pub const MockMessageQueue = struct {
    items: std.ArrayList(messages.Message),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockMessageQueue {
        return .{
            .items = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockMessageQueue) void {
        self.items.deinit(self.allocator);
    }

    pub fn interface(self: *MockMessageQueue) IMessageQueue {
        return .{
            .ptr = self,
            .vtable = &.{
                .push = pushImpl,
                .pop = popImpl,
                .len = lenImpl,
            },
        };
    }

    fn pushImpl(ptr: *anyopaque, msg: messages.Message) bool {
        const self: *MockMessageQueue = @ptrCast(@alignCast(ptr));
        self.items.append(self.allocator, msg) catch return false;
        return true;
    }

    fn popImpl(ptr: *anyopaque, out: *messages.Message) bool {
        const self: *MockMessageQueue = @ptrCast(@alignCast(ptr));
        if (self.items.items.len == 0) return false;
        out.* = self.items.orderedRemove(0);
        return true;
    }

    fn lenImpl(ptr: *anyopaque) usize {
        const self: *MockMessageQueue = @ptrCast(@alignCast(ptr));
        return self.items.items.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "RealMessageQueue - basic push/pop" {
    var queue = try RealMessageQueue.init(testing.allocator);
    defer queue.deinit();
    const iface = queue.interface();

    const msg1 = messages.Message{
        .allocate_block = .{
            .worker_id = 1,
            .request_id = 100,
            .size = 3,
        },
    };

    // Push
    try testing.expect(iface.push(msg1));

    // Pop
    var received: messages.Message = undefined;
    try testing.expect(iface.pop(&received));

    // Проверка
    try testing.expectEqual(std.meta.Tag(messages.Message).allocate_block, std.meta.activeTag(received));
    try testing.expectEqual(@as(u8, 1), received.allocate_block.worker_id);
    try testing.expectEqual(@as(u64, 100), received.allocate_block.request_id);
    try testing.expectEqual(@as(u8, 3), received.allocate_block.size);
}

test "RealMessageQueue - FIFO order" {
    var queue = try RealMessageQueue.init(testing.allocator);
    defer queue.deinit();
    const iface = queue.interface();

    const msg1 = messages.Message{
        .allocate_block = .{
            .worker_id = 1,
            .request_id = 100,
            .size = 1,
        },
    };

    const msg2 = messages.Message{
        .allocate_block = .{
            .worker_id = 2,
            .request_id = 200,
            .size = 2,
        },
    };

    const msg3 = messages.Message{
        .allocate_block = .{
            .worker_id = 3,
            .request_id = 300,
            .size = 3,
        },
    };

    // Push 3 messages
    try testing.expect(iface.push(msg1));
    try testing.expect(iface.push(msg2));
    try testing.expect(iface.push(msg3));

    // Pop в том же порядке
    var received: messages.Message = undefined;

    try testing.expect(iface.pop(&received));
    try testing.expectEqual(@as(u8, 1), received.allocate_block.worker_id);

    try testing.expect(iface.pop(&received));
    try testing.expectEqual(@as(u8, 2), received.allocate_block.worker_id);

    try testing.expect(iface.pop(&received));
    try testing.expectEqual(@as(u8, 3), received.allocate_block.worker_id);

    // Очередь пуста
    try testing.expect(!iface.pop(&received));
}

test "RealMessageQueue - empty queue" {
    var queue = try RealMessageQueue.init(testing.allocator);
    defer queue.deinit();
    const iface = queue.interface();

    var msg: messages.Message = undefined;
    try testing.expect(!iface.pop(&msg));
}

test "MockMessageQueue - basic push/pop" {
    var queue = MockMessageQueue.init(testing.allocator);
    defer queue.deinit();

    const iface = queue.interface();

    const msg1 = messages.Message{
        .occupy_block = .{
            .worker_id = 5,
            .request_id = 500,
            .hash = [_]u8{0xAB} ** 32,
            .data_size = 4096,
        },
    };

    // Push
    try testing.expect(iface.push(msg1));
    try testing.expectEqual(@as(usize, 1), iface.len());

    // Pop
    var received: messages.Message = undefined;
    try testing.expect(iface.pop(&received));
    try testing.expectEqual(@as(usize, 0), iface.len());

    // Проверка
    try testing.expectEqual(std.meta.Tag(messages.Message).occupy_block, std.meta.activeTag(received));
    try testing.expectEqual(@as(u8, 5), received.occupy_block.worker_id);
    try testing.expectEqual(@as(u64, 500), received.occupy_block.request_id);
}

test "MockMessageQueue - multiple messages" {
    var queue = MockMessageQueue.init(testing.allocator);
    defer queue.deinit();

    const iface = queue.interface();

    // Push несколько разных типов сообщений
    try testing.expect(iface.push(.{
        .allocate_block = .{ .worker_id = 1, .request_id = 1, .size = 1 },
    }));

    try testing.expect(iface.push(.{
        .release_block = .{ .worker_id = 2, .request_id = 2, .hash = [_]u8{0} ** 32 },
    }));

    try testing.expect(iface.push(.{
        .error_result = .{ .worker_id = 3, .request_id = 3, .code = .block_not_found },
    }));

    try testing.expectEqual(@as(usize, 3), iface.len());

    // Pop в порядке FIFO
    var msg: messages.Message = undefined;

    try testing.expect(iface.pop(&msg));
    try testing.expectEqual(std.meta.Tag(messages.Message).allocate_block, std.meta.activeTag(msg));

    try testing.expect(iface.pop(&msg));
    try testing.expectEqual(std.meta.Tag(messages.Message).release_block, std.meta.activeTag(msg));

    try testing.expect(iface.pop(&msg));
    try testing.expectEqual(std.meta.Tag(messages.Message).error_result, std.meta.activeTag(msg));

    try testing.expectEqual(@as(usize, 0), iface.len());
}

test "Interface compatibility - Real and Mock work the same" {
    // Test с RealMessageQueue
    {
        var queue = try RealMessageQueue.init(testing.allocator);
        defer queue.deinit();
        const iface = queue.interface();

        const msg = messages.Message{
            .allocate_block = .{ .worker_id = 1, .request_id = 1, .size = 1 },
        };

        try testing.expect(iface.push(msg));
        var received: messages.Message = undefined;
        try testing.expect(iface.pop(&received));
        try testing.expectEqual(@as(u8, 1), received.allocate_block.worker_id);
    }

    // Тот же тест с MockMessageQueue
    {
        var queue = MockMessageQueue.init(testing.allocator);
        defer queue.deinit();
        const iface = queue.interface();

        const msg = messages.Message{
            .allocate_block = .{ .worker_id = 1, .request_id = 1, .size = 1 },
        };

        try testing.expect(iface.push(msg));
        var received: messages.Message = undefined;
        try testing.expect(iface.pop(&received));
        try testing.expectEqual(@as(u8, 1), received.allocate_block.worker_id);
    }
}
