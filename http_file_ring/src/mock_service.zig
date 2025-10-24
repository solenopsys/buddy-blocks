const std = @import("std");
const interfaces = @import("interfaces.zig");
const WorkerServiceInterface = interfaces.WorkerServiceInterface;
const BlockInfo = interfaces.BlockInfo;
const WorkerServiceError = interfaces.WorkerServiceError;

pub const MockWorkerService = struct {
    allocator: std.mem.Allocator,
    next_block_num: std.atomic.Value(u64),
    hash_map: std.AutoHashMap([32]u8, BlockInfo),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) MockWorkerService {
        return MockWorkerService{
            .allocator = allocator,
            .next_block_num = std.atomic.Value(u64).init(0),
            .hash_map = std.AutoHashMap([32]u8, BlockInfo).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *MockWorkerService) void {
        self.hash_map.deinit();
    }

    pub fn interface(self: *MockWorkerService) WorkerServiceInterface {
        return WorkerServiceInterface{
            .ptr = self,
            .vtable = &.{
                .onBlockInputRequest = onBlockInputRequest,
                .onHashForBlock = onHashForBlock,
                .onFreeBlockRequest = onFreeBlockRequest,
                .onBlockAddressRequest = onBlockAddressRequest,
            },
        };
    }

    fn onBlockInputRequest(ptr: *anyopaque, size_index: u8) BlockInfo {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        // Атомарно инкрементируем block_num для уникального offset
        const block_num = self.next_block_num.fetchAdd(1, .monotonic);

        return BlockInfo{
            .block_num = block_num,
            .size_index = size_index,
        };
    }

    fn onHashForBlock(ptr: *anyopaque, hash: [32]u8, block_info: BlockInfo) void {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        // Сохраняем маппинг hash -> block_info
        self.mutex.lock();
        defer self.mutex.unlock();

        self.hash_map.put(hash, block_info) catch |err| {
            std.debug.print("MockWorkerService: Failed to store hash mapping: {}\n", .{err});
        };
    }

    fn onFreeBlockRequest(ptr: *anyopaque, hash: [32]u8) BlockInfo {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        // Удаляем из мапы
        if (self.hash_map.fetchRemove(hash)) |kv| {
            return kv.value;
        }

        return BlockInfo{
            .block_num = 0,
            .size_index = 0,
        };
    }

    fn onBlockAddressRequest(ptr: *anyopaque, hash: [32]u8) WorkerServiceError!BlockInfo {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        // Ищем в мапе
        if (self.hash_map.get(hash)) |block_info| {
            return block_info;
        }

        return error.BlockNotFound;
    }
};
