const std = @import("std");

/// Ошибки сервиса worker
pub const WorkerServiceError = error{
    BlockNotFound,
};

/// Тип операции для io_uring
pub const OpType = enum {
    accept,
    recv_header,
    pipeline, // общий контекст для всех операций pipeline
    read_block, // чтение блока для GET
    send_response, // отправка ответа
    poll_socket, // ожидание данных на socket (POLL_ADD)
};

/// Какая операция завершилась
pub const PipelineOp = enum(u8) {
    splice_socket_to_pipe = 0,
    tee = 1,
    splice_to_file = 2,
    splice_to_hash = 3,
};

/// Состояние pipeline операций (chunked processing)
pub const PipelineState = struct {
    // Дескрипторы pipe
    pipe1_read: i32,
    pipe1_write: i32,
    pipe2_read: i32,
    pipe2_write: i32,

    // Hash socket для этого запроса
    hash_socket: i32,

    // HTTP контекст (для отправки ответа клиенту)
    conn_fd: i32 = -1,
    block_info: BlockInfo = .{ .block_num = 0 },

    // Параметры для chunked processing
    file_offset: u64 = 0,
    total_length: usize = 0,

    // Прогресс по операциям (сколько байт каждая операция обработала)
    tee_completed: usize = 0,
    file_completed: usize = 0,
    hash_completed: usize = 0,

    // Offset следующего chunk'а для которого можно запустить TEE
    // (запускаем только после того как оба splice предыдущего chunk'а завершились)
    next_tee_offset: usize = 0,

    // Флаг что splice в hash уже запущен (чтобы не запускать дважды)
    hash_splice_started: bool = false,

    // Буфер для полученного хеша
    hash: [32]u8 = undefined,
    hash_ready: bool = false,

    // Ошибка если была
    has_error: bool = false,

    pub fn init(p1r: i32, p1w: i32, p2r: i32, p2w: i32, hash_sock: i32) PipelineState {
        return .{
            .pipe1_read = p1r,
            .pipe1_write = p1w,
            .pipe2_read = p2r,
            .pipe2_write = p2w,
            .hash_socket = hash_sock,
        };
    }

    pub fn isComplete(self: *PipelineState) bool {
        // Все три операции должны обработать все данные
        return self.tee_completed == self.total_length and
               self.file_completed == self.total_length and
               self.hash_completed == self.total_length;
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
    bytes_transferred: u64 = 0,

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
    data_size: u64 = 0,

    pub fn capacityBytes(self: BlockInfo) usize {
        const capped_index: u8 = if (self.size_index > 7) 7 else self.size_index;
        const shift: u6 = @intCast(capped_index);
        const capacity: u64 = (@as(u64, 4096)) << shift;
        return @intCast(capacity);
    }
};

/// Интерфейс сервиса управления блоками
pub const WorkerServiceInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onBlockInputRequest: *const fn (ptr: *anyopaque, size_index: u8) BlockInfo,
        onHashForBlock: *const fn (ptr: *anyopaque, hash: [32]u8, block_info: BlockInfo, data_size: u64) void,
        onFreeBlockRequest: *const fn (ptr: *anyopaque, hash: [32]u8) BlockInfo,
        onBlockAddressRequest: *const fn (ptr: *anyopaque, hash: [32]u8) WorkerServiceError!BlockInfo,
        onBlockExistsRequest: *const fn (ptr: *anyopaque, hash: [32]u8) anyerror!bool,
        onLockPatchRequest: *const fn (ptr: *anyopaque, hash: [32]u8, resource_id: []const u8, body: []const u8) anyerror!void,
    };

    pub fn onBlockInputRequest(self: WorkerServiceInterface, size_index: u8) BlockInfo {
        return self.vtable.onBlockInputRequest(self.ptr, size_index);
    }

    pub fn onHashForBlock(self: WorkerServiceInterface, hash: [32]u8, block_info: BlockInfo, data_size: u64) void {
        self.vtable.onHashForBlock(self.ptr, hash, block_info, data_size);
    }

    pub fn onFreeBlockRequest(self: WorkerServiceInterface, hash: [32]u8) BlockInfo {
        return self.vtable.onFreeBlockRequest(self.ptr, hash);
    }

    pub fn onBlockAddressRequest(self: WorkerServiceInterface, hash: [32]u8) WorkerServiceError!BlockInfo {
        return self.vtable.onBlockAddressRequest(self.ptr, hash);
    }

    pub fn onBlockExistsRequest(self: WorkerServiceInterface, hash: [32]u8) anyerror!bool {
        return self.vtable.onBlockExistsRequest(self.ptr, hash);
    }

    pub fn onLockPatchRequest(self: WorkerServiceInterface, hash: [32]u8, resource_id: []const u8, body: []const u8) anyerror!void {
        return self.vtable.onLockPatchRequest(self.ptr, hash, resource_id, body);
    }
};
