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
        _ = size_index;
        const block_num = self.next_block;
        self.next_block += 1;

        return BlockInfo{
            .block_num = block_num,
            .size_index = 0, // всегда 4кб
        };
    }

    fn onHashForBlock(ptr: *anyopaque, hash: [32]u8, block_info: BlockInfo) void {
        _ = ptr;
        _ = hash;
        _ = block_info;
    }

    fn onFreeBlockRequest(ptr: *anyopaque, hash: [32]u8) BlockInfo {
        _ = ptr;
        _ = hash;

        return BlockInfo{
            .block_num = 0,
            .size_index = 0,
        };
    }

    fn onBlockAddressRequest(ptr: *anyopaque, hash: [32]u8) BlockInfo {
        _ = ptr;
        _ = hash;

        return BlockInfo{
            .block_num = 0,
            .size_index = 0,
        };
    }
};
