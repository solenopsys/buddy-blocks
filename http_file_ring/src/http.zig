const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const picozig = @import("picozig").picozig;
const Ring = @import("uring.zig").Ring;
const interfaces = @import("interfaces.zig");
const OpContext = interfaces.OpContext;
const OpType = interfaces.OpType;
const PipelineOp = interfaces.PipelineOp;
const WorkerServiceInterface = interfaces.WorkerServiceInterface;
const WorkerServiceError = interfaces.WorkerServiceError;

const FileStorage = @import("file.zig").FileStorage;
const HashSocketPool = @import("hash_socket_pool.zig").HashSocketPool;

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    ring: *Ring,
    socket: posix.fd_t,
    service: WorkerServiceInterface,
    file_storage: *FileStorage,
    hash_pool: HashSocketPool,

    pub fn init(allocator: std.mem.Allocator, ring: *Ring, port: u16, service: WorkerServiceInterface, file_storage: *FileStorage) !HttpServer {
        const socket = try createSocket(port);

        return HttpServer{
            .allocator = allocator,
            .ring = ring,
            .socket = socket,
            .service = service,
            .file_storage = file_storage,
            .hash_pool = HashSocketPool.init(allocator),
        };
    }

    pub fn deinit(self: *HttpServer) void {
        posix.close(self.socket);
        self.hash_pool.deinit();
    }

    pub fn run(self: *HttpServer) !void {
        // Запускаем accept
        const ctx = try self.allocator.create(OpContext);
        ctx.* = .{
            .op_type = .accept,
            .conn_fd = -1,
            .block_info = .{ .block_num = 0 },
            .content_length = 0,
            .hash = undefined,
            .addr = undefined,
            .addrlen = @sizeOf(posix.sockaddr),
            .bytes_transferred = 0,
        };

        try self.ring.queueAccept(self.socket, &ctx.addr, &ctx.addrlen, @intFromPtr(ctx));
        _ = try self.ring.submit();

        // Event loop
        while (true) {
            const cqe = try self.ring.waitCqe();

            // Игнорируем вспомогательные операции (tee, splice без контекста)
            if (cqe.user_data == 0) {
                if (cqe.res < 0) {
                    std.debug.print("Auxiliary operation failed: {d}\n", .{cqe.res});
                }
                continue;
            }

            const context = @as(*OpContext, @ptrFromInt(cqe.user_data));

            switch (context.op_type) {
                .accept => try self.handleAccept(cqe.res),
                .recv_header => try self.handleHeader(context, cqe.res),
                .pipeline => try self.handlePipeline(context, cqe.res),
                .read_block => try self.handleReadBlock(context, cqe.res),
                .send_response => try self.handleSendResponse(context, cqe.res),
            }
        }
    }

    fn handleAccept(self: *HttpServer, res: i32) !void {
        if (res < 0) {
            std.debug.print("Accept failed with error code: {d}\n", .{res});
            return error.AcceptFailed;
        }

        const conn_fd = res;
        // Буфер 256 байт - достаточно для HTTP заголовков, body останется в socket для splice
        const buffer = try self.allocator.alloc(u8, 256);

        const ctx = try self.allocator.create(OpContext);
        ctx.* = .{
            .op_type = .recv_header,
            .conn_fd = conn_fd,
            .block_info = .{ .block_num = 0 },
            .content_length = 0,
            .hash = undefined,
            .buffer = buffer,
            .bytes_transferred = 0,
        };

        try self.ring.queueRecv(conn_fd, buffer, @intFromPtr(ctx));
        _ = try self.ring.submit();

        // Снова ставим accept
        const accept_ctx = try self.allocator.create(OpContext);
        accept_ctx.* = .{
            .op_type = .accept,
            .conn_fd = -1,
            .block_info = .{ .block_num = 0 },
            .content_length = 0,
            .hash = undefined,
            .addr = undefined,
            .addrlen = @sizeOf(posix.sockaddr),
            .bytes_transferred = 0,
        };

        try self.ring.queueAccept(self.socket, &accept_ctx.addr, &accept_ctx.addrlen, @intFromPtr(accept_ctx));
        _ = try self.ring.submit();
    }

    fn handleHeader(self: *HttpServer, ctx: *OpContext, bytes_read: i32) !void {
        if (bytes_read <= 0) {
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        const buffer = ctx.buffer orelse return error.NoBuffer;
        const data = buffer[0..@intCast(bytes_read)];
        var headers: [100]picozig.Header = undefined;
        var httpRequest = picozig.HttpRequest{
            .params = undefined,
            .headers = &headers,
            .body = &[_]u8{},
        };

        const header_len = picozig.parseRequest(data, &httpRequest);

        // ВАЖНО: body может уже быть в буфере после заголовков!
        const header_len_usize: usize = @intCast(header_len);
        const body_in_buffer = if (header_len > 0 and header_len_usize < data.len) data[header_len_usize..] else &[_]u8{};

        // Определяем метод
        const method = httpRequest.params.method;

        if (std.mem.eql(u8, method, "PUT")) {
            try self.handlePut(ctx, &httpRequest, body_in_buffer);
        } else if (std.mem.eql(u8, method, "GET")) {
            try self.handleGet(ctx, &httpRequest);
        } else if (std.mem.eql(u8, method, "DELETE")) {
            try self.handleDelete(ctx, &httpRequest);
        } else {
            // Неподдерживаемый метод
            const response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            self.allocator.free(buffer);
            self.allocator.destroy(ctx);
        }
    }

    fn handlePut(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest, body_in_buffer: []const u8) !void {
        // Получаем Content-Length
        const content_length = getContentLength(req);
        if (content_length == 0) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Запрашиваем блок у сервиса
        // size_index: 0=4KB, 1=8KB, 2=16KB, 3=32KB, 4=64KB, 5=128KB, 6=256KB, 7=512KB
        const size_index: u8 = @intCast(@ctz(content_length / 4096));
        const block_info = self.service.onBlockInputRequest(size_index);

        // Получаем hash_socket из пула
        const hash_socket = self.hash_pool.acquire() catch |err| {
            std.debug.print("Failed to acquire hash socket: {}\n", .{err});
            const response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        };

        // Создаем pipes для pipeline
        const pipes1 = try posix.pipe();
        const pipes2 = try posix.pipe();

        // Увеличиваем размер pipe буферов до 512KB
        const F_SETPIPE_SZ: i32 = 1031;
        const pipe_size: i32 = 524288; // 512 KB
        _ = linux.fcntl(pipes1[0], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes1[1], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes2[0], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes2[1], F_SETPIPE_SZ, pipe_size);

        // Создаем общее состояние pipeline
        const pipeline_state = try self.allocator.create(interfaces.PipelineState);
        pipeline_state.* = interfaces.PipelineState.init(pipes1[0], pipes1[1], pipes2[0], pipes2[1], hash_socket);

        // Если часть body уже в буфере - записываем её в pipe
        if (body_in_buffer.len > 0) {
            const written = try posix.write(pipes1[1], body_in_buffer);
            if (written != body_in_buffer.len) {
                std.debug.print("ERROR: write to pipe failed: wrote {d} of {d} bytes\n", .{ written, body_in_buffer.len });
            }
        }

        const remaining_bytes = content_length - body_in_buffer.len;

        if (remaining_bytes > 0) {
            // Есть ещё данные в socket - делаем splice
            const splice_ctx = try self.allocator.create(OpContext);
            splice_ctx.* = .{
                .op_type = .pipeline,
                .conn_fd = ctx.conn_fd,
                .block_info = block_info,
                .content_length = content_length,
                .hash = undefined,
                .buffer = null,
                .pipeline_state = pipeline_state,
                .pipeline_op = .splice_socket_to_pipe,
                .bytes_transferred = @intCast(body_in_buffer.len),
            };

            try self.ring.queueSplice(ctx.conn_fd, -1, pipes1[1], -1, @intCast(remaining_bytes), @intFromPtr(splice_ctx));
            _ = try self.ring.submit();
        } else {
            // Все данные уже в pipe, запускаем pipeline сразу
            posix.close(pipes1[1]); // Закрываем write end
            pipeline_state.pipe1_write = -1; // Помечаем что уже закрыт

            const offset = block_info.block_num * 4096;

            // Создаем контексты для 3 параллельных операций
            const tee_ctx = try self.allocator.create(OpContext);
            tee_ctx.* = .{
                .op_type = .pipeline,
                .conn_fd = ctx.conn_fd,
                .block_info = block_info,
                .content_length = content_length,
                .hash = undefined,
                .buffer = null,
                .pipeline_state = pipeline_state,
                .pipeline_op = .tee,
                .bytes_transferred = 0,
            };

            const file_ctx = try self.allocator.create(OpContext);
            file_ctx.* = tee_ctx.*;
            file_ctx.pipeline_op = .splice_to_file;
            file_ctx.bytes_transferred = 0;

            const hash_ctx = try self.allocator.create(OpContext);
            hash_ctx.* = tee_ctx.*;
            hash_ctx.pipeline_op = .splice_to_hash;
            hash_ctx.bytes_transferred = 0;

            // Запускаем 3 операции параллельно
            try self.ring.queueTee(pipes1[0], pipes2[1], @intCast(content_length), @intFromPtr(tee_ctx));
            try self.file_storage.queueSplice(pipes1[0], offset, @intCast(content_length), @intFromPtr(file_ctx));
            try self.ring.queueSplice(pipes2[0], -1, pipeline_state.hash_socket, -1, @intCast(content_length), @intFromPtr(hash_ctx));
            _ = try self.ring.submit();
        }

        if (ctx.buffer) |buf| self.allocator.free(buf);
        self.allocator.destroy(ctx);
    }

    fn handleGet(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest) !void {
        const path = req.params.path;

        // Проверяем что путь начинается с /
        if (path.len < 2 or path[0] != '/') {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Парсим хеш из пути (убираем начальный /)
        const hex_hash = path[1..];
        if (hex_hash.len != 64) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Конвертируем hex в bytes
        var hash: [32]u8 = undefined;
        for (0..32) |i| {
            hash[i] = std.fmt.parseInt(u8, hex_hash[i * 2 .. i * 2 + 2], 16) catch {
                const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                _ = try posix.send(ctx.conn_fd, response, 0);
                posix.close(ctx.conn_fd);
                if (ctx.buffer) |buf| self.allocator.free(buf);
                self.allocator.destroy(ctx);
                return;
            };
        }

        // Запрашиваем адрес блока у сервиса
        const block_info = self.service.onBlockAddressRequest(hash) catch {
            std.debug.print("GET miss for hash {s}\n", .{hex_hash});
            const response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        };
        std.debug.print("GET hit for hash {s} -> block_num {d}\n", .{ hex_hash, block_info.block_num });
        const offset = block_info.block_num * 4096;
        const block_size: u64 = @as(u64, 4096) << @intCast(block_info.size_index);

        // Отправляем HTTP заголовки
        var header_buf: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{block_size}) catch unreachable;
        _ = try posix.send(ctx.conn_fd, headers, 0);

        // Создаем pipe для splice
        const pipes = try posix.pipe();

        // Увеличиваем размер pipe буферов до 512KB
        const F_SETPIPE_SZ: i32 = 1031;
        const pipe_size: i32 = 524288; // 512 KB
        _ = linux.fcntl(pipes[0], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes[1], F_SETPIPE_SZ, pipe_size);

        // Сохраняем контекст для продолжения
        const read_ctx = try self.allocator.create(OpContext);
        read_ctx.* = .{
            .op_type = .read_block,
            .conn_fd = ctx.conn_fd,
            .block_info = block_info,
            .content_length = block_size,
            .hash = hash,
            .buffer = null,
            .pipeline_state = null,
            .bytes_transferred = 0,
        };

        // Сохраняем информацию о pipe в OpContext используя pipeline_state как указатель
        const pipe_state = try self.allocator.create(interfaces.PipelineState);
        pipe_state.* = interfaces.PipelineState.init(pipes[0], pipes[1], -1, -1, -1);  // hash_socket = -1 для GET
        read_ctx.pipeline_state = pipe_state;

        // Запускаем splice: file -> pipe (используем queueSplice из ring напрямую)
        try self.ring.queueSplice(self.file_storage.fd, @intCast(offset), pipes[1], -1, @intCast(block_size), @intFromPtr(read_ctx));
        _ = try self.ring.submit();

        if (ctx.buffer) |buf| self.allocator.free(buf);
        self.allocator.destroy(ctx);
    }

    fn handleReadBlock(self: *HttpServer, ctx: *OpContext, res: i32) !void {
        const state = ctx.pipeline_state orelse return error.NoPipelineState;

        if (res < 0) {
            std.debug.print("Read block failed: {d}\n", .{res});
            const response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = posix.send(ctx.conn_fd, response, 0) catch {};
            posix.close(ctx.conn_fd);
            state.cleanup();
            self.allocator.destroy(state);
            self.allocator.destroy(ctx);
            return;
        }

        if (res == 0) {
            std.debug.print("Read block returned 0 bytes unexpectedly\n", .{});
            const response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = posix.send(ctx.conn_fd, response, 0) catch {};
            posix.close(ctx.conn_fd);
            state.cleanup();
            self.allocator.destroy(state);
            self.allocator.destroy(ctx);
            return;
        }

        ctx.bytes_transferred += @intCast(res);
        if (ctx.bytes_transferred < ctx.content_length) {
            const offset_base = ctx.block_info.block_num * 4096;
            const next_offset = offset_base + ctx.bytes_transferred;
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueSplice(self.file_storage.fd, @intCast(next_offset), state.pipe1_write, -1, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return;
        }

        // Splice из файла в pipe завершен, теперь splice из pipe в socket
        if (state.pipe1_write >= 0) {
            posix.close(state.pipe1_write);
            state.pipe1_write = -1;
        }
        ctx.bytes_transferred = 0;

        try self.ring.queueSplice(state.pipe1_read, -1, ctx.conn_fd, -1, @intCast(ctx.content_length), @intFromPtr(ctx));
        ctx.op_type = .send_response;
        _ = try self.ring.submit();
    }

    fn handleSendResponse(self: *HttpServer, ctx: *OpContext, res: i32) !void {
        const state = ctx.pipeline_state orelse return error.NoPipelineState;

        if (res < 0) {
            std.debug.print("Send response failed: {d}\n", .{res});
            posix.close(ctx.conn_fd);
            state.cleanup();
            self.allocator.destroy(state);
            self.allocator.destroy(ctx);
            return;
        }

        if (res == 0 and ctx.bytes_transferred < ctx.content_length) {
            std.debug.print("Send response returned 0 bytes before finishing transfer\n", .{});
            posix.close(ctx.conn_fd);
            state.cleanup();
            self.allocator.destroy(state);
            self.allocator.destroy(ctx);
            return;
        }

        ctx.bytes_transferred += @intCast(res);
        if (ctx.bytes_transferred < ctx.content_length) {
            const remaining = ctx.content_length - ctx.bytes_transferred;
            try self.ring.queueSplice(state.pipe1_read, -1, ctx.conn_fd, -1, @intCast(remaining), @intFromPtr(ctx));
            _ = try self.ring.submit();
            return;
        }

        posix.close(ctx.conn_fd);
        state.cleanup();
        self.allocator.destroy(state);
        self.allocator.destroy(ctx);
    }

    fn handleDelete(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest) !void {
        const path = req.params.path;

        // Проверяем что путь начинается с /
        if (path.len < 2 or path[0] != '/') {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Парсим хеш из пути (убираем начальный /)
        const hex_hash = path[1..];
        if (hex_hash.len != 64) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Конвертируем hex в bytes
        var hash: [32]u8 = undefined;
        for (0..32) |i| {
            hash[i] = std.fmt.parseInt(u8, hex_hash[i * 2 .. i * 2 + 2], 16) catch {
                const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                _ = try posix.send(ctx.conn_fd, response, 0);
                posix.close(ctx.conn_fd);
                if (ctx.buffer) |buf| self.allocator.free(buf);
                self.allocator.destroy(ctx);
                return;
            };
        }

        // Запрашиваем освобождение блока у сервиса
        _ = self.service.onFreeBlockRequest(hash);

        // Отправляем успешный ответ
        const response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _ = try posix.send(ctx.conn_fd, response, 0);
        posix.close(ctx.conn_fd);

        if (ctx.buffer) |buf| self.allocator.free(buf);
        self.allocator.destroy(ctx);
    }

    fn handlePipeline(self: *HttpServer, ctx: *OpContext, res: i32) !void {
        const state = ctx.pipeline_state orelse return error.NoPipelineState;

        // Обрабатываем ошибку
        if (res < 0) {
            std.debug.print("Pipeline operation {s} failed: {d}\n", .{ @tagName(ctx.pipeline_op), res });
            state.has_error = true;
            // Возвращаем hash_socket в пул если он был выделен
            if (state.hash_socket >= 0) {
                self.hash_pool.release(state.hash_socket);
            }
            state.cleanup();
            posix.close(ctx.conn_fd);
            self.allocator.destroy(state);
            self.allocator.destroy(ctx);
            return;
        }

        // Обрабатываем в зависимости от того, какая операция завершилась
        switch (ctx.pipeline_op) {
            .splice_socket_to_pipe => {
                // КРИТИЧЕСКАЯ ПРОВЕРКА: если splice вернул 0 байт, данные не прочитались!
                if (res == 0) {
                    std.debug.print("ERROR: splice(socket->pipe) returned 0 bytes! Socket buffer might be empty or not ready.\n", .{});
                    const response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    _ = posix.send(ctx.conn_fd, response, 0) catch {};
                    posix.close(ctx.conn_fd);
                    // Возвращаем hash_socket в пул
                    if (state.hash_socket >= 0) {
                        self.hash_pool.release(state.hash_socket);
                    }
                    state.cleanup();
                    self.allocator.destroy(state);
                    self.allocator.destroy(ctx);
                    return;
                }

                ctx.bytes_transferred += @intCast(res);
                if (ctx.bytes_transferred < ctx.content_length) {
                    const remaining = ctx.content_length - ctx.bytes_transferred;
                    try self.ring.queueSplice(ctx.conn_fd, -1, state.pipe1_write, -1, @intCast(remaining), @intFromPtr(ctx));
                    _ = try self.ring.submit();
                    return;
                }

                // Закрываем write-конец pipe1 - больше не нужен
                if (state.pipe1_write >= 0) {
                    posix.close(state.pipe1_write);
                    state.pipe1_write = -1;
                }

                ctx.bytes_transferred = 0;

                // Запускаем 3 параллельные операции
                const offset = ctx.block_info.block_num * 4096;

                // Создаем контексты для каждой операции
                const tee_ctx = try self.allocator.create(OpContext);
                tee_ctx.* = ctx.*;
                tee_ctx.pipeline_op = .tee;
                tee_ctx.bytes_transferred = 0;

                const file_ctx = try self.allocator.create(OpContext);
                file_ctx.* = ctx.*;
                file_ctx.pipeline_op = .splice_to_file;
                file_ctx.bytes_transferred = 0;

                const hash_ctx = try self.allocator.create(OpContext);
                hash_ctx.* = ctx.*;
                hash_ctx.pipeline_op = .splice_to_hash;
                hash_ctx.bytes_transferred = 0;

                // tee(pipe1→pipe2)
                try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(ctx.content_length), @intFromPtr(tee_ctx));

                // splice(pipe1→file)
                try self.file_storage.queueSplice(state.pipe1_read, offset, @intCast(ctx.content_length), @intFromPtr(file_ctx));

                // splice(pipe2→hash_socket)
                try self.ring.queueSplice(state.pipe2_read, -1, state.hash_socket, -1, @intCast(ctx.content_length), @intFromPtr(hash_ctx));

                _ = try self.ring.submit();
                self.allocator.destroy(ctx);
            },

            .tee => {
                std.debug.print("TEE completed {d} bytes (res={d})\n", .{ ctx.bytes_transferred, res });
                if (res == 0) {
                    std.debug.print("ERROR: tee(pipe1->pipe2) returned 0 bytes\n", .{});
                    state.has_error = true;
                    // Возвращаем hash_socket в пул
                    if (state.hash_socket >= 0) {
                        self.hash_pool.release(state.hash_socket);
                    }
                    state.cleanup();
                    posix.close(ctx.conn_fd);
                    self.allocator.destroy(state);
                    self.allocator.destroy(ctx);
                    return;
                }

                ctx.bytes_transferred += @intCast(res);
                if (ctx.bytes_transferred < ctx.content_length) {
                    const remaining = ctx.content_length - ctx.bytes_transferred;
                    try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(remaining), @intFromPtr(ctx));
                    _ = try self.ring.submit();
                    return;
                }

                if (state.pipe2_write >= 0) {
                    posix.close(state.pipe2_write);
                    state.pipe2_write = -1;
                }

                state.markComplete(.tee);
                try self.checkPipelineComplete(state, ctx);
                self.allocator.destroy(ctx);
            },

            .splice_to_file => {
                std.debug.print("Splice to file completed chunk {d} bytes (res={d})\n", .{ ctx.bytes_transferred, res });
                if (res == 0) {
                    std.debug.print("ERROR: splice(pipe1->file) returned 0 bytes\n", .{});
                    state.has_error = true;
                    // Возвращаем hash_socket в пул
                    if (state.hash_socket >= 0) {
                        self.hash_pool.release(state.hash_socket);
                    }
                    state.cleanup();
                    posix.close(ctx.conn_fd);
                    self.allocator.destroy(state);
                    self.allocator.destroy(ctx);
                    return;
                }

                ctx.bytes_transferred += @intCast(res);
                if (ctx.bytes_transferred < ctx.content_length) {
                    const total_written = ctx.bytes_transferred;
                    const remaining = ctx.content_length - total_written;
                    const file_offset = ctx.block_info.block_num * 4096 + total_written;
                    try self.file_storage.queueSplice(state.pipe1_read, file_offset, @intCast(remaining), @intFromPtr(ctx));
                    _ = try self.ring.submit();
                    return;
                }

                if (state.pipe1_read >= 0) {
                    posix.close(state.pipe1_read);
                    state.pipe1_read = -1;
                }

                state.markComplete(.splice_to_file);
                try self.checkPipelineComplete(state, ctx);
                self.allocator.destroy(ctx);
            },

            .splice_to_hash => {
                std.debug.print("Splice to hash completed chunk {d} bytes (res={d})\n", .{ ctx.bytes_transferred, res });
                if (res == 0) {
                    std.debug.print("ERROR: splice(pipe2->hash) returned 0 bytes\n", .{});
                    state.has_error = true;
                    // Возвращаем hash_socket в пул
                    if (state.hash_socket >= 0) {
                        self.hash_pool.release(state.hash_socket);
                    }
                    state.cleanup();
                    posix.close(ctx.conn_fd);
                    self.allocator.destroy(state);
                    self.allocator.destroy(ctx);
                    return;
                }

                ctx.bytes_transferred += @intCast(res);
                if (ctx.bytes_transferred < ctx.content_length) {
                    const remaining = ctx.content_length - ctx.bytes_transferred;
                    try self.ring.queueSplice(state.pipe2_read, -1, state.hash_socket, -1, @intCast(remaining), @intFromPtr(ctx));
                    _ = try self.ring.submit();
                    return;
                }

                if (state.pipe2_read >= 0) {
                    posix.close(state.pipe2_read);
                    state.pipe2_read = -1;
                }

                state.markComplete(.splice_to_hash);

                // Теперь читаем hash из AF_ALG socket
                const hash_buffer = try self.allocator.alloc(u8, 32);
                const len = try posix.recv(state.hash_socket, hash_buffer, 0);

                if (len == 32) {
                    @memcpy(&state.hash, hash_buffer[0..32]);
                    state.hash_ready = true;
                } else {
                    std.debug.print("read_hash failed: expected 32 bytes, got {d}\n", .{len});
                }

                self.allocator.free(hash_buffer);

                try self.checkPipelineComplete(state, ctx);
                self.allocator.destroy(ctx);
            },
        }
    }

    fn checkPipelineComplete(self: *HttpServer, state: *interfaces.PipelineState, ctx: *OpContext) !void {
        if (!state.isComplete()) return;
        if (!state.hash_ready) {
            std.debug.print("ERROR: pipeline complete but hash not ready\n", .{});
            return;
        }

        // Все операции завершены!
        // Формируем хеш в hex формате
        var hex_hash: [64]u8 = undefined;
        for (state.hash, 0..) |byte, i| {
            _ = std.fmt.bufPrint(hex_hash[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
        }

        // Сохраняем сопоставление хеша и блока после полной обработки
        self.service.onHashForBlock(state.hash, ctx.block_info);

        std.debug.print("Responding with hash {s} for block_num {d}\n", .{ hex_hash, ctx.block_info.block_num });

        // Отправляем ответ с хешем
        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ hex_hash.len, hex_hash }) catch unreachable;
        _ = try posix.send(ctx.conn_fd, response, 0);
        posix.close(ctx.conn_fd);

        // Возвращаем hash_socket в пул
        self.hash_pool.release(state.hash_socket);

        // Cleanup
        state.cleanup();
        self.allocator.destroy(state);
    }
};

fn createSocket(port: u16) !posix.fd_t {
    const socket = posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch |err| {
        std.debug.print("ERROR: Failed to create socket: {}\n", .{err});
        return err;
    };
    errdefer posix.close(socket);

    const yes: i32 = 1;
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&yes)) catch |err| {
        std.debug.print("ERROR: Failed to set SO_REUSEADDR: {}\n", .{err});
        return err;
    };

    // Set SO_REUSEPORT to allow multiple workers on the same port
    posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&yes)) catch |err| {
        std.debug.print("ERROR: Failed to set SO_REUSEPORT: {}\n", .{err});
        return err;
    };

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    posix.bind(socket, &address.any, address.getOsSockLen()) catch |err| {
        std.debug.print("ERROR: Failed to bind to port {d}: {}\n", .{ port, err });
        std.debug.print("       Port is already in use. Please stop the existing server first.\n", .{});
        return err;
    };

    posix.listen(socket, 128) catch |err| {
        std.debug.print("ERROR: Failed to listen on port {d}: {}\n", .{ port, err });
        return err;
    };

    return socket;
}

fn getContentLength(req: *const picozig.HttpRequest) usize {
    const headers = req.headers[0..req.params.num_headers];
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) {
            return std.fmt.parseInt(usize, header.value, 10) catch 0;
        }
    }
    return 0;
}
