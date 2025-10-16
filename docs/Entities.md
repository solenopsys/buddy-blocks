# Entities and Interfaces - Разборная архитектура

## Принципы проектирования

1. **Каждый компонент работает через интерфейс**
2. **Зависимости инжектятся через конструктор**
3. **Каждый компонент тестируется изолированно с моками**
4. **Система собирается как конструктор (plug-and-play)**

---

## 1. SPSC Queue - Очередь коммуникации

### Интерфейс
```zig
pub const ISPSCQueue = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push: *const fn(ptr: *anyopaque, data: []const u8) bool,
        pop: *const fn(ptr: *anyopaque, buffer: []u8) ?usize,
        len: *const fn(ptr: *anyopaque) usize,
    };

    pub fn push(self: ISPSCQueue, data: []const u8) bool {
        return self.vtable.push(self.ptr, data);
    }

    pub fn pop(self: ISPSCQueue, buffer: []u8) ?usize {
        return self.vtable.pop(self.ptr, buffer);
    }

    pub fn len(self: ISPSCQueue) usize {
        return self.vtable.len(self.ptr);
    }
};
```

### Реализация: RealSPSCQueue
```zig
pub const RealSPSCQueue = struct {
    inner: *spsc.Queue,  // https://github.com/freref/spsc-queue
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) !RealSPSCQueue {
        const queue = try allocator.create(spsc.Queue);
        queue.* = try spsc.Queue.init(capacity);
        return .{ .inner = queue, .allocator = allocator };
    }

    pub fn deinit(self: *RealSPSCQueue) void {
        self.inner.deinit();
        self.allocator.destroy(self.inner);
    }

    pub fn interface(self: *RealSPSCQueue) ISPSCQueue {
        return .{
            .ptr = self,
            .vtable = &.{
                .push = pushImpl,
                .pop = popImpl,
                .len = lenImpl,
            },
        };
    }

    fn pushImpl(ptr: *anyopaque, data: []const u8) bool {
        const self: *RealSPSCQueue = @ptrCast(@alignCast(ptr));
        return self.inner.push(data);
    }

    fn popImpl(ptr: *anyopaque, buffer: []u8) ?usize {
        const self: *RealSPSCQueue = @ptrCast(@alignCast(ptr));
        return self.inner.pop(buffer);
    }

    fn lenImpl(ptr: *anyopaque) usize {
        const self: *RealSPSCQueue = @ptrCast(@alignCast(ptr));
        return self.inner.len();
    }
};
```

### Mock: MockSPSCQueue
```zig
pub const MockSPSCQueue = struct {
    items: std.ArrayList([]u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MockSPSCQueue {
        return .{
            .items = std.ArrayList([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockSPSCQueue) void {
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit();
    }

    pub fn interface(self: *MockSPSCQueue) ISPSCQueue {
        return .{
            .ptr = self,
            .vtable = &.{
                .push = pushImpl,
                .pop = popImpl,
                .len = lenImpl,
            },
        };
    }

    fn pushImpl(ptr: *anyopaque, data: []const u8) bool {
        const self: *MockSPSCQueue = @ptrCast(@alignCast(ptr));
        const copy = self.allocator.dupe(u8, data) catch return false;
        self.items.append(copy) catch return false;
        return true;
    }

    fn popImpl(ptr: *anyopaque, buffer: []u8) ?usize {
        const self: *MockSPSCQueue = @ptrCast(@alignCast(ptr));
        if (self.items.items.len == 0) return null;
        const item = self.items.orderedRemove(0);
        defer self.allocator.free(item);
        @memcpy(buffer[0..item.len], item);
        return item.len;
    }

    fn lenImpl(ptr: *anyopaque) usize {
        const self: *MockSPSCQueue = @ptrCast(@alignCast(ptr));
        return self.items.items.len;
    }
};
```

### Тестирование
```zig
test "ISPSCQueue - real implementation" {
    var queue = try RealSPSCQueue.init(testing.allocator, 1024);
    defer queue.deinit();

    const iface = queue.interface();

    // Test push/pop
    try testing.expect(iface.push("hello"));
    var buffer: [10]u8 = undefined;
    const len = iface.pop(&buffer).?;
    try testing.expectEqualStrings("hello", buffer[0..len]);
}

test "ISPSCQueue - mock implementation" {
    var mock = MockSPSCQueue.init(testing.allocator);
    defer mock.deinit();

    const iface = mock.interface();

    // Same test as above - interface is identical!
    try testing.expect(iface.push("hello"));
    var buffer: [10]u8 = undefined;
    const len = iface.pop(&buffer).?;
    try testing.expectEqualStrings("hello", buffer[0..len]);
}
```

---

## 2. Message Handler - Обработка сообщений

### Интерфейс
```zig
pub const IMessageHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle_allocate: *const fn(ptr: *anyopaque, msg: messages.AllocateRequest) anyerror!messages.AllocateResult,
        handle_occupy: *const fn(ptr: *anyopaque, msg: messages.OccupyRequest) anyerror!void,
        handle_release: *const fn(ptr: *anyopaque, msg: messages.ReleaseRequest) anyerror!void,
        handle_get_address: *const fn(ptr: *anyopaque, msg: messages.GetAddressRequest) anyerror!messages.GetAddressResult,
    };

    pub fn handleAllocate(self: IMessageHandler, msg: messages.AllocateRequest) !messages.AllocateResult {
        return self.vtable.handle_allocate(self.ptr, msg);
    }

    pub fn handleOccupy(self: IMessageHandler, msg: messages.OccupyRequest) !void {
        return self.vtable.handle_occupy(self.ptr, msg);
    }

    pub fn handleRelease(self: IMessageHandler, msg: messages.ReleaseRequest) !void {
        return self.vtable.handle_release(self.ptr, msg);
    }

    pub fn handleGetAddress(self: IMessageHandler, msg: messages.GetAddressRequest) !messages.GetAddressResult {
        return self.vtable.handle_get_address(self.ptr, msg);
    }
};
```

### Реализация: BuddyMessageHandler
```zig
pub const BuddyMessageHandler = struct {
    buddy_allocator: *BuddyAllocator,
    allocator: Allocator,

    pub fn init(buddy_allocator: *BuddyAllocator, allocator: Allocator) BuddyMessageHandler {
        return .{
            .buddy_allocator = buddy_allocator,
            .allocator = allocator,
        };
    }

    pub fn interface(self: *BuddyMessageHandler) IMessageHandler {
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
        const self: *BuddyMessageHandler = @ptrCast(@alignCast(ptr));
        const metadata = try self.buddy_allocator.allocateBlock(msg.size);
        return .{
            .offset = BuddyAllocator.getOffset(metadata),
            .size = msg.size,
            .block_num = metadata.block_num,
        };
    }

    fn handleOccupyImpl(ptr: *anyopaque, msg: messages.OccupyRequest) !void {
        const self: *BuddyMessageHandler = @ptrCast(@alignCast(ptr));
        try self.buddy_allocator.occupyBlock(msg.hash, msg.data_size);
    }

    fn handleReleaseImpl(ptr: *anyopaque, msg: messages.ReleaseRequest) !void {
        const self: *BuddyMessageHandler = @ptrCast(@alignCast(ptr));
        try self.buddy_allocator.free(msg.hash);
    }

    fn handleGetAddressImpl(ptr: *anyopaque, msg: messages.GetAddressRequest) !messages.GetAddressResult {
        const self: *BuddyMessageHandler = @ptrCast(@alignCast(ptr));
        const metadata = try self.buddy_allocator.getBlock(msg.hash);
        return .{
            .offset = BuddyAllocator.getOffset(metadata),
            .size = metadata.data_size,
        };
    }
};
```

### Mock: MockMessageHandler
```zig
pub const MockMessageHandler = struct {
    allocate_response: ?messages.AllocateResult = null,
    get_address_response: ?messages.GetAddressResult = null,

    // Для проверки в тестах
    last_allocate: ?messages.AllocateRequest = null,
    last_occupy: ?messages.OccupyRequest = null,
    last_release: ?messages.ReleaseRequest = null,
    last_get_address: ?messages.GetAddressRequest = null,

    pub fn init() MockMessageHandler {
        return .{};
    }

    pub fn interface(self: *MockMessageHandler) IMessageHandler {
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
        const self: *MockMessageHandler = @ptrCast(@alignCast(ptr));
        self.last_allocate = msg;
        return self.allocate_response orelse error.NotConfigured;
    }

    fn handleOccupyImpl(ptr: *anyopaque, msg: messages.OccupyRequest) !void {
        const self: *MockMessageHandler = @ptrCast(@alignCast(ptr));
        self.last_occupy = msg;
    }

    fn handleReleaseImpl(ptr: *anyopaque, msg: messages.ReleaseRequest) !void {
        const self: *MockMessageHandler = @ptrCast(@alignCast(ptr));
        self.last_release = msg;
    }

    fn handleGetAddressImpl(ptr: *anyopaque, msg: messages.GetAddressRequest) !messages.GetAddressResult {
        const self: *MockMessageHandler = @ptrCast(@alignCast(ptr));
        self.last_get_address = msg;
        return self.get_address_response orelse error.NotConfigured;
    }
};
```

---

## 3. Block Pool - Пул блоков в Worker

### Интерфейс
```zig
pub const IBlockPool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        acquire: *const fn(ptr: *anyopaque) ?BlockInfo,
        release: *const fn(ptr: *anyopaque, block: BlockInfo) void,
        needsRefill: *const fn(ptr: *anyopaque) bool,
        getSize: *const fn(ptr: *anyopaque) u8,
    };

    pub fn acquire(self: IBlockPool) ?BlockInfo {
        return self.vtable.acquire(self.ptr);
    }

    pub fn release(self: IBlockPool, block: BlockInfo) void {
        self.vtable.release(self.ptr, block);
    }

    pub fn needsRefill(self: IBlockPool) bool {
        return self.vtable.needsRefill(self.ptr);
    }

    pub fn getSize(self: IBlockPool) u8 {
        return self.vtable.getSize(self.ptr);
    }
};

pub const BlockInfo = struct {
    offset: u64,
    size: u8,
    block_num: u64,
};
```

### Реализация: SimpleBlockPool
```zig
pub const SimpleBlockPool = struct {
    size: u8,
    target_free: usize,
    free_blocks: std.ArrayList(BlockInfo),
    allocator: Allocator,

    pub fn init(allocator: Allocator, size: u8, target_free: usize) !SimpleBlockPool {
        return .{
            .size = size,
            .target_free = target_free,
            .free_blocks = std.ArrayList(BlockInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SimpleBlockPool) void {
        self.free_blocks.deinit();
    }

    pub fn interface(self: *SimpleBlockPool) IBlockPool {
        return .{
            .ptr = self,
            .vtable = &.{
                .acquire = acquireImpl,
                .release = releaseImpl,
                .needsRefill = needsRefillImpl,
                .getSize = getSizeImpl,
            },
        };
    }

    fn acquireImpl(ptr: *anyopaque) ?BlockInfo {
        const self: *SimpleBlockPool = @ptrCast(@alignCast(ptr));
        if (self.free_blocks.items.len == 0) return null;
        return self.free_blocks.pop();
    }

    fn releaseImpl(ptr: *anyopaque, block: BlockInfo) void {
        const self: *SimpleBlockPool = @ptrCast(@alignCast(ptr));
        self.free_blocks.append(block) catch {};
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
```

### Mock: MockBlockPool
```zig
pub const MockBlockPool = struct {
    size: u8,
    blocks_to_return: std.ArrayList(BlockInfo),
    needs_refill_response: bool = false,
    allocator: Allocator,

    pub fn init(allocator: Allocator, size: u8) MockBlockPool {
        return .{
            .size = size,
            .blocks_to_return = std.ArrayList(BlockInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockBlockPool) void {
        self.blocks_to_return.deinit();
    }

    pub fn interface(self: *MockBlockPool) IBlockPool {
        return .{
            .ptr = self,
            .vtable = &.{
                .acquire = acquireImpl,
                .release = releaseImpl,
                .needsRefill = needsRefillImpl,
                .getSize = getSizeImpl,
            },
        };
    }

    fn acquireImpl(ptr: *anyopaque) ?BlockInfo {
        const self: *MockBlockPool = @ptrCast(@alignCast(ptr));
        if (self.blocks_to_return.items.len == 0) return null;
        return self.blocks_to_return.pop();
    }

    fn releaseImpl(ptr: *anyopaque, block: BlockInfo) void {
        const self: *MockBlockPool = @ptrCast(@alignCast(ptr));
        self.blocks_to_return.append(block) catch {};
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
```

---

## 4. Controller - Обработка батчей

### Интерфейс
```zig
pub const IController = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn(ptr: *anyopaque) anyerror!void,
        shutdown: *const fn(ptr: *anyopaque) void,
    };

    pub fn run(self: IController) !void {
        return self.vtable.run(self.ptr);
    }

    pub fn shutdown(self: IController) void {
        self.vtable.shutdown(self.ptr);
    }
};
```

### Реализация: BatchController
```zig
pub const BatchController = struct {
    allocator: Allocator,
    message_handler: IMessageHandler,  // Зависимость через интерфейс!
    worker_queues: []WorkerQueues,     // ISPSCQueue внутри

    // Буферы для батчинга
    allocate_requests: std.ArrayList(messages.AllocateRequest),
    occupy_requests: std.ArrayList(messages.OccupyRequest),
    release_requests: std.ArrayList(messages.ReleaseRequest),
    get_address_requests: std.ArrayList(messages.GetAddressRequest),

    // Для паузы
    before_run: i64,
    cycle_interval_ns: i64,

    running: std.atomic.Value(bool),

    pub const WorkerQueues = struct {
        from_worker: ISPSCQueue,  // Интерфейс!
        to_worker: ISPSCQueue,    // Интерфейс!
    };

    pub fn init(
        allocator: Allocator,
        message_handler: IMessageHandler,  // Инжектим через интерфейс
        worker_queues: []WorkerQueues,
        cycle_interval_ns: i64,
    ) !BatchController {
        return .{
            .allocator = allocator,
            .message_handler = message_handler,
            .worker_queues = worker_queues,
            .allocate_requests = std.ArrayList(messages.AllocateRequest).init(allocator),
            .occupy_requests = std.ArrayList(messages.OccupyRequest).init(allocator),
            .release_requests = std.ArrayList(messages.ReleaseRequest).init(allocator),
            .get_address_requests = std.ArrayList(messages.GetAddressRequest).init(allocator),
            .before_run = std.time.nanoTimestamp(),
            .cycle_interval_ns = cycle_interval_ns,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *BatchController) void {
        self.allocate_requests.deinit();
        self.occupy_requests.deinit();
        self.release_requests.deinit();
        self.get_address_requests.deinit();
    }

    pub fn interface(self: *BatchController) IController {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = runImpl,
                .shutdown = shutdownImpl,
            },
        };
    }

    fn runImpl(ptr: *anyopaque) !void {
        const self: *BatchController = @ptrCast(@alignCast(ptr));

        while (self.running.load(.monotonic)) {
            // Шаг 0: Динамическая пауза
            const now = std.time.nanoTimestamp();
            const elapsed = now - self.before_run;
            if (elapsed < self.cycle_interval_ns) {
                const sleep_ns = self.cycle_interval_ns - elapsed;
                std.time.sleep(@intCast(sleep_ns));
            }
            self.before_run = std.time.nanoTimestamp();

            // Шаг 1-2: Собрать и разложить сообщения
            try self.collectMessages();

            // Шаг 3-7: Обработать батчи
            try self.processBatches();

            // Шаг 8: Отправить результаты
            try self.sendResults();
        }
    }

    fn shutdownImpl(ptr: *anyopaque) void {
        const self: *BatchController = @ptrCast(@alignCast(ptr));
        self.running.store(false, .monotonic);
    }

    fn collectMessages(self: *BatchController) !void {
        // Опрос всех очередей от workers
        for (self.worker_queues) |queues| {
            var buffer: [1024]u8 = undefined;
            while (queues.from_worker.pop(&buffer)) |len| {
                const msg_bytes = buffer[0..len];
                // Десериализовать и разложить по типам
                try self.distributeMessage(msg_bytes);
            }
        }
    }

    fn processBatches(self: *BatchController) !void {
        // 1. Release (ПЕРВЫМ!)
        for (self.release_requests.items) |req| {
            self.message_handler.handleRelease(req) catch |err| {
                // Отправить error message
                try self.sendError(req.worker_id, req.request_id, err);
            };
        }
        self.release_requests.clearRetainingCapacity();

        // 2. Allocate
        for (self.allocate_requests.items) |req| {
            const result = self.message_handler.handleAllocate(req) catch |err| {
                try self.sendError(req.worker_id, req.request_id, err);
                continue;
            };
            try self.sendAllocateResult(req.worker_id, req.request_id, result);
        }
        self.allocate_requests.clearRetainingCapacity();

        // 3. Occupy
        for (self.occupy_requests.items) |req| {
            self.message_handler.handleOccupy(req) catch |err| {
                try self.sendError(req.worker_id, req.request_id, err);
                continue;
            };
            try self.sendOccupyResult(req.worker_id, req.request_id);
        }
        self.occupy_requests.clearRetainingCapacity();

        // 4. GetAddress
        for (self.get_address_requests.items) |req| {
            const result = self.message_handler.handleGetAddress(req) catch |err| {
                try self.sendError(req.worker_id, req.request_id, err);
                continue;
            };
            try self.sendGetAddressResult(req.worker_id, req.request_id, result);
        }
        self.get_address_requests.clearRetainingCapacity();
    }

    // ... sendResults, sendError, etc.
};
```

### Mock: MockController
```zig
pub const MockController = struct {
    running: bool = true,
    run_called: bool = false,
    shutdown_called: bool = false,

    pub fn init() MockController {
        return .{};
    }

    pub fn interface(self: *MockController) IController {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = runImpl,
                .shutdown = shutdownImpl,
            },
        };
    }

    fn runImpl(ptr: *anyopaque) !void {
        const self: *MockController = @ptrCast(@alignCast(ptr));
        self.run_called = true;
    }

    fn shutdownImpl(ptr: *anyopaque) void {
        const self: *MockController = @ptrCast(@alignCast(ptr));
        self.shutdown_called = true;
        self.running = false;
    }
};
```

---

## 5. Worker - HTTP сервер + пулы блоков

### Интерфейс
```zig
pub const IWorker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn(ptr: *anyopaque) anyerror!void,
        shutdown: *const fn(ptr: *anyopaque) void,
    };

    pub fn run(self: IWorker) !void {
        return self.vtable.run(self.ptr);
    }

    pub fn shutdown(self: IWorker) void {
        self.vtable.shutdown(self.ptr);
    }
};
```

### Реализация: HttpWorker
```zig
pub const HttpWorker = struct {
    id: u8,
    allocator: Allocator,
    ring: linux.IoUring,
    server_socket: posix.fd_t,
    file_fd: posix.fd_t,

    // Пулы блоков (через интерфейсы!)
    block_pools: [8]IBlockPool,

    // Очереди (через интерфейсы!)
    to_controller: ISPSCQueue,
    from_controller: ISPSCQueue,

    running: std.atomic.Value(bool),

    pub fn init(
        id: u8,
        allocator: Allocator,
        port: u16,
        file_fd: posix.fd_t,
        block_pools: [8]IBlockPool,  // Инжектим через интерфейс!
        to_controller: ISPSCQueue,   // Инжектим через интерфейс!
        from_controller: ISPSCQueue, // Инжектим через интерфейс!
    ) !HttpWorker {
        const server_socket = try createServerSocket(port);
        const ring = try linux.IoUring.init(256, 0);

        return .{
            .id = id,
            .allocator = allocator,
            .ring = ring,
            .server_socket = server_socket,
            .file_fd = file_fd,
            .block_pools = block_pools,
            .to_controller = to_controller,
            .from_controller = from_controller,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *HttpWorker) void {
        self.ring.deinit();
        posix.close(self.server_socket);
    }

    pub fn interface(self: *HttpWorker) IWorker {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = runImpl,
                .shutdown = shutdownImpl,
            },
        };
    }

    fn runImpl(ptr: *anyopaque) !void {
        const self: *HttpWorker = @ptrCast(@alignCast(ptr));

        while (self.running.load(.monotonic)) {
            // Обработка io_uring
            _ = try self.ring.submit_and_wait(1);
            while (self.ring.cq_ready() > 0) {
                const cqe = try self.ring.copy_cqe();
                try self.handleCqe(cqe);
            }

            // Проверка ответов от controller
            try self.checkControllerMessages();

            // Проверка и пополнение пулов
            try self.refillPools();
        }
    }

    fn shutdownImpl(ptr: *anyopaque) void {
        const self: *HttpWorker = @ptrCast(@alignCast(ptr));
        self.running.store(false, .monotonic);
    }

    fn refillPools(self: *HttpWorker) !void {
        for (self.block_pools) |pool| {
            if (pool.needsRefill()) {
                // Отправить allocate запрос в controller
                try self.requestBlockAllocation(pool.getSize());
            }
        }
    }

    // ... handleCqe, checkControllerMessages, etc.
};
```

### Mock: MockWorker
```zig
pub const MockWorker = struct {
    run_called: bool = false,
    shutdown_called: bool = false,

    pub fn init() MockWorker {
        return .{};
    }

    pub fn interface(self: *MockWorker) IWorker {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = runImpl,
                .shutdown = shutdownImpl,
            },
        };
    }

    fn runImpl(ptr: *anyopaque) !void {
        const self: *MockWorker = @ptrCast(@alignCast(ptr));
        self.run_called = true;
    }

    fn shutdownImpl(ptr: *anyopaque) void {
        const self: *MockWorker = @ptrCast(@alignCast(ptr));
        self.shutdown_called = true;
    }
};
```

---

## 6. Сборка системы (Plug-and-Play)

### Реальная система
```zig
pub fn createRealSystem(allocator: Allocator) !System {
    // 1. SPSC очереди
    var queue1_real = try RealSPSCQueue.init(allocator, 4096);
    var queue2_real = try RealSPSCQueue.init(allocator, 4096);
    const queue1 = queue1_real.interface();
    const queue2 = queue2_real.interface();

    // 2. Message handler
    var buddy_allocator = try BuddyAllocator.init(...);
    var buddy_handler = BuddyMessageHandler.init(&buddy_allocator, allocator);
    const message_handler = buddy_handler.interface();

    // 3. Block pools
    var pools_real: [8]SimpleBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_real, 0..) |*pool, i| {
        pool.* = try SimpleBlockPool.init(allocator, @intCast(i), 10);
        pools[i] = pool.interface();
    }

    // 4. Controller
    const worker_queues = [_]BatchController.WorkerQueues{
        .{ .from_worker = queue1, .to_worker = queue2 },
    };
    var controller = try BatchController.init(
        allocator,
        message_handler,
        &worker_queues,
        100_000, // 100µs
    );

    // 5. Worker
    var worker = try HttpWorker.init(
        0,
        allocator,
        10001,
        file_fd,
        pools,
        queue1,
        queue2,
    );

    return System{
        .controller = controller,
        .worker = worker,
        // ... cleanup
    };
}
```

### Тестовая система (с моками)
```zig
test "Controller with mock handler and queues" {
    var allocator = testing.allocator;

    // 1. Mock очереди
    var queue1_mock = MockSPSCQueue.init(allocator);
    defer queue1_mock.deinit();
    var queue2_mock = MockSPSCQueue.init(allocator);
    defer queue2_mock.deinit();

    const queue1 = queue1_mock.interface();
    const queue2 = queue2_mock.interface();

    // 2. Mock message handler
    var mock_handler = MockMessageHandler.init();
    mock_handler.allocate_response = .{
        .offset = 0,
        .size = 0,
        .block_num = 1,
    };
    const message_handler = mock_handler.interface();

    // 3. Controller (реальный, но с моками!)
    const worker_queues = [_]BatchController.WorkerQueues{
        .{ .from_worker = queue1, .to_worker = queue2 },
    };
    var controller = try BatchController.init(
        allocator,
        message_handler,
        &worker_queues,
        100_000,
    );
    defer controller.deinit();

    // Положить сообщение в очередь
    const msg = messages.AllocateRequest{ .worker_id = 0, .request_id = 1, .size = 0 };
    const msg_bytes = messages.serialize(msg);
    try testing.expect(queue1.push(msg_bytes));

    // Один цикл обработки (можно тестировать изолированно!)
    try controller.collectMessages();
    try controller.processBatches();
    try controller.sendResults();

    // Проверка
    try testing.expect(mock_handler.last_allocate != null);
    try testing.expectEqual(@as(u8, 0), mock_handler.last_allocate.?.size);
}

test "Worker with mock pools and queues" {
    var allocator = testing.allocator;

    // Mock пулы
    var pools_mock: [8]MockBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_mock, 0..) |*pool, i| {
        pool.* = MockBlockPool.init(allocator, @intCast(i));
        pools[i] = pool.interface();
    }
    defer for (&pools_mock) |*pool| pool.deinit();

    // Mock очереди
    var to_controller_mock = MockSPSCQueue.init(allocator);
    defer to_controller_mock.deinit();
    var from_controller_mock = MockSPSCQueue.init(allocator);
    defer from_controller_mock.deinit();

    // Worker (реальный, но с моками!)
    var worker = try HttpWorker.init(
        0,
        allocator,
        10001,
        -1, // mock file_fd
        pools,
        to_controller_mock.interface(),
        from_controller_mock.interface(),
    );
    defer worker.deinit();

    // Настроить mock pool: нужен refill
    pools_mock[0].needs_refill_response = true;

    // Вызвать refillPools (изолированно!)
    try worker.refillPools();

    // Проверить что запрос отправлен
    try testing.expect(to_controller_mock.items.items.len > 0);
}
```

---

## 7. Структура файлов

```
src/
├── interfaces.zig          # Все интерфейсы
│   ├── ISPSCQueue
│   ├── IMessageHandler
│   ├── IBlockPool
│   ├── IController
│   └── IWorker
│
├── spsc.zig                # SPSC Queue
│   ├── RealSPSCQueue
│   └── MockSPSCQueue
│
├── message_handler.zig     # Message handlers
│   ├── BuddyMessageHandler
│   └── MockMessageHandler
│
├── block_pool.zig          # Block pools
│   ├── SimpleBlockPool
│   └── MockBlockPool
│
├── controller.zig          # Controller
│   ├── BatchController
│   └── MockController
│
├── worker.zig              # Worker
│   ├── HttpWorker
│   └── MockWorker
│
├── messages.zig            # Message types
│   ├── MessageToController
│   ├── MessageFromController
│   └── serialize/deserialize
│
└── main.zig                # Assembly
    └── createRealSystem()

tests/
├── spsc_test.zig           # SPSC Queue tests
├── message_handler_test.zig
├── block_pool_test.zig
├── controller_test.zig     # С моками!
├── worker_test.zig         # С моками!
└── integration_test.zig    # Все реальные компоненты
```

---

## 8. Примеры изолированных тестов

### Тест Controller без Worker
```zig
test "Controller processes allocate batch" {
    // Подготовка
    var mock_handler = MockMessageHandler.init();
    mock_handler.allocate_response = .{ .offset = 1000, .size = 0, .block_num = 1 };

    var queue_from = MockSPSCQueue.init(testing.allocator);
    defer queue_from.deinit();
    var queue_to = MockSPSCQueue.init(testing.allocator);
    defer queue_to.deinit();

    const queues = [_]BatchController.WorkerQueues{
        .{ .from_worker = queue_from.interface(), .to_worker = queue_to.interface() },
    };

    var controller = try BatchController.init(
        testing.allocator,
        mock_handler.interface(),
        &queues,
        100_000,
    );
    defer controller.deinit();

    // Действие: отправить 3 allocate запроса
    for (0..3) |i| {
        const msg = messages.AllocateRequest{ .worker_id = 0, .request_id = i, .size = 0 };
        _ = queue_from.interface().push(messages.serialize(msg));
    }

    // Один цикл обработки
    try controller.collectMessages();
    try controller.processBatches();

    // Проверка: handler вызван 3 раза
    try testing.expectEqual(@as(usize, 3), controller.allocate_requests.items.len);
}
```

### Тест Worker без Controller
```zig
test "Worker requests refill when pool is low" {
    // Подготовка: mock pool с низким уровнем блоков
    var pool = MockBlockPool.init(testing.allocator, 0);
    defer pool.deinit();
    pool.needs_refill_response = true;

    var to_controller = MockSPSCQueue.init(testing.allocator);
    defer to_controller.deinit();
    var from_controller = MockSPSCQueue.init(testing.allocator);
    defer from_controller.deinit();

    var pools = [_]IBlockPool{pool.interface()} ** 8;

    var worker = try HttpWorker.init(
        0,
        testing.allocator,
        10001,
        -1,
        pools,
        to_controller.interface(),
        from_controller.interface(),
    );
    defer worker.deinit();

    // Действие
    try worker.refillPools();

    // Проверка: запрос отправлен
    try testing.expect(to_controller.items.items.len > 0);

    // Десериализовать и проверить тип
    var buffer: [1024]u8 = undefined;
    const len = to_controller.interface().pop(&buffer).?;
    const msg = messages.deserialize(buffer[0..len]);
    try testing.expect(msg == .allocate_block);
}
```

---

## Ключевые преимущества архитектуры

1. ✅ **Изолированное тестирование**: каждый компонент тестируется отдельно с моками
2. ✅ **Простая сборка**: система собирается как конструктор
3. ✅ **Гибкость**: легко заменить любой компонент (real ↔ mock)
4. ✅ **Отладка**: можно запустить controller без worker и наоборот
5. ✅ **Расширяемость**: легко добавить новые реализации интерфейсов

---

**Версия:** 1.0
**Дата:** 2025-10-16
