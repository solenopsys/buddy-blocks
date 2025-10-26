const std = @import("std");
const interfaces = @import("interfaces.zig");
const WorkerServiceInterface = interfaces.WorkerServiceInterface;
const BlockInfo = interfaces.BlockInfo;
const WorkerServiceError = interfaces.WorkerServiceError;

pub const MockWorkerService = struct {
    allocator: std.mem.Allocator,
    next_block_num: std.atomic.Value(u64),
    hash_map: std.StringHashMap(BlockInfo),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) MockWorkerService {
        return MockWorkerService{
            .allocator = allocator,
            .next_block_num = std.atomic.Value(u64).init(0),
            .hash_map = std.StringHashMap(BlockInfo).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *MockWorkerService) void {
        var it = self.hash_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
        }
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
                .onBlockExistsRequest = onBlockExistsRequest,
                .onLockPatchRequest = onLockPatchRequest,
            },
        };
    }

    fn onBlockInputRequest(ptr: *anyopaque, size_index: u8) BlockInfo {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        const block_num = self.next_block_num.fetchAdd(1, .monotonic);

        return BlockInfo{
            .block_num = block_num,
            .size_index = size_index,
            .data_size = 0,
        };
    }

    fn onHashForBlock(ptr: *anyopaque, hash: [32]u8, block_info: BlockInfo, data_size: u64) void {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        // Сохраняем маппинг hash -> block_info
        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf = hashToHex(hash);

        var stored_info = block_info;
        stored_info.data_size = data_size;

        // Аллоцируем память для ключа (иначе key_buf уничтожится при выходе)
        const key = self.allocator.alloc(u8, 64) catch |err| {
            std.debug.print("MockWorkerService: Failed to allocate key: {}\n", .{err});
            return;
        };
        @memcpy(key, &key_buf);

        self.hash_map.put(key, stored_info) catch |err| {
            std.debug.print("MockWorkerService: Failed to store hash mapping: {}\n", .{err});
            self.allocator.free(key);
            return;
        };

        std.debug.print(
            "Stored hash {s} -> block_num {d}, size_index {d}, data_size {d}, total mapped {d}\n",
            .{ key, stored_info.block_num, stored_info.size_index, stored_info.data_size, self.hash_map.count() },
        );
    }

    fn onFreeBlockRequest(ptr: *anyopaque, hash: [32]u8) BlockInfo {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf = hashToHex(hash);
        const key = key_buf[0..];

        // Удаляем из мапы
        if (self.hash_map.fetchRemove(key)) |kv| {
            const info = kv.value;
            self.allocator.free(@constCast(kv.key));
            return info;
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

        var key_buf = hashToHex(hash);
        const key = key_buf[0..];

        // Ищем в мапе
        if (self.hash_map.get(key)) |block_info| {
            std.debug.print("Lookup hit for hash {s} -> block_num {d}\n", .{ key, block_info.block_num });
            return block_info;
        }

        std.debug.print("Lookup miss for hash {s} (mapped {d})\n", .{ key, self.hash_map.count() });

        return error.BlockNotFound;
    }

    fn onBlockExistsRequest(ptr: *anyopaque, hash: [32]u8) !bool {
        const self: *MockWorkerService = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf = hashToHex(hash);
        const key = key_buf[0..];
        return self.hash_map.get(key) != null;
    }

    fn onLockPatchRequest(ptr: *anyopaque, _: [32]u8, _: []const u8, _: []const u8) !void {
        _ = ptr;
    }

    fn hashToHex(hash: [32]u8) [64]u8 {
        var hex_buf: [64]u8 = undefined;
        for (hash, 0..) |byte, i| {
            _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
        }
        return hex_buf;
    }
};
