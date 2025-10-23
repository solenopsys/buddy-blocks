const std = @import("std");

/// Тип операции для io_uring
pub const OpType = enum {
    accept,
    recv_header,
    pipeline, // общий контекст для всех операций pipeline
    read_block, // чтение блока для GET
    send_response, // отправка ответа
};

/// Какая операция завершилась
pub const PipelineOp = enum(u8) {
    splice_socket_to_pipe = 0,
    tee = 1,
    splice_to_file = 2,
    splice_to_hash = 3,
};

/// Состояние pipeline операций
pub const PipelineState = struct {
    // Дескрипторы pipe
    pipe1_read: i32,
    pipe1_write: i32,
    pipe2_read: i32,
    pipe2_write: i32,

    // Битовая маска завершенных операций (биты 1,2,3 для tee, file, hash)
    completed_mask: u8 = 0,

    // Ошибка если была
    has_error: bool = false,

    pub fn init(p1r: i32, p1w: i32, p2r: i32, p2w: i32) PipelineState {
        return .{
            .pipe1_read = p1r,
            .pipe1_write = p1w,
            .pipe2_read = p2r,
            .pipe2_write = p2w,
        };
    }

    pub fn markComplete(self: *PipelineState, op: PipelineOp) void {
        const shift: u3 = @intCast(@intFromEnum(op));
        self.completed_mask |= @as(u8, 1) << shift;
    }

    pub fn isComplete(self: *PipelineState) bool {
        // Проверяем что завершились tee (bit 1), file (bit 2), hash (bit 3)
        return (self.completed_mask & 0b1110) == 0b1110;
    }

    pub fn cleanup(self: *PipelineState) void {
        const posix = std.posix;
        if (self.pipe1_read >= 0) posix.close(self.pipe1_read);
        if (self.pipe1_write >= 0) posix.close(self.pipe1_write);
        if (self.pipe2_read >= 0) posix.close(self.pipe2_read);
        if (self.pipe2_write >= 0) posix.close(self.pipe2_write);
    }
};

/// Контекст операции для user_data
pub const OpContext = struct {
    op_type: OpType,
    conn_fd: i32,
    block_info: BlockInfo,
    content_length: u64,
    hash: [32]u8,
    buffer: ?[]u8 = null,

    // Для accept операции
    addr: std.posix.sockaddr = undefined,
    addrlen: std.posix.socklen_t = undefined,

    // Для pipeline операций
    pipeline_state: ?*PipelineState = null,
    pipeline_op: PipelineOp = .splice_socket_to_pipe,
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
