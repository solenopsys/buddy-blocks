const std = @import("std");

/// Тип операции для io_uring
pub const OpType = enum {
    accept,
    recv_header,
    splice_to_pipe,
    tee_pipe,
    splice_to_file,
    splice_to_hash,
    read_hash,
};

/// Контекст операции для user_data
pub const OpContext = struct {
    op_type: OpType,
    conn_fd: i32,
    block_info: BlockInfo,
    content_length: u64,
    hash: [32]u8,
    buffer: ?[]u8 = null,
};

/// Результат запроса блока
pub const BlockInfo = struct {
    block_num: u64,
    size_index: u8 = 0,
};

/// Интерфейс сервиса управления блоками
pub const WorkerServiceInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onBlockInputRequest: *const fn (ptr: *anyopaque, size_index: u8) BlockInfo,
        onHashForBlock: *const fn (ptr: *anyopaque, hash: [32]u8, block_info: BlockInfo) void,
        onFreeBlockRequest: *const fn (ptr: *anyopaque, hash: [32]u8) BlockInfo,
        onBlockAddressRequest: *const fn (ptr: *anyopaque, hash: [32]u8) BlockInfo,
    };

    pub fn onBlockInputRequest(self: WorkerServiceInterface, size_index: u8) BlockInfo {
        return self.vtable.onBlockInputRequest(self.ptr, size_index);
    }

    pub fn onHashForBlock(self: WorkerServiceInterface, hash: [32]u8, block_info: BlockInfo) void {
        self.vtable.onHashForBlock(self.ptr, hash, block_info);
    }

    pub fn onFreeBlockRequest(self: WorkerServiceInterface, hash: [32]u8) BlockInfo {
        return self.vtable.onFreeBlockRequest(self.ptr, hash);
    }

    pub fn onBlockAddressRequest(self: WorkerServiceInterface, hash: [32]u8) BlockInfo {
        return self.vtable.onBlockAddressRequest(self.ptr, hash);
    }
};
