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

const max_header_bytes: usize = 16 * 1024; // cap HTTP header size to 16KB
const max_block_bytes: usize = 4096 * 128; // 512 KB

fn sizeIndexForLength(length: usize) u8 {
    if (length <= 4096) return 0;
    var idx: u8 = 0;
    var capacity: usize = 4096;
    while (idx < 7 and capacity < length) : (idx += 1) {
        capacity <<= 1;
    }
    return idx;
}

fn blockOffset(info: interfaces.BlockInfo) u64 {
    return info.block_num * @as(u64, info.capacityBytes());
}

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
        // 4KB header buffer keeps typical browser requests in a single read
        const buffer = try self.allocator.alloc(u8, 4096);

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

        var total_read: usize = @intCast(ctx.bytes_transferred);
        total_read += @intCast(bytes_read);
        ctx.bytes_transferred = total_read;

        const buffer = ctx.buffer orelse return error.NoBuffer;
        if (total_read > buffer.len) return error.BufferOverflow;
        var data = buffer[0..total_read];
        var headers: [100]picozig.Header = undefined;
        var httpRequest = picozig.HttpRequest{
            .params = undefined,
            .headers = &headers,
            .body = &[_]u8{},
        };

        const header_len = picozig.parseRequest(data, &httpRequest);
        if (header_len == -2) {
            if (data.len >= max_header_bytes) {
                std.debug.print("HTTP header exceeded {d} bytes\n", .{max_header_bytes});
                self.respondWithStatus(ctx, "431 Request Header Fields Too Large");
                return;
            }

            var current_buffer = buffer;
            if (current_buffer.len == data.len) {
                const new_len = @min(current_buffer.len * 2, max_header_bytes);
                const new_buffer = try self.allocator.alloc(u8, new_len);
                @memcpy(new_buffer[0..data.len], data);
                self.allocator.free(current_buffer);
                ctx.buffer = new_buffer;
                current_buffer = new_buffer;
                data = current_buffer[0..data.len];
            }

            ctx.bytes_transferred = data.len;
            const remaining = current_buffer[data.len..];
            if (remaining.len == 0) {
                self.respondWithStatus(ctx, "431 Request Header Fields Too Large");
                return;
            }

            try self.ring.queueRecv(ctx.conn_fd, remaining, @intFromPtr(ctx));
            _ = try self.ring.submit();
            return;
        } else if (header_len < 0) {
            const status = "400 Bad Request";
            std.debug.print("HTTP parse error {d} -> {s}\n", .{ header_len, status });
            self.respondWithStatus(ctx, status);
            return;
        }

        // ВАЖНО: body может уже быть в буфере после заголовков!
        const header_len_usize: usize = @intCast(header_len);
        const body_in_buffer = if (header_len_usize < data.len) data[header_len_usize..] else &[_]u8{};
        ctx.bytes_transferred = 0; // reset counter before handing off

        // Определяем метод
        const method = httpRequest.params.method;

        if (std.mem.eql(u8, method, "PUT")) {
            try self.handlePut(ctx, &httpRequest, body_in_buffer);
        } else if (std.mem.eql(u8, method, "GET")) {
            try self.handleGet(ctx, &httpRequest);
        } else if (std.mem.eql(u8, method, "HEAD")) {
            try self.handleHead(ctx, &httpRequest);
        } else if (std.mem.eql(u8, method, "PATCH")) {
            try self.handlePatch(ctx, &httpRequest, body_in_buffer);
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
        const content_length = getContentLength(req);
        if (content_length == 0) {
            self.respondWithStatus(ctx, "411 Length Required");
            return;
        }

        if (content_length > max_block_bytes) {
            self.respondWithStatus(ctx, "413 Payload Too Large");
            return;
        }

        const size_index = sizeIndexForLength(content_length);
        const block_info = self.service.onBlockInputRequest(size_index);
        const block_capacity = block_info.capacityBytes();
        if (content_length > block_capacity) {
            std.debug.print(
                "ERROR: content_length {d} exceeds allocated capacity {d} for block_num {d}\n",
                .{ content_length, block_capacity, block_info.block_num },
            );
            self.respondWithStatus(ctx, "500 Internal Server Error");
            return;
        }

        if (body_in_buffer.len > content_length) {
            self.respondWithStatus(ctx, "400 Bad Request");
            return;
        }

        const hash_socket = self.hash_pool.acquire() catch |err| {
            std.debug.print("Failed to acquire hash socket: {}\n", .{err});
            self.respondWithStatus(ctx, "503 Service Unavailable");
            return;
        };

        const pipes1 = try posix.pipe();
        const pipes2 = try posix.pipe();

        const F_SETPIPE_SZ: i32 = 1031;
        const pipe_size: i32 = 524288; // 512 KB
        _ = linux.fcntl(pipes1[0], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes1[1], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes2[0], F_SETPIPE_SZ, pipe_size);
        _ = linux.fcntl(pipes2[1], F_SETPIPE_SZ, pipe_size);

        const pipeline_state = try self.allocator.create(interfaces.PipelineState);
        pipeline_state.* = interfaces.PipelineState.init(pipes1[0], pipes1[1], pipes2[0], pipes2[1], hash_socket);

        if (body_in_buffer.len > 0) {
            const written = try posix.write(pipes1[1], body_in_buffer);
            if (written != body_in_buffer.len) {
                std.debug.print("ERROR: write to pipe failed: wrote {d} of {d} bytes\n", .{ written, body_in_buffer.len });
            }
        }

        const remaining_bytes = content_length - body_in_buffer.len;
        if (remaining_bytes > 0) {
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
            posix.close(pipes1[1]);
            pipeline_state.pipe1_write = -1;

            const offset = blockOffset(block_info);

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

            try self.ring.queueTee(pipes1[0], pipes2[1], @intCast(content_length), @intFromPtr(tee_ctx));
            try self.file_storage.queueSplice(pipes1[0], offset, @intCast(content_length), @intFromPtr(file_ctx));
            try self.ring.queueSplice(pipes2[0], -1, pipeline_state.hash_socket, -1, @intCast(content_length), @intFromPtr(hash_ctx));
            _ = try self.ring.submit();
        }

        if (ctx.buffer) |buf| self.allocator.free(buf);
        self.allocator.destroy(ctx);
    }

    fn handleHead(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest) !void {
        const path = req.params.path;

        if (path.len < 2 or path[0] != '/') {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        const hex_hash = path[1..];
        if (hex_hash.len != 64) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

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

        const exists = self.service.onBlockExistsRequest(hash) catch {
            self.respondWithStatus(ctx, "500 Internal Server Error");
            return;
        };

        const payload_slice: []const u8 = if (exists) "true"[0..4] else "false"[0..5];
        const payload_len = payload_slice.len;
        var header_buf: [128]u8 = undefined;
        const response = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{payload_len}) catch unreachable;
        _ = try posix.send(ctx.conn_fd, response, 0);
        if (payload_len > 0) {
            _ = try posix.send(ctx.conn_fd, payload_slice, 0);
        }
        posix.close(ctx.conn_fd);
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
        const block_capacity = block_info.capacityBytes();
        const data_length: usize = @intCast(@min(block_info.data_size, block_capacity));
        const offset = blockOffset(block_info);
        std.debug.print(
            "GET hit for hash {s} -> block_num {d}, offset {d}, data_size {d}, capacity {d}\n",
            .{ hex_hash, block_info.block_num, offset, data_length, block_capacity },
        );

        // Отправляем HTTP заголовки
        var header_buf: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{data_length}) catch unreachable;
        _ = try posix.send(ctx.conn_fd, headers, 0);

        if (data_length == 0) {
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

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
            .content_length = data_length,
            .hash = hash,
            .buffer = null,
            .pipeline_state = null,
            .bytes_transferred = 0,
        };

        // Сохраняем информацию о pipe в OpContext используя pipeline_state как указатель
        const pipe_state = try self.allocator.create(interfaces.PipelineState);
        pipe_state.* = interfaces.PipelineState.init(pipes[0], pipes[1], -1, -1, -1); // hash_socket = -1 для GET
        read_ctx.pipeline_state = pipe_state;

        // Запускаем splice: file -> pipe (используем queueSplice из ring напрямую)
        try self.ring.queueSplice(self.file_storage.fd, @intCast(offset), pipes[1], -1, @intCast(data_length), @intFromPtr(read_ctx));
        _ = try self.ring.submit();

        if (ctx.buffer) |buf| self.allocator.free(buf);
        self.allocator.destroy(ctx);
    }

    fn handlePatch(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest, body_in_buffer: []const u8) !void {
        const path = req.params.path;
        const prefix = "/lock/";
        if (!std.mem.startsWith(u8, path, prefix)) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        const rest = path[prefix.len..];
        const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        };

        const hex_hash = rest[0..slash_index];
        const resource_id = rest[slash_index + 1 ..];
        if (hex_hash.len != 64 or resource_id.len == 0) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

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

        const content_length = getContentLength(req);
        if (content_length == 0) {
            self.respondWithStatus(ctx, "411 Length Required");
            return;
        }

        if (body_in_buffer.len > content_length) {
            self.respondWithStatus(ctx, "400 Bad Request");
            return;
        }

        var payload = try self.allocator.alloc(u8, content_length);
        defer self.allocator.free(payload);

        var filled: usize = 0;
        if (body_in_buffer.len > 0) {
            @memcpy(payload[0..body_in_buffer.len], body_in_buffer);
            filled = body_in_buffer.len;
        }

        while (filled < content_length) {
            const chunk = posix.recv(ctx.conn_fd, payload[filled..content_length], 0) catch {
                self.respondWithStatus(ctx, "400 Bad Request");
                return;
            };

            if (chunk == 0) {
                self.respondWithStatus(ctx, "400 Bad Request");
                return;
            }

            filled += chunk;
        }

        self.service.onLockPatchRequest(hash, resource_id, payload) catch {
            self.respondWithStatus(ctx, "500 Internal Server Error");
            return;
        };

        const response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _ = try posix.send(ctx.conn_fd, response, 0);
        posix.close(ctx.conn_fd);
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
            const offset_base = blockOffset(ctx.block_info);
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

    fn respondWithStatus(self: *HttpServer, ctx: *OpContext, status: []const u8) void {
        var response_buf: [128]u8 = undefined;
        const response = std.fmt.bufPrint(
            &response_buf,
            "HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{status},
        ) catch unreachable;
        _ = posix.send(ctx.conn_fd, response, 0) catch {};
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
                const offset = blockOffset(ctx.block_info);

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
                    const file_offset = blockOffset(ctx.block_info) + total_written;
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
        self.service.onHashForBlock(state.hash, ctx.block_info, ctx.content_length);

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
