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

const FileStorage = @import("file.zig").FileStorage;

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    ring: *Ring,
    socket: posix.fd_t,
    service: WorkerServiceInterface,
    file_storage: *FileStorage,
    hash_socket: posix.fd_t,

    pub fn init(allocator: std.mem.Allocator, ring: *Ring, port: u16, service: WorkerServiceInterface, file_storage: *FileStorage) !HttpServer {
        const socket = try createSocket(port);
        const hash_socket = try createHashSocket();

        return HttpServer{
            .allocator = allocator,
            .ring = ring,
            .socket = socket,
            .service = service,
            .file_storage = file_storage,
            .hash_socket = hash_socket,
        };
    }

    pub fn deinit(self: *HttpServer) void {
        posix.close(self.socket);
        posix.close(self.hash_socket);
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
            const response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n";
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
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Запрашиваем блок у сервиса
        const block_info = self.service.onBlockInputRequest(0);

        // Создаем pipes для pipeline
        const pipes1 = try posix.pipe();
        const pipes2 = try posix.pipe();

        // Создаем общее состояние pipeline
        const pipeline_state = try self.allocator.create(interfaces.PipelineState);
        pipeline_state.* = interfaces.PipelineState.init(pipes1[0], pipes1[1], pipes2[0], pipes2[1]);

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
            };

            const file_ctx = try self.allocator.create(OpContext);
            file_ctx.* = tee_ctx.*;
            file_ctx.pipeline_op = .splice_to_file;

            const hash_ctx = try self.allocator.create(OpContext);
            hash_ctx.* = tee_ctx.*;
            hash_ctx.pipeline_op = .splice_to_hash;

            // Запускаем 3 операции параллельно
            try self.ring.queueTee(pipes1[0], pipes2[1], @intCast(content_length), @intFromPtr(tee_ctx));
            try self.file_storage.queueSplice(pipes1[0], offset, @intCast(content_length), @intFromPtr(file_ctx));
            try self.ring.queueSplice(pipes2[0], -1, self.hash_socket, -1, @intCast(content_length), @intFromPtr(hash_ctx));
            _ = try self.ring.submit();
        }

        if (ctx.buffer) |buf| self.allocator.free(buf);
        self.allocator.destroy(ctx);
    }

    fn handleGet(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest) !void {
        const path = req.params.path;

        // Проверяем что путь начинается с /
        if (path.len < 2 or path[0] != '/') {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Парсим хеш из пути (убираем начальный /)
        const hex_hash = path[1..];
        if (hex_hash.len != 64) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
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
                const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
                _ = try posix.send(ctx.conn_fd, response, 0);
                posix.close(ctx.conn_fd);
                if (ctx.buffer) |buf| self.allocator.free(buf);
                self.allocator.destroy(ctx);
                return;
            };
        }

        // Запрашиваем адрес блока у сервиса
        const block_info = self.service.onBlockAddressRequest(hash);
        const offset = block_info.block_num * 4096;
        const block_size: u64 = 4096;

        // Отправляем HTTP заголовки
        var header_buf: [256]u8 = undefined;
        const headers = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{block_size}) catch unreachable;
        _ = try posix.send(ctx.conn_fd, headers, 0);

        // Создаем pipe для splice
        const pipes = try posix.pipe();

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
        };

        // Сохраняем информацию о pipe в OpContext используя pipeline_state как указатель
        const pipe_state = try self.allocator.create(interfaces.PipelineState);
        pipe_state.* = interfaces.PipelineState.init(pipes[0], pipes[1], -1, -1);
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
            const response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";
            _ = posix.send(ctx.conn_fd, response, 0) catch {};
            posix.close(ctx.conn_fd);
            state.cleanup();
            self.allocator.destroy(state);
            self.allocator.destroy(ctx);
            return;
        }

        std.debug.print("handleReadBlock: splice file->pipe completed, {d} bytes (expected {d})\n", .{ res, ctx.content_length });

        // Splice из файла в pipe завершен, теперь splice из pipe в socket
        // Закрываем write конец pipe
        posix.close(state.pipe1_write);
        state.pipe1_write = -1; // Помечаем что закрыт

        // Запускаем splice: pipe -> socket
        try self.ring.queueSplice(state.pipe1_read, -1, ctx.conn_fd, -1, @intCast(ctx.content_length), @intFromPtr(ctx));
        ctx.op_type = .send_response; // Меняем тип операции
        _ = try self.ring.submit();
    }

    fn handleSendResponse(self: *HttpServer, ctx: *OpContext, res: i32) !void {
        const state = ctx.pipeline_state orelse return error.NoPipelineState;

        if (res < 0) {
            std.debug.print("Send response failed: {d}\n", .{res});
        }

        // Закрываем соединение и очищаем ресурсы
        posix.close(ctx.conn_fd);
        state.cleanup();
        self.allocator.destroy(state);
        self.allocator.destroy(ctx);
    }

    fn handleDelete(self: *HttpServer, ctx: *OpContext, req: *const picozig.HttpRequest) !void {
        const path = req.params.path;

        // Проверяем что путь начинается с /
        if (path.len < 2 or path[0] != '/') {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            _ = try posix.send(ctx.conn_fd, response, 0);
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
            self.allocator.destroy(ctx);
            return;
        }

        // Парсим хеш из пути (убираем начальный /)
        const hex_hash = path[1..];
        if (hex_hash.len != 64) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
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
                const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
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
        const response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
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
                    const response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";
                    _ = posix.send(ctx.conn_fd, response, 0) catch {};
                    posix.close(ctx.conn_fd);
                    state.cleanup();
                    self.allocator.destroy(state);
                    self.allocator.destroy(ctx);
                    return;
                }

                // Закрываем write-конец pipe1 - больше не нужен
                posix.close(state.pipe1_write);
                state.pipe1_write = -1;

                // Запускаем 3 параллельные операции
                const offset = ctx.block_info.block_num * 4096;

                // Создаем контексты для каждой операции
                const tee_ctx = try self.allocator.create(OpContext);
                tee_ctx.* = ctx.*;
                tee_ctx.pipeline_op = .tee;

                const file_ctx = try self.allocator.create(OpContext);
                file_ctx.* = ctx.*;
                file_ctx.pipeline_op = .splice_to_file;

                const hash_ctx = try self.allocator.create(OpContext);
                hash_ctx.* = ctx.*;
                hash_ctx.pipeline_op = .splice_to_hash;

                // tee(pipe1→pipe2)
                try self.ring.queueTee(state.pipe1_read, state.pipe2_write, @intCast(ctx.content_length), @intFromPtr(tee_ctx));

                // splice(pipe1→file)
                try self.file_storage.queueSplice(state.pipe1_read, offset, @intCast(ctx.content_length), @intFromPtr(file_ctx));

                // splice(pipe2→hash_socket)
                try self.ring.queueSplice(state.pipe2_read, -1, self.hash_socket, -1, @intCast(ctx.content_length), @intFromPtr(hash_ctx));

                _ = try self.ring.submit();
                self.allocator.destroy(ctx);
            },

            .tee => {
                // Закрываем write-конец pipe2
                posix.close(state.pipe2_write);
                state.pipe2_write = -1;

                state.markComplete(.tee);
                try self.checkPipelineComplete(state, ctx);
                self.allocator.destroy(ctx);
            },

            .splice_to_file => {
                // Закрываем read-конец pipe1
                posix.close(state.pipe1_read);
                state.pipe1_read = -1;

                state.markComplete(.splice_to_file);
                try self.checkPipelineComplete(state, ctx);
                self.allocator.destroy(ctx);
            },

            .splice_to_hash => {
                // Закрываем read-конец pipe2
                posix.close(state.pipe2_read);
                state.pipe2_read = -1;

                state.markComplete(.splice_to_hash);

                // Теперь читаем hash из AF_ALG socket
                const hash_buffer = try self.allocator.alloc(u8, 32);
                const len = try posix.recv(self.hash_socket, hash_buffer, 0);

                if (len == 32) {
                    @memcpy(&ctx.hash, hash_buffer[0..32]);
                    self.service.onHashForBlock(ctx.hash, ctx.block_info);
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

        // Все операции завершены!
        // Формируем хеш в hex формате
        var hex_hash: [64]u8 = undefined;
        for (ctx.hash, 0..) |byte, i| {
            _ = std.fmt.bufPrint(hex_hash[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
        }

        // Отправляем ответ с хешем
        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ hex_hash.len, hex_hash }) catch unreachable;
        _ = try posix.send(ctx.conn_fd, response, 0);
        posix.close(ctx.conn_fd);

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

fn createHashSocket() !posix.fd_t {
    const AF_ALG = 38;
    const sock = try posix.socket(AF_ALG, posix.SOCK.SEQPACKET, 0);
    errdefer posix.close(sock);

    // struct sockaddr_alg {
    //   __u16 salg_family;   // 0-1
    //   __u8  salg_type[14]; // 2-15
    //   __u32 salg_feat;     // 16-19
    //   __u32 salg_mask;     // 20-23
    //   __u8  salg_name[64]; // 24-87
    // };
    var addr: [88]u8 = std.mem.zeroes([88]u8);
    addr[0] = AF_ALG; // sa_family (u16)
    addr[1] = 0;

    // salg_type = "hash" (offset 2, length 14)
    @memcpy(addr[2..6], "hash");

    // salg_name = "sha256" (offset 24, length 64)
    @memcpy(addr[24..30], "sha256");

    try posix.bind(sock, @ptrCast(@alignCast(&addr)), 88);

    // accept для получения operation socket
    const op_sock = try posix.accept(sock, null, null, 0);
    posix.close(sock);

    return op_sock;
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
