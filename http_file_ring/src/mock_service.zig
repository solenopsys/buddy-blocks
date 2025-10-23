const std = @import("std");
const interfaces = @import("interfaces.zig");
const WorkerServiceInterface = interfaces.WorkerServiceInterface;
const BlockInfo = interfaces.BlockInfo;

pub const MockWorkerService = struct {
    next_block: u64 = 0,

    pub fn init() MockWorkerService {
        return MockWorkerService{};
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
        const block_num = self.next_block;
        self.next_block += 1;

        std.debug.print("MockService: onBlockInputRequest(size_index={d}) -> block_num={d}\n", .{ size_index, block_num });

        return BlockInfo{
            .block_num = block_num,
            .size_index = 0, // всегда 4кб
        };
    }

    fn onHashForBlock(ptr: *anyopaque, hash: [32]u8, block_info: BlockInfo) void {
        _ = ptr;
        std.debug.print("MockService: onHashForBlock(block_num={d}, size_index={d}, hash=", .{ block_info.block_num, block_info.size_index });
        for (hash[0..8]) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...)\n", .{});
    }

    fn onFreeBlockRequest(ptr: *anyopaque, hash: [32]u8) BlockInfo {
        _ = ptr;
        std.debug.print("MockService: onFreeBlockRequest(hash=", .{});
        for (hash[0..8]) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...)\n", .{});

        return BlockInfo{
            .block_num = 0,
            .size_index = 0,
        };
    }

    fn onBlockAddressRequest(ptr: *anyopaque, hash: [32]u8) BlockInfo {
        _ = ptr;
        std.debug.print("MockService: onBlockAddressRequest(hash=", .{});
        for (hash[0..8]) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...)\n", .{});

        return BlockInfo{
            .block_num = 0,
            .size_index = 0,
        };
    }
};
