const std = @import("std");
const messages = @import("../messaging/messages.zig");
const interfaces = @import("../messaging/interfaces.zig");
const IControllerHandler = interfaces.IControllerHandler;
const IMessageQueue = interfaces.IMessageQueue;

/// Пара очередей для коммуникации с одним worker'ом
pub const WorkerQueues = struct {
    from_worker: IMessageQueue, // Входящие сообщения от worker
    to_worker: IMessageQueue, // Исходящие сообщения к worker
};

/// Batch Controller - единственный поток с доступом к LMDBX
pub const BatchController = struct {
    allocator: std.mem.Allocator,
    message_handler: IControllerHandler,
    worker_queues: []WorkerQueues,

    // Буферы для батчинга сообщений
    allocate_requests: std.ArrayList(messages.AllocateRequest),
    occupy_requests: std.ArrayList(messages.OccupyRequest),
    release_requests: std.ArrayList(messages.ReleaseRequest),
    get_address_requests: std.ArrayList(messages.GetAddressRequest),

    // Буферы для результатов (чтобы отправить после обработки батча)
    allocate_results: std.ArrayList(messages.AllocateResult),
    occupy_results: std.ArrayList(messages.OccupyResult),
    release_results: std.ArrayList(messages.ReleaseResult),
    get_address_results: std.ArrayList(messages.GetAddressResult),
    error_results: std.ArrayList(messages.ErrorResult),

    // Для динамической паузы
    before_run: i128,
    cycle_interval_ns: i128,

    // Флаг работы
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        message_handler: IControllerHandler,
        worker_queues: []WorkerQueues,
        cycle_interval_ns: i128,
    ) !BatchController {
        return .{
            .allocator = allocator,
            .message_handler = message_handler,
            .worker_queues = worker_queues,
            .allocate_requests = .{},
            .occupy_requests = .{},
            .release_requests = .{},
            .get_address_requests = .{},
            .allocate_results = .{},
            .occupy_results = .{},
            .release_results = .{},
            .get_address_results = .{},
            .error_results = .{},
            .before_run = std.time.nanoTimestamp(),
            .cycle_interval_ns = cycle_interval_ns,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *BatchController) void {
        self.allocate_requests.deinit(self.allocator);
        self.occupy_requests.deinit(self.allocator);
        self.release_requests.deinit(self.allocator);
        self.get_address_requests.deinit(self.allocator);
        self.allocate_results.deinit(self.allocator);
        self.occupy_results.deinit(self.allocator);
        self.release_results.deinit(self.allocator);
        self.get_address_results.deinit(self.allocator);
        self.error_results.deinit(self.allocator);
    }

    pub fn run(self: *BatchController) !void {
        while (self.running.load(.monotonic)) {
            // Вычисляем сколько прошло с прошлого цикла
            const now = std.time.nanoTimestamp();
            const elapsed = now - self.before_run;

            // Если прошло меньше интервала - спим на остаток
            if (elapsed < self.cycle_interval_ns) {
                const sleep_ns = self.cycle_interval_ns - elapsed;
                std.Thread.sleep(@intCast(sleep_ns));
            }
            // Обновляем время начала цикла НА now (не на новый timestamp!)
            self.before_run = now;

            // Шаг 1: Собрать все сообщения из входящих очередей
            try self.collectMessages();

            // Шаг 2: Обработать батчи в правильном порядке
            try self.processBatches();

            // Шаг 3: Отправить результаты
            try self.sendResults();
        }
    }

    pub fn shutdown(self: *BatchController) void {
        self.running.store(false, .monotonic);
    }

    /// Собрать все сообщения из входящих очередей и разложить по типам
    fn collectMessages(self: *BatchController) !void {
        for (self.worker_queues) |queues| {
            var msg: messages.Message = undefined;
            while (queues.from_worker.pop(&msg)) {
                switch (msg) {
                    .allocate_block => |req| try self.allocate_requests.append(self.allocator, req),
                    .occupy_block => |req| try self.occupy_requests.append(self.allocator, req),
                    .release_block => |req| try self.release_requests.append(self.allocator, req),
                    .get_address => |req| try self.get_address_requests.append(self.allocator, req),
                    else => {}, // Игнорируем некорректные сообщения
                }
            }
        }
    }

    /// Обработать батчи в правильном порядке:
    /// 1. GetAddress (read-only, сразу отправляем для уменьшения latency)
    /// 2. Release (освобождаем блоки)
    /// 3. Allocate (выделяем блоки)
    /// 4. Occupy (занимаем блоки)
    fn processBatches(self: *BatchController) !void {
        // 1. GetAddress - ПЕРВЫМ! (read-only, уменьшает latency GET запросов)
        for (self.get_address_requests.items) |req| {
            const result = self.message_handler.handleGetAddress(req) catch |err| {
                try self.error_results.append(self.allocator, .{
                    .worker_id = req.worker_id,
                    .request_id = req.request_id,
                    .code = errorToCode(err),
                });
                continue;
            };
            try self.get_address_results.append(self.allocator, result);
        }
        self.get_address_requests.clearRetainingCapacity();

        // 2. Release - освобождаем блоки (возвращаем в buddy allocator)
        for (self.release_requests.items) |req| {
            self.message_handler.handleRelease(req) catch |err| {
                try self.error_results.append(self.allocator, .{
                    .worker_id = req.worker_id,
                    .request_id = req.request_id,
                    .code = errorToCode(err),
                });
                continue;
            };
            try self.release_results.append(self.allocator, .{
                .worker_id = req.worker_id,
                .request_id = req.request_id,
            });
        }
        self.release_requests.clearRetainingCapacity();

        // 3. Allocate - выделяем блоки из buddy allocator
        for (self.allocate_requests.items) |req| {
            const result = self.message_handler.handleAllocate(req) catch |err| {
                try self.error_results.append(self.allocator, .{
                    .worker_id = req.worker_id,
                    .request_id = req.request_id,
                    .code = errorToCode(err),
                });
                continue;
            };
            try self.allocate_results.append(self.allocator, result);
        }
        self.allocate_requests.clearRetainingCapacity();

        // 4. Occupy - занимаем блоки реальными данными
        for (self.occupy_requests.items) |req| {
            const result = self.message_handler.handleOccupy(req) catch |err| {
                try self.error_results.append(self.allocator, .{
                    .worker_id = req.worker_id,
                    .request_id = req.request_id,
                    .code = errorToCode(err),
                });
                continue;
            };
            try self.occupy_results.append(self.allocator, result);
        }
        self.occupy_requests.clearRetainingCapacity();
    }

    /// Отправить результаты в исходящие очереди workers
    fn sendResults(self: *BatchController) !void {
        // Отправляем GetAddress результаты
        for (self.get_address_results.items) |result| {
            const worker_id = result.worker_id;
            if (worker_id >= self.worker_queues.len) continue;

            const msg = messages.Message{ .get_address_result = result };
            _ = self.worker_queues[worker_id].to_worker.push(msg);
        }
        self.get_address_results.clearRetainingCapacity();

        // Отправляем Release результаты
        for (self.release_results.items) |result| {
            const worker_id = result.worker_id;
            if (worker_id >= self.worker_queues.len) continue;

            const msg = messages.Message{ .release_result = result };
            _ = self.worker_queues[worker_id].to_worker.push(msg);
        }
        self.release_results.clearRetainingCapacity();

        // Отправляем Allocate результаты
        for (self.allocate_results.items) |result| {
            const worker_id = result.worker_id;
            if (worker_id >= self.worker_queues.len) continue;

            const msg = messages.Message{ .allocate_result = result };
            _ = self.worker_queues[worker_id].to_worker.push(msg);
        }
        self.allocate_results.clearRetainingCapacity();

        // Отправляем Occupy результаты
        for (self.occupy_results.items) |result| {
            const worker_id = result.worker_id;
            if (worker_id >= self.worker_queues.len) continue;

            const msg = messages.Message{ .occupy_result = result };
            _ = self.worker_queues[worker_id].to_worker.push(msg);
        }
        self.occupy_results.clearRetainingCapacity();

        // Отправляем Error результаты
        for (self.error_results.items) |result| {
            const worker_id = result.worker_id;
            if (worker_id >= self.worker_queues.len) continue;

            const msg = messages.Message{ .error_result = result };
            _ = self.worker_queues[worker_id].to_worker.push(msg);
        }
        self.error_results.clearRetainingCapacity();
    }

    /// Конвертируем ошибки в ErrorCode
    fn errorToCode(err: anyerror) messages.ErrorCode {
        return switch (err) {
            error.BlockNotFound => .block_not_found,
            error.OutOfMemory => .allocation_failed,
            error.InvalidBlockSize => .invalid_size,
            error.AllocationFailed => .allocation_failed,
            else => .internal_error,
        };
    }
};

/// Mock Controller для тестов
pub const MockController = struct {
    run_called: bool = false,
    shutdown_called: bool = false,

    pub fn init() MockController {
        return .{};
    }

    pub fn run(self: *MockController) !void {
        self.run_called = true;
        // Для тестов просто устанавливаем флаг, не запускаем реальный цикл
    }

    pub fn shutdown(self: *MockController) void {
        self.shutdown_called = true;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const message_queue = @import("../messaging/message_queue.zig");
const handler = @import("handler.zig");

test "BatchController - initialization and shutdown" {
    var mock_handler = handler.MockControllerHandler.init();
    const handler_iface = mock_handler.interface();

    var queue1 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue1.deinit();
    var queue2 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue2.deinit();

    const worker_queues = [_]WorkerQueues{.{
        .from_worker = queue1.interface(),
        .to_worker = queue2.interface(),
    }};

    var controller = try BatchController.init(
        testing.allocator,
        handler_iface,
        @constCast(&worker_queues),
        100_000, // 100µs
    );
    defer controller.deinit();

    try testing.expect(controller.running.load(.monotonic));

    controller.shutdown();
    try testing.expect(!controller.running.load(.monotonic));
}

test "BatchController - collectMessages разложение по типам" {
    var mock_handler = handler.MockControllerHandler.init();
    const handler_iface = mock_handler.interface();

    var queue1 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue1.deinit();
    var queue2 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue2.deinit();

    const worker_queues = [_]WorkerQueues{.{
        .from_worker = queue1.interface(),
        .to_worker = queue2.interface(),
    }};

    var controller = try BatchController.init(
        testing.allocator,
        handler_iface,
        @constCast(&worker_queues),
        100_000,
    );
    defer controller.deinit();

    // Отправляем разные типы сообщений
    _ = queue1.interface().push(.{ .allocate_block = .{ .worker_id = 0, .request_id = 1, .size = 2 } });
    _ = queue1.interface().push(.{ .occupy_block = .{ .worker_id = 0, .request_id = 2, .hash = [_]u8{0xAA} ** 32, .data_size = 1024 } });
    _ = queue1.interface().push(.{ .release_block = .{ .worker_id = 0, .request_id = 3, .hash = [_]u8{0xBB} ** 32 } });
    _ = queue1.interface().push(.{ .get_address = .{ .worker_id = 0, .request_id = 4, .hash = [_]u8{0xCC} ** 32 } });

    // Собираем сообщения
    try controller.collectMessages();

    // Проверяем что сообщения разложены по типам
    try testing.expectEqual(@as(usize, 1), controller.allocate_requests.items.len);
    try testing.expectEqual(@as(usize, 1), controller.occupy_requests.items.len);
    try testing.expectEqual(@as(usize, 1), controller.release_requests.items.len);
    try testing.expectEqual(@as(usize, 1), controller.get_address_requests.items.len);

    // Проверяем содержимое
    try testing.expectEqual(@as(u64, 1), controller.allocate_requests.items[0].request_id);
    try testing.expectEqual(@as(u64, 2), controller.occupy_requests.items[0].request_id);
    try testing.expectEqual(@as(u64, 3), controller.release_requests.items[0].request_id);
    try testing.expectEqual(@as(u64, 4), controller.get_address_requests.items[0].request_id);
}

test "BatchController - processBatches порядок обработки" {
    var mock_handler = handler.MockControllerHandler.init();

    // Настраиваем mock handler для возврата результатов
    mock_handler.allocate_response = .{
        .worker_id = 0,
        .request_id = 1,
        .offset = 4096,
        .size = 2,
        .block_num = 100,
    };
    mock_handler.get_address_response = .{
        .worker_id = 0,
        .request_id = 4,
        .offset = 8192,
        .size = 2048,
    };

    const handler_iface = mock_handler.interface();

    var queue1 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue1.deinit();
    var queue2 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue2.deinit();

    const worker_queues = [_]WorkerQueues{.{
        .from_worker = queue1.interface(),
        .to_worker = queue2.interface(),
    }};

    var controller = try BatchController.init(
        testing.allocator,
        handler_iface,
        @constCast(&worker_queues),
        100_000,
    );
    defer controller.deinit();

    // Добавляем запросы напрямую в батч-буферы
    try controller.allocate_requests.append(controller.allocator, .{ .worker_id = 0, .request_id = 1, .size = 2 });
    try controller.occupy_requests.append(controller.allocator, .{ .worker_id = 0, .request_id = 2, .hash = [_]u8{0xAA} ** 32, .data_size = 1024 });
    try controller.release_requests.append(controller.allocator, .{ .worker_id = 0, .request_id = 3, .hash = [_]u8{0xBB} ** 32 });
    try controller.get_address_requests.append(controller.allocator, .{ .worker_id = 0, .request_id = 4, .hash = [_]u8{0xCC} ** 32 });

    // Обрабатываем батчи
    try controller.processBatches();

    // Проверяем что handler был вызван для каждого типа
    try testing.expect(mock_handler.last_allocate != null);
    try testing.expect(mock_handler.last_occupy != null);
    try testing.expect(mock_handler.last_release != null);
    try testing.expect(mock_handler.last_get_address != null);

    // Проверяем что результаты сохранены
    try testing.expectEqual(@as(usize, 1), controller.allocate_results.items.len);
    try testing.expectEqual(@as(usize, 1), controller.occupy_results.items.len);
    try testing.expectEqual(@as(usize, 1), controller.release_results.items.len);
    try testing.expectEqual(@as(usize, 1), controller.get_address_results.items.len);

    // Проверяем содержимое результатов
    try testing.expectEqual(@as(u64, 4096), controller.allocate_results.items[0].offset);
    try testing.expectEqual(@as(u64, 8192), controller.get_address_results.items[0].offset);
}

test "BatchController - sendResults отправка в правильные очереди" {
    var mock_handler = handler.MockControllerHandler.init();
    const handler_iface = mock_handler.interface();

    var queue1 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue1.deinit();
    var queue2 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue2.deinit();

    const worker_queues = [_]WorkerQueues{.{
        .from_worker = queue1.interface(),
        .to_worker = queue2.interface(),
    }};

    var controller = try BatchController.init(
        testing.allocator,
        handler_iface,
        @constCast(&worker_queues),
        100_000,
    );
    defer controller.deinit();

    // Добавляем результаты напрямую в буферы
    try controller.allocate_results.append(controller.allocator, .{
        .worker_id = 0,
        .request_id = 1,
        .offset = 4096,
        .size = 2,
        .block_num = 100,
    });

    try controller.get_address_results.append(controller.allocator, .{
        .worker_id = 0,
        .request_id = 2,
        .offset = 8192,
        .size = 2048,
    });

    // Отправляем результаты
    try controller.sendResults();

    // Проверяем что результаты попали в очередь to_worker
    try testing.expectEqual(@as(usize, 2), queue2.interface().len());

    // Читаем и проверяем сообщения (GetAddress отправляется первым!)
    var msg1: messages.Message = undefined;
    try testing.expect(queue2.interface().pop(&msg1));
    try testing.expectEqual(std.meta.Tag(messages.Message).get_address_result, std.meta.activeTag(msg1));
    try testing.expectEqual(@as(u64, 2), msg1.get_address_result.request_id);

    var msg2: messages.Message = undefined;
    try testing.expect(queue2.interface().pop(&msg2));
    try testing.expectEqual(std.meta.Tag(messages.Message).allocate_result, std.meta.activeTag(msg2));
    try testing.expectEqual(@as(u64, 1), msg2.allocate_result.request_id);
}

test "BatchController - полный цикл обработки" {
    var mock_handler = handler.MockControllerHandler.init();
    mock_handler.allocate_response = .{
        .worker_id = 0,
        .request_id = 1,
        .offset = 4096,
        .size = 2,
        .block_num = 100,
    };
    const handler_iface = mock_handler.interface();

    var queue1 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue1.deinit();
    var queue2 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue2.deinit();

    const worker_queues = [_]WorkerQueues{.{
        .from_worker = queue1.interface(),
        .to_worker = queue2.interface(),
    }};

    var controller = try BatchController.init(
        testing.allocator,
        handler_iface,
        @constCast(&worker_queues),
        100_000,
    );
    defer controller.deinit();

    // Отправляем запрос
    _ = queue1.interface().push(.{ .allocate_block = .{ .worker_id = 0, .request_id = 1, .size = 2 } });

    // Один цикл обработки
    try controller.collectMessages();
    try controller.processBatches();
    try controller.sendResults();

    // Проверяем что результат вернулся
    try testing.expectEqual(@as(usize, 1), queue2.interface().len());

    var msg: messages.Message = undefined;
    try testing.expect(queue2.interface().pop(&msg));
    try testing.expectEqual(std.meta.Tag(messages.Message).allocate_result, std.meta.activeTag(msg));
    try testing.expectEqual(@as(u64, 4096), msg.allocate_result.offset);
}

test "BatchController - обработка ошибок" {
    var mock_handler = handler.MockControllerHandler.init();
    // Не настраиваем allocate_response - handler вернет error.NotConfigured
    const handler_iface = mock_handler.interface();

    var queue1 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue1.deinit();
    var queue2 = message_queue.MockMessageQueue.init(testing.allocator);
    defer queue2.deinit();

    const worker_queues = [_]WorkerQueues{.{
        .from_worker = queue1.interface(),
        .to_worker = queue2.interface(),
    }};

    var controller = try BatchController.init(
        testing.allocator,
        handler_iface,
        @constCast(&worker_queues),
        100_000,
    );
    defer controller.deinit();

    // Добавляем запрос который вызовет ошибку
    try controller.allocate_requests.append(controller.allocator, .{ .worker_id = 0, .request_id = 1, .size = 2 });

    // Обрабатываем
    try controller.processBatches();

    // Проверяем что есть error result
    try testing.expectEqual(@as(usize, 1), controller.error_results.items.len);
    try testing.expectEqual(@as(u64, 1), controller.error_results.items[0].request_id);

    // Отправляем результаты
    try controller.sendResults();

    // Проверяем что error попал в очередь
    try testing.expectEqual(@as(usize, 1), queue2.interface().len());

    var msg: messages.Message = undefined;
    try testing.expect(queue2.interface().pop(&msg));
    try testing.expectEqual(std.meta.Tag(messages.Message).error_result, std.meta.activeTag(msg));
}

test "MockController - basic functionality" {
    var mock = MockController.init();

    try testing.expect(!mock.run_called);
    try testing.expect(!mock.shutdown_called);

    try mock.run();
    try testing.expect(mock.run_called);

    mock.shutdown();
    try testing.expect(mock.shutdown_called);
}
