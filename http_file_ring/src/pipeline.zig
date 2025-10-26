const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("uring.zig").Ring;
const FileStorage = @import("file.zig").FileStorage;
const interfaces = @import("interfaces.zig");
const WorkerServiceInterface = interfaces.WorkerServiceInterface;
const BlockInfo = interfaces.BlockInfo;

/// Колбек для завершения операций
pub const CompletionCallback = *const fn (ctx: *anyopaque, result: PipelineResult) void;

pub const PipelineResult = union(enum) {
    success_write: struct {
        hash: [32]u8,
        block_info: BlockInfo,
    },
    success_read: struct {
        data_ready: bool, // данные готовы в pipe для отправки
    },
    error_occurred: struct {
        message: []const u8,
    },
};

pub const DataPipeline = struct {
    allocator: std.mem.Allocator,
    ring: *Ring,
    file_storage: *FileStorage,
    service: WorkerServiceInterface,
    hash_socket: posix.fd_t,

    pub fn init(
        allocator: std.mem.Allocator,
        ring: *Ring,
        file_storage: *FileStorage,
        service: WorkerServiceInterface,
        hash_socket: posix.fd_t,
    ) DataPipeline {
        return DataPipeline{
            .allocator = allocator,
            .ring = ring,
            .file_storage = file_storage,
            .service = service,
            .hash_socket = hash_socket,
        };
    }

    /// PUT: записать данные из socket_fd в storage
    pub fn writePipeline(
        self: *DataPipeline,
        socket_fd: i32,
        content_length: usize,
        body_in_buffer: []const u8,
        callback_ctx: *anyopaque,
        callback: CompletionCallback,
    ) !void {
        // Получаем блок от сервиса
        const block_info = self.service.onBlockInputRequest(0);
        const offset = block_info.block_num * 4096;

        // Создаём pipes
        const pipes1 = try posix.pipe();
        const pipes2 = try posix.pipe();

        // Записываем buffered данные в pipe если есть
        if (body_in_buffer.len > 0) {
            const written = try posix.write(pipes1[1], body_in_buffer);
            if (written != body_in_buffer.len) {
                return error.PartialWrite;
            }
        }

        const remaining_bytes = content_length - body_in_buffer.len;

        // Создаём контекст операции
        const op_ctx = try self.allocator.create(WriteOpContext);
        op_ctx.* = .{
            .pipeline = self,
            .socket_fd = socket_fd,
            .block_info = block_info,
            .offset = offset,
            .content_length = content_length,
            .pipe1_read = pipes1[0],
            .pipe1_write = pipes1[1],
            .pipe2_read = pipes2[0],
            .pipe2_write = pipes2[1],
            .callback_ctx = callback_ctx,
            .callback = callback,
            .stage = if (remaining_bytes > 0) .splice_socket_to_pipe else .parallel_ops,
            .completed_ops = 0,
            .hash = undefined,
        };

        if (remaining_bytes > 0) {
            // Ещё данные в socket - splice их в pipe
            try self.ring.queueSplice(socket_fd, -1, pipes1[1], -1, @intCast(remaining_bytes), @intFromPtr(op_ctx));
            _ = try self.ring.submit();
        } else {
            // Все данные уже в pipe, стартуем параллельные операции
            posix.close(pipes1[1]);
            op_ctx.pipe1_write = -1;
            try self.startParallelOps(op_ctx);
        }
    }

    fn startParallelOps(self: *DataPipeline, op_ctx: *WriteOpContext) !void {
        // Запускаем 3 операции параллельно: tee, splice_to_file, splice_to_hash
        try self.ring.queueTee(op_ctx.pipe1_read, op_ctx.pipe2_write, @intCast(op_ctx.content_length), @intFromPtr(op_ctx) | 1); // |1 - флаг tee
        try self.file_storage.queueSplice(op_ctx.pipe1_read, op_ctx.offset, @intCast(op_ctx.content_length), @intFromPtr(op_ctx) | 2); // |2 - флаг file
        try self.ring.queueSplice(op_ctx.pipe2_read, -1, self.hash_socket, -1, @intCast(op_ctx.content_length), @intFromPtr(op_ctx) | 3); // |3 - флаг hash
        _ = try self.ring.submit();
    }

    /// GET: читать данные из storage в socket_fd
    pub fn readPipeline(
        self: *DataPipeline,
        socket_fd: i32,
        hash: [32]u8,
        callback_ctx: *anyopaque,
        callback: CompletionCallback,
    ) !void {
        // Получаем адрес блока
        const block_info = self.service.onBlockAddressRequest(hash);
        const offset = block_info.block_num * 4096;
        const block_size: usize = 4096;

        // Создаём pipe
        const pipes = try posix.pipe();

        // Создаём контекст операции
        const op_ctx = try self.allocator.create(ReadOpContext);
        op_ctx.* = .{
            .pipeline = self,
            .socket_fd = socket_fd,
            .block_info = block_info,
            .offset = offset,
            .block_size = block_size,
            .pipe_read = pipes[0],
            .pipe_write = pipes[1],
            .callback_ctx = callback_ctx,
            .callback = callback,
            .stage = .splice_file_to_pipe,
        };

        // Splice: file -> pipe
        try self.ring.queueSplice(self.file_storage.fd, @intCast(offset), pipes[1], -1, @intCast(block_size), @intFromPtr(op_ctx));
        _ = try self.ring.submit();
    }

    /// Обработчик completion events от io_uring
    pub fn handleCompletion(self: *DataPipeline, user_data: u64, res: i32) !void {
        const ptr = user_data & ~@as(u64, 0x7); // Убираем флаги
        const flags = user_data & 0x7;

        if (flags == 0) {
            // WriteOpContext: splice_socket_to_pipe
            const op_ctx: *WriteOpContext = @ptrFromInt(ptr);
            try self.handleWriteCompletion(op_ctx, res, .splice_socket_to_pipe);
        } else if (flags == 1) {
            // WriteOpContext: tee
            const op_ctx: *WriteOpContext = @ptrFromInt(ptr);
            try self.handleWriteCompletion(op_ctx, res, .tee);
        } else if (flags == 2) {
            // WriteOpContext: splice_to_file
            const op_ctx: *WriteOpContext = @ptrFromInt(ptr);
            try self.handleWriteCompletion(op_ctx, res, .splice_to_file);
        } else if (flags == 3) {
            // WriteOpContext: splice_to_hash
            const op_ctx: *WriteOpContext = @ptrFromInt(ptr);
            try self.handleWriteCompletion(op_ctx, res, .splice_to_hash);
        } else if (flags == 4) {
            // ReadOpContext: splice_file_to_pipe
            const op_ctx: *ReadOpContext = @ptrFromInt(ptr);
            try self.handleReadCompletion(op_ctx, res, .splice_file_to_pipe);
        } else if (flags == 5) {
            // ReadOpContext: splice_pipe_to_socket
            const op_ctx: *ReadOpContext = @ptrFromInt(ptr);
            try self.handleReadCompletion(op_ctx, res, .splice_pipe_to_socket);
        }
    }

    fn handleWriteCompletion(self: *DataPipeline, op_ctx: *WriteOpContext, res: i32, stage: WriteStage) !void {
        if (res < 0) {
            self.cleanupWrite(op_ctx);
            op_ctx.callback(op_ctx.callback_ctx, .{ .error_occurred = .{ .message = "Write operation failed" } });
            self.allocator.destroy(op_ctx);
            return;
        }

        switch (stage) {
            .splice_socket_to_pipe => {
                // Закрываем write end pipe1
                posix.close(op_ctx.pipe1_write);
                op_ctx.pipe1_write = -1;
                op_ctx.stage = .parallel_ops;
                try self.startParallelOps(op_ctx);
            },
            .tee => {
                posix.close(op_ctx.pipe2_write);
                op_ctx.pipe2_write = -1;
                op_ctx.completed_ops += 1;
                if (op_ctx.completed_ops == 3) try self.finishWrite(op_ctx);
            },
            .splice_to_file => {
                posix.close(op_ctx.pipe1_read);
                op_ctx.pipe1_read = -1;
                op_ctx.completed_ops += 1;
                if (op_ctx.completed_ops == 3) try self.finishWrite(op_ctx);
            },
            .splice_to_hash => {
                posix.close(op_ctx.pipe2_read);
                op_ctx.pipe2_read = -1;

                // Читаем hash
                var hash_buffer: [32]u8 = undefined;
                const len = try posix.recv(self.hash_socket, &hash_buffer, 0);
                if (len == 32) {
                    op_ctx.hash = hash_buffer;
                    self.service.onHashForBlock(op_ctx.hash, op_ctx.block_info, op_ctx.content_length);
                }

                op_ctx.completed_ops += 1;
                if (op_ctx.completed_ops == 3) try self.finishWrite(op_ctx);
            },
            .parallel_ops => unreachable,
        }
    }

    fn finishWrite(self: *DataPipeline, op_ctx: *WriteOpContext) !void {
        self.cleanupWrite(op_ctx);
        op_ctx.callback(op_ctx.callback_ctx, .{
            .success_write = .{
                .hash = op_ctx.hash,
                .block_info = op_ctx.block_info,
            },
        });
        self.allocator.destroy(op_ctx);
    }

    fn cleanupWrite(_: *DataPipeline, op_ctx: *WriteOpContext) void {
        if (op_ctx.pipe1_read >= 0) posix.close(op_ctx.pipe1_read);
        if (op_ctx.pipe1_write >= 0) posix.close(op_ctx.pipe1_write);
        if (op_ctx.pipe2_read >= 0) posix.close(op_ctx.pipe2_read);
        if (op_ctx.pipe2_write >= 0) posix.close(op_ctx.pipe2_write);
    }

    fn handleReadCompletion(self: *DataPipeline, op_ctx: *ReadOpContext, res: i32, stage: ReadStage) !void {
        if (res < 0) {
            self.cleanupRead(op_ctx);
            op_ctx.callback(op_ctx.callback_ctx, .{ .error_occurred = .{ .message = "Read operation failed" } });
            self.allocator.destroy(op_ctx);
            return;
        }

        switch (stage) {
            .splice_file_to_pipe => {
                // Закрываем write end pipe
                posix.close(op_ctx.pipe_write);
                op_ctx.pipe_write = -1;
                op_ctx.stage = .splice_pipe_to_socket;

                // Splice: pipe -> socket
                try self.ring.queueSplice(op_ctx.pipe_read, -1, op_ctx.socket_fd, -1, @intCast(op_ctx.block_size), @intFromPtr(op_ctx) | 5);
                _ = try self.ring.submit();
            },
            .splice_pipe_to_socket => {
                self.cleanupRead(op_ctx);
                op_ctx.callback(op_ctx.callback_ctx, .{ .success_read = .{ .data_ready = true } });
                self.allocator.destroy(op_ctx);
            },
        }
    }

    fn cleanupRead(_: *DataPipeline, op_ctx: *ReadOpContext) void {
        if (op_ctx.pipe_read >= 0) posix.close(op_ctx.pipe_read);
        if (op_ctx.pipe_write >= 0) posix.close(op_ctx.pipe_write);
    }
};

const WriteStage = enum {
    splice_socket_to_pipe,
    parallel_ops,
    tee,
    splice_to_file,
    splice_to_hash,
};

const WriteOpContext = struct {
    pipeline: *DataPipeline,
    socket_fd: i32,
    block_info: BlockInfo,
    offset: u64,
    content_length: usize,
    pipe1_read: i32,
    pipe1_write: i32,
    pipe2_read: i32,
    pipe2_write: i32,
    callback_ctx: *anyopaque,
    callback: CompletionCallback,
    stage: WriteStage,
    completed_ops: u8,
    hash: [32]u8,
};

const ReadStage = enum {
    splice_file_to_pipe,
    splice_pipe_to_socket,
};

const ReadOpContext = struct {
    pipeline: *DataPipeline,
    socket_fd: i32,
    block_info: BlockInfo,
    offset: u64,
    block_size: usize,
    pipe_read: i32,
    pipe_write: i32,
    callback_ctx: *anyopaque,
    callback: CompletionCallback,
    stage: ReadStage,
};
