const std = @import("std");
const posix = std.posix;

const messages = @import("../messaging/messages.zig");
const interfaces = @import("../messaging/interfaces.zig");

const IMessageQueue = interfaces.IMessageQueue;
const IBlockPool = interfaces.IBlockPool;
const PoolBlockInfo = interfaces.BlockInfo;

const http_file_ring = @import("http_file_ring");
const Ring = http_file_ring.Ring;
const FileStorage = http_file_ring.FileStorage;
const HttpServer = http_file_ring.HttpServer;
const WorkerServiceInterface = http_file_ring.WorkerServiceInterface;
const HttpBlockInfo = http_file_ring.BlockInfo;

const ControllerResponse = union(enum) {
    allocate: messages.AllocateResult,
    occupy: messages.OccupyResult,
    release: messages.ReleaseResult,
    get_address: messages.GetAddressResult,
    err: messages.ErrorResult,
};

fn responseFromMessage(msg: messages.Message) ?struct { request_id: u64, res: ControllerResponse } {
    return switch (msg) {
        .allocate_result => |m| .{ .request_id = m.request_id, .res = .{ .allocate = m } },
        .occupy_result => |m| .{ .request_id = m.request_id, .res = .{ .occupy = m } },
        .release_result => |m| .{ .request_id = m.request_id, .res = .{ .release = m } },
        .get_address_result => |m| .{ .request_id = m.request_id, .res = .{ .get_address = m } },
        .error_result => |m| .{ .request_id = m.request_id, .res = .{ .err = m } },
        else => null,
    };
}

fn toHttpBlock(block: PoolBlockInfo) HttpBlockInfo {
    return .{ .block_num = block.block_num, .size_index = block.size };
}

fn sizeToBytes(size_index: u8) u64 {
    const idx = if (size_index > 7) 7 else size_index;
    return (@as(u64, 4096)) << @as(u6, @intCast(idx));
}

fn bytesToSizeIndex(size: u64) u8 {
    if (size <= 4096) return 0;
    const adjusted = if (size < 4096) 4096 else size;
    const bits = std.math.log2_int_ceil(u64, adjusted);
    const diff = bits - 12;
    return @intCast(if (diff > 7) 7 else diff);
}

const WorkerService = struct {
    worker: *HttpWorker,

    fn interface(self: *WorkerService) WorkerServiceInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .onBlockInputRequest = onBlockInputRequest,
                .onHashForBlock = onHashForBlock,
                .onFreeBlockRequest = onFreeBlockRequest,
                .onBlockAddressRequest = onBlockAddressRequest,
            },
        };
    }

    fn onBlockInputRequest(ptr: *anyopaque, size_index: u8) HttpBlockInfo {
        const self: *WorkerService = @ptrCast(@alignCast(ptr));
        return self.worker.acquireBlock(size_index);
    }

    fn onHashForBlock(ptr: *anyopaque, hash: [32]u8, block: HttpBlockInfo) void {
        const self: *WorkerService = @ptrCast(@alignCast(ptr));
        self.worker.finishPut(hash, block);
    }

    fn onFreeBlockRequest(ptr: *anyopaque, hash: [32]u8) HttpBlockInfo {
        const self: *WorkerService = @ptrCast(@alignCast(ptr));
        return self.worker.freeBlock(hash);
    }

    fn onBlockAddressRequest(ptr: *anyopaque, hash: [32]u8) http_file_ring.WorkerServiceError!HttpBlockInfo {
        const self: *WorkerService = @ptrCast(@alignCast(ptr));
        return self.worker.lookupBlock(hash);
    }
};

pub const HttpWorker = struct {
    id: u8,
    allocator: std.mem.Allocator,
    port: u16,
    block_pools: [8]IBlockPool,
    to_controller: IMessageQueue,
    from_controller: IMessageQueue,
    next_request_id: u64,
    pending: std.AutoHashMap(u64, ControllerResponse),
    running: std.atomic.Value(bool),
    sleep_ns: u64,

    ring: Ring,
    storage: FileStorage,
    service: WorkerService,
    server: HttpServer,

    pub fn init(
        self: *HttpWorker,
        id: u8,
        allocator: std.mem.Allocator,
        port: u16,
        file_fd: posix.fd_t,
        block_pools: [8]IBlockPool,
        to_controller: IMessageQueue,
        from_controller: IMessageQueue,
        _: i128,
        sleep_ns: u64,
    ) !void {
        self.id = id;
        self.allocator = allocator;
        self.port = port;
        self.block_pools = block_pools;
        self.to_controller = to_controller;
        self.from_controller = from_controller;
        self.next_request_id = 1;
        self.pending = std.AutoHashMap(u64, ControllerResponse).init(allocator);
        errdefer self.pending.deinit();
        self.running = std.atomic.Value(bool).init(true);
        self.sleep_ns = sleep_ns;

        self.ring = try Ring.init(256);
        errdefer self.ring.deinit();

        self.storage = .{ .ring = &self.ring, .fd = file_fd };
        self.service = .{ .worker = self };

        // HTTP server will be initialized later in startServer()
        self.server = undefined;
    }

    /// Start HTTP server (opens port) - call after prefilling pools
    pub fn startServer(self: *HttpWorker) !void {
        self.server = try HttpServer.init(self.allocator, &self.ring, self.port, self.service.interface(), &self.storage);
    }

    /// Prefill block pools with blocks from controller
    pub fn prefillPools(self: *HttpWorker, pool_targets: [8]usize) !void {
        std.debug.print("  Worker {d}: Prefilling block pools...\n", .{self.id});

        for (pool_targets, 0..) |target, size_idx| {
            if (target == 0) continue;

            var filled: usize = 0;
            while (filled < target) : (filled += 1) {
                // Request block from controller
                const req_id = self.nextId();
                self.send(.{ .allocate_block = .{
                    .worker_id = self.id,
                    .request_id = req_id,
                    .size = @intCast(size_idx),
                } });

                const block_info = switch (self.awaitControllerResponse(req_id)) {
                    .allocate => |res| PoolBlockInfo{ .size = res.size, .block_num = res.block_num },
                    .err => {
                        std.debug.print("  Worker {d}: Failed to prefill pool size {d}\n", .{ self.id, size_idx });
                        break;
                    },
                    else => unreachable,
                };

                // Add to pool
                if (size_idx < self.block_pools.len) {
                    self.block_pools[size_idx].release(block_info);
                }
            }

            std.debug.print("  Worker {d}: Pool size {d} filled with {d}/{d} blocks\n", .{ self.id, size_idx, filled, target });
        }
    }

    pub fn deinit(self: *HttpWorker) void {
        self.server.deinit();
        self.ring.deinit();
        self.pending.deinit();
    }

    pub fn run(self: *HttpWorker) !void {
        self.server.run() catch |err| {
            if (!self.running.load(.acquire) and err == error.AcceptFailed) return;
            return err;
        };
    }

    pub fn shutdown(self: *HttpWorker) void {
        self.running.store(false, .release);

        if (self.server.socket >= 0) {
            posix.shutdown(self.server.socket, .both) catch {};
            posix.close(self.server.socket);
            self.server.socket = -1;
        }
    }

    fn acquireBlock(self: *HttpWorker, size_index: u8) HttpBlockInfo {
        if (size_index < self.block_pools.len) {
            if (self.block_pools[size_index].acquire()) |block| return toHttpBlock(block);
        }

        const req_id = self.nextId();
        self.send(.{ .allocate_block = .{
            .worker_id = self.id,
            .request_id = req_id,
            .size = size_index,
        } });

        return switch (self.awaitControllerResponse(req_id)) {
            .allocate => |res| toHttpBlock(.{ .size = res.size, .block_num = res.block_num }),
            .err => @panic("controller allocate error"),
            else => unreachable,
        };
    }

    fn finishPut(self: *HttpWorker, hash: [32]u8, block: HttpBlockInfo) void {
        const req_id = self.nextId();
        self.send(.{ .occupy_block = .{
            .worker_id = self.id,
            .request_id = req_id,
            .hash = hash,
            .block_num = block.block_num,
            .size = block.size_index,
            .data_size = sizeToBytes(block.size_index),
        } });

        switch (self.awaitControllerResponse(req_id)) {
            .occupy => {},
            .err => @panic("controller occupy error"),
            else => unreachable,
        }
    }

    fn freeBlock(self: *HttpWorker, hash: [32]u8) HttpBlockInfo {
        const req_id = self.nextId();
        self.send(.{ .release_block = .{
            .worker_id = self.id,
            .request_id = req_id,
            .hash = hash,
        } });

        return switch (self.awaitControllerResponse(req_id)) {
            .release => .{ .block_num = 0, .size_index = 0 },
            .err => @panic("controller release error"),
            else => unreachable,
        };
    }

    fn lookupBlock(self: *HttpWorker, hash: [32]u8) http_file_ring.WorkerServiceError!HttpBlockInfo {
        const req_id = self.nextId();
        self.send(.{ .get_address = .{
            .worker_id = self.id,
            .request_id = req_id,
            .hash = hash,
        } });

        return switch (self.awaitControllerResponse(req_id)) {
            .get_address => |res| blk: {
                const size_index = bytesToSizeIndex(res.size);
                const block_size = sizeToBytes(size_index);
                const block_num = if (block_size == 0) res.offset else res.offset / block_size;
                break :blk .{ .block_num = block_num, .size_index = size_index };
            },
            .err => error.BlockNotFound,
            else => unreachable,
        };
    }

    fn send(self: *HttpWorker, msg: messages.Message) void {
        while (!self.to_controller.push(msg)) {
            if (!self.running.load(.acquire)) @panic("worker stopping");
            self.pause();
        }
    }

    fn awaitControllerResponse(self: *HttpWorker, request_id: u64) ControllerResponse {
        while (self.running.load(.acquire)) {
            if (self.pending.fetchRemove(request_id)) |entry| return entry.value;

            var msg: messages.Message = undefined;
            if (self.from_controller.pop(&msg)) {
                if (responseFromMessage(msg)) |hit| {
                    if (hit.request_id == request_id) return hit.res;
                    self.pending.put(hit.request_id, hit.res) catch {};
                }
            }

            self.pause();
        }

        @panic("worker stopped while waiting for controller");
    }

    fn nextId(self: *HttpWorker) u64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn pause(self: *const HttpWorker) void {
        if (self.sleep_ns > 0) {
            std.Thread.sleep(self.sleep_ns);
        } else {
            std.Thread.yield() catch {};
        }
    }
};
