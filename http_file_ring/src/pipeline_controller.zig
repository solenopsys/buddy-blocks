const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Ring = @import("uring.zig").Ring;
const interfaces = @import("interfaces.zig");
const FileStorage = @import("file.zig").FileStorage;

const CHUNK_SIZE: usize = 65536; // 64KB chunks

/// Pipeline контроллер с ПРАВИЛЬНОЙ chunked логикой:
/// 1. TEE копирует chunk из pipe1 в pipe2
/// 2. После завершения TEE запускаем SPLICE (pipe1→file) и SPLICE (pipe2→hash) параллельно
/// 3. Когда оба SPLICE завершены, переходим к следующему chunk
pub const PipelineController = struct {
    allocator: std.mem.Allocator,
    ring: *Ring,
    file_storage: *FileStorage,

    pub fn init(allocator: std.mem.Allocator, ring: *Ring, file_storage: *FileStorage) PipelineController {
        return .{
            .allocator = allocator,
            .ring = ring,
            .file_storage = file_storage,
        };
    }

    pub fn startPipeline(
        self: *PipelineController,
        pipe1_read: i32,
        pipe2_read: i32,
        pipe2_write: i32,
        hash_socket: i32,
        file_offset: u64,
        data_length: usize,
        conn_fd: i32,
        block_info: interfaces.BlockInfo,
    ) !*interfaces.PipelineState {
        const state = try self.allocator.create(interfaces.PipelineState);
        state.* = interfaces.PipelineState.init(pipe1_read, -1, pipe2_read, pipe2_write, hash_socket);
        state.file_offset = file_offset;
        state.total_length = data_length;
        state.conn_fd = conn_fd;
        state.block_info = block_info;

        // Запускаем первый TEE chunk
        const first_chunk_size = @min(CHUNK_SIZE, data_length);
        const tee_ctx = try self.allocator.create(interfaces.OpContext);
        tee_ctx.* = .{
            .op_type = .pipeline,
            .conn_fd = -1,
            .block_info = .{ .block_num = 0 }, // используем для offset
            .content_length = first_chunk_size,
            .hash = undefined,
            .buffer = null,
            .pipeline_state = state,
            .pipeline_op = .tee,
            .bytes_transferred = 0,
        };

        // Следующий TEE chunk можно запускать только после завершения splice первого chunk'а
        state.next_tee_offset = first_chunk_size;

        try self.ring.queueTee(pipe1_read, pipe2_write, @intCast(first_chunk_size), @intFromPtr(tee_ctx));
        _ = try self.ring.submit();

        return state;
    }

    pub fn handlePipelineCompletion(
        self: *PipelineController,
        ctx: *interfaces.OpContext,
        res: i32,
    ) !PipelineResult {
        const state = ctx.pipeline_state orelse return error.NoPipelineState;

        if (res < 0) {
            std.debug.print("Pipeline operation {s} failed: {d}\n", .{ @tagName(ctx.pipeline_op), res });
            state.has_error = true;
            return .{ .status = .failed, .should_cleanup = true };
        }

        switch (ctx.pipeline_op) {
            .splice_socket_to_pipe => return try self.handleSpliceSocketToPipe(ctx, state, res),
            .tee => return try self.handleTee(ctx, state, res),
            .splice_to_file => return try self.handleSpliceToFile(ctx, state, res),
            .splice_to_hash => return try self.handleSpliceToHash(ctx, state, res),
        }
    }

    fn handleSpliceSocketToPipe(
        self: *PipelineController,
        ctx: *interfaces.OpContext,
        state: *interfaces.PipelineState,
        res: i32,
    ) !PipelineResult {
        // При работе через прокси splice может вернуть 0 байт если данные еще в пути
        if (res == 0 and ctx.bytes_transferred < ctx.content_length) {
            std.debug.print("splice(socket->pipe) returned 0 bytes, need POLL. Progress: {d}/{d}\n", .{ ctx.bytes_transferred, ctx.content_length });
            // Возвращаем статус что нужен POLL
            return .{ .status = .need_poll, .should_cleanup = false };
        }

        ctx.bytes_transferred += @intCast(res);

        // Retry если не все получено
        if (ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueSplice(state.conn_fd, -1, state.pipe1_write, -1, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        // Все данные из socket получены!
        // Закрываем write-конец pipe1
        if (state.pipe1_write >= 0) {
            posix.close(state.pipe1_write);
            state.pipe1_write = -1;
        }

        // Запускаем первый TEE chunk
        const first_chunk_size = @min(CHUNK_SIZE, state.total_length);
        const tee_ctx = try self.allocator.create(interfaces.OpContext);
        tee_ctx.* = .{
            .op_type = .pipeline,
            .conn_fd = -1,
            .block_info = .{ .block_num = 0 }, // chunk offset, НЕ block_num!
            .content_length = first_chunk_size,
            .hash = undefined,
            .buffer = null,
            .pipeline_state = state,
            .pipeline_op = .tee,
            .bytes_transferred = 0,
        };

        state.next_tee_offset = first_chunk_size;

        try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(first_chunk_size), @intFromPtr(tee_ctx));
        _ = try self.ring.submit();

        return .{ .status = .in_progress, .should_cleanup = true };
    }

    /// Проверяет и запускает следующий TEE chunk если splice_to_file предыдущего chunk'а завершен
    fn tryStartNextTeeChunk(
        self: *PipelineController,
        state: *interfaces.PipelineState,
    ) !void {
        // Проверяем: splice в файл завершен до next_tee_offset?
        if (state.file_completed >= state.next_tee_offset and state.next_tee_offset < state.total_length) {
            const remaining = state.total_length - state.next_tee_offset;
            const next_chunk_size = @min(CHUNK_SIZE, remaining);
            const next_offset = state.next_tee_offset;

            const next_tee_ctx = try self.allocator.create(interfaces.OpContext);
            next_tee_ctx.* = .{
                .op_type = .pipeline,
                .conn_fd = -1,
                .block_info = .{ .block_num = next_offset },
                .content_length = next_chunk_size,
                .hash = undefined,
                .buffer = null,
                .pipeline_state = state,
                .pipeline_op = .tee,
                .bytes_transferred = 0,
            };

            state.next_tee_offset += next_chunk_size;

            try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(next_chunk_size), @intFromPtr(next_tee_ctx));
            _ = try self.ring.submit();
        }
    }

    /// Запускает splice из pipe2 в hash socket когда все TEE завершены
    fn tryStartHashSplice(
        self: *PipelineController,
        state: *interfaces.PipelineState,
    ) !void {
        // Запускаем splice в hash ОДИН РАЗ когда все TEE завершены и еще не запущено
        if (state.tee_completed == state.total_length and !state.hash_splice_started) {
            state.hash_splice_started = true;

            const hash_ctx = try self.allocator.create(interfaces.OpContext);
            hash_ctx.* = .{
                .op_type = .pipeline,
                .conn_fd = -1,
                .block_info = .{ .block_num = 0 },
                .content_length = state.total_length,
                .hash = undefined,
                .buffer = null,
                .pipeline_state = state,
                .pipeline_op = .splice_to_hash,
                .bytes_transferred = 0,
            };

            try self.ring.queueSplice(state.pipe2_read, -1, state.hash_socket, -1, @intCast(state.total_length), @intFromPtr(hash_ctx));
            _ = try self.ring.submit();
        }
    }

    fn handleTee(
        self: *PipelineController,
        ctx: *interfaces.OpContext,
        state: *interfaces.PipelineState,
        res: i32,
    ) !PipelineResult {
        const chunk_offset = ctx.block_info.block_num;

        ctx.bytes_transferred += @intCast(res);

        // Retry если не все скопировано
        if (res == 0 and ctx.bytes_transferred < ctx.content_length) {
            std.debug.print("WARN: tee returned 0, retrying\n", .{});
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        if (ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        // TEE chunk завершён! Теперь запускаем splice для этого chunk'а
        state.tee_completed += ctx.bytes_transferred;
        const chunk_size = ctx.bytes_transferred;

        // SPLICE в файл для этого chunk'а
        const file_ctx = try self.allocator.create(interfaces.OpContext);
        file_ctx.* = .{
            .op_type = .pipeline,
            .conn_fd = -1,
            .block_info = .{ .block_num = chunk_offset },
            .content_length = chunk_size,
            .hash = undefined,
            .buffer = null,
            .pipeline_state = state,
            .pipeline_op = .splice_to_file,
            .bytes_transferred = 0,
        };
        const file_off = state.file_offset + chunk_offset;
        try self.file_storage.queueSplice(state.pipe1_read, file_off, @intCast(chunk_size), @intFromPtr(file_ctx));

        // НЕ делаем chunked splice в hash!
        // Вместо этого, все данные копятся в pipe2, и splice в hash будет ОДИН РАЗ в конце

        _ = try self.ring.submit();

        // Проверяем: может все TEE завершены и можно запустить hash splice?
        try self.tryStartHashSplice(state);

        return .{ .status = .in_progress, .should_cleanup = true };
    }

    fn handleSpliceToFile(
        self: *PipelineController,
        ctx: *interfaces.OpContext,
        state: *interfaces.PipelineState,
        res: i32,
    ) !PipelineResult {
        const chunk_offset = ctx.block_info.block_num;

        ctx.bytes_transferred += @intCast(res);

        // Retry
        if (res == 0 and ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            const file_off = state.file_offset + chunk_offset + ctx.bytes_transferred;
            try self.file_storage.queueSplice(state.pipe1_read, file_off, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        if (ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            const file_off = state.file_offset + chunk_offset + ctx.bytes_transferred;
            try self.file_storage.queueSplice(state.pipe1_read, file_off, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        // Chunk завершён
        state.file_completed += ctx.bytes_transferred;

        // Проверяем: может быть можно запустить следующий TEE?
        try self.tryStartNextTeeChunk(state);

        // Проверяем: может все TEE завершены и можно запустить hash splice?
        try self.tryStartHashSplice(state);

        const is_complete = state.isComplete();
        return .{
            .status = if (is_complete) .completed else .in_progress,
            .should_cleanup = true,
            .hash_ready = is_complete and state.hash_ready,
        };
    }

    fn handleSpliceToHash(
        self: *PipelineController,
        ctx: *interfaces.OpContext,
        state: *interfaces.PipelineState,
        res: i32,
    ) !PipelineResult {
        ctx.bytes_transferred += @intCast(res);

        // Retry если не все отправлено
        if (res == 0 and ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueSplice(state.pipe2_read, -1, state.hash_socket, -1, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        if (ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueSplice(state.pipe2_read, -1, state.hash_socket, -1, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return .{ .status = .in_progress, .should_cleanup = false };
        }

        // Hash splice завершён полностью!
        state.hash_completed = ctx.bytes_transferred;

        // Читаем хеш
        if (!state.hash_ready) {
            const hash_buffer = try self.allocator.alloc(u8, 32);
            defer self.allocator.free(hash_buffer);

            const len = try posix.recv(state.hash_socket, hash_buffer, 0);
            if (len == 32) {
                @memcpy(&state.hash, hash_buffer[0..32]);
                state.hash_ready = true;
            } else {
                std.debug.print("WARN: read_hash failed: expected 32 bytes, got {d}\n", .{len});
            }
        }

        const is_complete = state.isComplete();
        return .{
            .status = if (is_complete) .completed else .in_progress,
            .should_cleanup = true,
            .hash_ready = is_complete and state.hash_ready,
            .hash = state.hash,
            .send_response = is_complete and state.hash_ready,
        };
    }

    /// Обработка результата POLL операции (для медленных прокси)
    pub fn handlePollSocket(
        self: *PipelineController,
        ctx: *interfaces.OpContext,
        res: i32,
    ) !PipelineResult {
        const state = ctx.pipeline_state orelse return error.NoPipelineState;

        if (res < 0) {
            std.debug.print("Poll failed: {d}\n", .{res});
            state.has_error = true;
            return .{ .status = .failed, .should_cleanup = true };
        }

        // POLL завершился успешно - данные доступны на socket
        // Возвращаемся к splice операции
        const remaining = ctx.content_length - ctx.bytes_transferred;
        try self.ring.queueSplice(state.conn_fd, -1, state.pipe1_write, -1, @intCast(remaining), @intFromPtr(ctx));
        _ = try self.ring.submit();

        // Возвращаем статус in_progress чтобы продолжить
        return .{ .status = .in_progress, .should_cleanup = false };
    }

    /// Создает начальную операцию splice socket->pipe для PUT запроса
    pub fn startSocketSplice(
        self: *PipelineController,
        state: *interfaces.PipelineState,
        remaining_bytes: usize,
        bytes_already_written: usize,
    ) !*interfaces.OpContext {
        const splice_ctx = try self.allocator.create(interfaces.OpContext);
        splice_ctx.* = .{
            .op_type = .pipeline,
            .conn_fd = state.conn_fd,
            .block_info = state.block_info,
            .content_length = state.total_length,
            .hash = undefined,
            .buffer = null,
            .pipeline_state = state,
            .pipeline_op = .splice_socket_to_pipe,
            .bytes_transferred = bytes_already_written,
        };

        try self.ring.queueSplice(state.conn_fd, -1, state.pipe1_write, -1, @intCast(remaining_bytes), @intFromPtr(splice_ctx));
        _ = try self.ring.submit();

        return splice_ctx;
    }
};

pub const PipelineStatus = enum {
    in_progress,
    completed,
    failed,
    need_poll, // Нужен POLL на socket перед повтором splice
};

pub const PipelineResult = struct {
    status: PipelineStatus,
    should_cleanup: bool,
    hash_ready: bool = false,
    hash: [32]u8 = undefined, // Готовый хеш если hash_ready = true
    send_response: bool = false, // Нужно ли отправить HTTP ответ
};
