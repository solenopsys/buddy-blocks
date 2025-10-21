const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const interfaces = @import("../messaging/interfaces.zig");
const messages = @import("../messaging/messages.zig");
const IMessageQueue = interfaces.IMessageQueue;
const IBlockPool = interfaces.IBlockPool;
const BlockInfo = interfaces.BlockInfo;

// Operation types in user_data (top 32 bits)
const OP_ACCEPT: u64 = 0;
const OP_READ: u64 = 1;
const OP_WRITE: u64 = 2;
const OP_FILE_READ: u64 = 3;
const OP_FILE_WRITE: u64 = 4;
const OP_PUT_WRITE: u64 = 5;

const Client = struct {
    socket: posix.fd_t,
    buffer: []u8,
    data: std.ArrayList(u8),
    is_complete: bool,
    keep_alive: bool,
    allocator: Allocator,

    fn init(socket: posix.fd_t, buffer: []u8, allocator: Allocator) Client {
        return .{
            .socket = socket,
            .buffer = buffer,
            .data = std.ArrayList(u8).empty,
            .is_complete = false,
            .keep_alive = true,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Client) void {
        self.data.deinit(self.allocator);
    }

    fn reset(self: *Client) void {
        self.data.clearRetainingCapacity();
        self.is_complete = false;
    }
};

const FileTransfer = struct {
    client_id: u64,
    file_fd: posix.fd_t,
    socket_fd: posix.fd_t,
    file_offset: u64,
    remaining: u64,
    buffer: []u8,
    allocator: Allocator,
    header_sent: bool,

    fn deinit(self: *FileTransfer) void {
        self.allocator.free(self.buffer);
    }
};

const PutWrite = struct {
    client_id: u64,
    hash: [32]u8,
    data: []u8,  // Owned copy of data
    offset: u64,
    allocator: Allocator,

    fn deinit(self: *PutWrite) void {
        self.allocator.free(self.data);
    }
};

/// Pending request waiting for Controller response
const PendingRequest = struct {
    request_id: u64,
    client_id: u64,
    request_type: RequestType,
    hash: [32]u8 = [_]u8{0} ** 32, // Used for PUT/DELETE/GET requests

    const RequestType = enum {
        allocate, // PUT - ждем allocate_result с блоком
        occupy, // PUT - ждем occupy_result с offset для записи данных
        get_address, // GET - ждем get_address_result с offset/size
        release, // DELETE - ждем release_result
    };
};

pub const HttpWorker = struct {
    id: u8,
    allocator: Allocator,
    ring: linux.IoUring,
    server_socket: posix.fd_t,
    clients: std.AutoHashMap(u64, *Client),
    file_transfers: std.AutoHashMap(u64, *FileTransfer),
    put_writes: std.AutoHashMap(u64, *PutWrite),
    next_client_id: u64,
    next_transfer_id: u64,
    next_put_write_id: u64,
    file_fd: posix.fd_t,
    port: u16,

    // Block pools (8 пулов для размеров 0-7)
    block_pools: [8]IBlockPool,

    // SPSC queues к/от Controller
    to_controller: IMessageQueue,
    from_controller: IMessageQueue,

    // Pending requests (request_id -> PendingRequest)
    pending_requests: std.AutoHashMap(u64, PendingRequest),
    next_request_id: u64,

    // Для динамической паузы
    before_run: i128,
    cycle_interval_ns: i128,

    // Флаг работы
    running: std.atomic.Value(bool),

    pub fn init(
        id: u8,
        allocator: Allocator,
        port: u16,
        file_fd: posix.fd_t,
        block_pools: [8]IBlockPool,
        to_controller: IMessageQueue,
        from_controller: IMessageQueue,
        cycle_interval_ns: i128,
    ) !HttpWorker {
        const server_socket = try createServerSocket(port);
        errdefer posix.close(server_socket);

        const ring = try linux.IoUring.init(512, 0);
        errdefer ring.deinit();

        return .{
            .id = id,
            .allocator = allocator,
            .ring = ring,
            .server_socket = server_socket,
            .clients = std.AutoHashMap(u64, *Client).init(allocator),
            .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(allocator),
            .put_writes = std.AutoHashMap(u64, *PutWrite).init(allocator),
            .next_client_id = 1,
            .next_transfer_id = 1,
            .next_put_write_id = 1,
            .file_fd = file_fd,
            .port = port,
            .block_pools = block_pools,
            .to_controller = to_controller,
            .from_controller = from_controller,
            .pending_requests = std.AutoHashMap(u64, PendingRequest).init(allocator),
            .next_request_id = 1,
            .before_run = std.time.nanoTimestamp(),
            .cycle_interval_ns = cycle_interval_ns,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *HttpWorker) void {
        var client_it = self.clients.iterator();
        while (client_it.next()) |entry| {
            posix.close(entry.value_ptr.*.socket);
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.value_ptr.*.buffer);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.clients.deinit();

        var transfer_it = self.file_transfers.iterator();
        while (transfer_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.file_transfers.deinit();

        var put_write_it = self.put_writes.iterator();
        while (put_write_it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.put_writes.deinit();

        self.pending_requests.deinit();
        self.ring.deinit();
        posix.close(self.server_socket);
    }

    pub fn run(self: *HttpWorker) !void {
        std.debug.print("Worker {d} started on port {d}\n", .{ self.id, self.port });

        // Submit initial accept
        const accept_user_data = (OP_ACCEPT << 32) | 0;
        _ = try self.ring.accept(accept_user_data, self.server_socket, null, null, 0);

        while (self.running.load(.monotonic)) {
            // Используем submit_and_wait с минимальным ожиданием 1 события
            // Это блокирует выполнение пока не появится хотя бы одно событие
            _ = try self.ring.submit_and_wait(1);

            // Обрабатываем все готовые CQE
            while (self.ring.cq_ready() > 0) {
                const cqe = try self.ring.copy_cqe();

                const op_type = cqe.user_data >> 32;
                const id = cqe.user_data & 0xFFFFFFFF;

                if (op_type == OP_ACCEPT) {
                    self.handleAccept(cqe.res) catch |err| {
                        std.debug.print("Worker {d}: Accept error: {any}\n", .{ self.id, err });
                    };
                    // Re-submit accept
                    _ = self.ring.accept(accept_user_data, self.server_socket, null, null, 0) catch {};
                } else if (op_type == OP_READ) {
                    self.handleClientRead(id, cqe.res) catch |err| {
                        std.debug.print("Worker {d}: Read error for client {d}: {any}\n", .{ self.id, id, err });
                    };
                } else if (op_type == OP_WRITE) {
                    self.handleClientWrite(id, cqe.res) catch |err| {
                        std.debug.print("Worker {d}: Write error for client {d}: {any}\n", .{ self.id, id, err });
                    };
                } else if (op_type == OP_FILE_READ) {
                    self.handleFileRead(id, cqe.res) catch |err| {
                        std.debug.print("Worker {d}: File read error for transfer {d}: {any}\n", .{ self.id, id, err });
                    };
                } else if (op_type == OP_FILE_WRITE) {
                    self.handleFileWrite(id, cqe.res) catch |err| {
                        std.debug.print("Worker {d}: File write error for transfer {d}: {any}\n", .{ self.id, id, err });
                    };
                } else if (op_type == OP_PUT_WRITE) {
                    self.handlePutWrite(id, cqe.res) catch |err| {
                        std.debug.print("Worker {d}: PUT write error for id {d}: {any}\n", .{ self.id, id, err });
                    };
                }
            }

            // Проверяем сообщения от Controller
            try self.checkControllerMessages();

            // Проверяем и пополняем пулы блоков
            try self.refillPools();
        }
    }

    pub fn shutdown(self: *HttpWorker) void {
        self.running.store(false, .monotonic);
    }

    /// Проверяет все пулы и запрашивает новые блоки если нужно
    fn refillPools(self: *HttpWorker) !void {
        for (self.block_pools, 0..) |pool, size_index| {
            if (pool.needsRefill()) {
                const request_id = self.next_request_id;
                self.next_request_id += 1;

                // Отправляем allocate запрос
                const msg = messages.Message{
                    .allocate_block = .{
                        .worker_id = self.id,
                        .request_id = request_id,
                        .size = @intCast(size_index),
                    },
                };

                _ = self.to_controller.push(msg);
            }
        }
    }

    /// Проверяет сообщения от Controller и обрабатывает их
    fn checkControllerMessages(self: *HttpWorker) !void {
        var msg: messages.Message = undefined;
        while (self.from_controller.pop(&msg)) {
            switch (msg) {
                .allocate_result => |result| {
                    // Добавляем блок в соответствующий пул
                    const block_info = BlockInfo{
                        .offset = result.offset,
                        .size = result.size,
                        .block_num = result.block_num,
                    };

                    if (result.size < 8) {
                        self.block_pools[result.size].release(block_info);
                    }

                    // Если это ответ на pending request - обрабатываем
                    if (self.pending_requests.get(result.request_id)) |pending| {
                        if (pending.request_type == .allocate) {
                            // TODO: continue PUT request processing
                            _ = self.pending_requests.remove(result.request_id);
                        }
                    }
                },
                .occupy_result => |result| {
                    // Получили offset - запускаем async write через io_uring
                    if (self.pending_requests.get(result.request_id)) |pending| {
                        if (pending.request_type == .occupy) {
                            const client = self.clients.getPtr(pending.client_id) orelse {
                                _ = self.pending_requests.remove(result.request_id);
                                return;
                            };

                            // Extract body from client data
                            const request = client.*.data.items;
                            const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
                                _ = self.pending_requests.remove(result.request_id);
                                return;
                            };
                            const body = request[body_start + 4 ..];

                            // Create PutWrite with owned copy of data
                            const put_write_id = self.next_put_write_id;
                            self.next_put_write_id += 1;

                            const put_write = try self.allocator.create(PutWrite);
                            const data_copy = try self.allocator.alloc(u8, body.len);
                            @memcpy(data_copy, body);

                            put_write.* = .{
                                .client_id = pending.client_id,
                                .hash = pending.hash,
                                .data = data_copy,
                                .offset = result.offset,
                                .allocator = self.allocator,
                            };

                            try self.put_writes.put(put_write_id, put_write);

                            // Submit async write через io_uring
                            const write_user_data = (OP_PUT_WRITE << 32) | put_write_id;
                            _ = try self.ring.write(write_user_data, self.file_fd, data_copy, result.offset);

                            _ = self.pending_requests.remove(result.request_id);
                        }
                    }
                },
                .release_result => |result| {
                    // Подтверждение release - отправляем успешный ответ
                    if (self.pending_requests.get(result.request_id)) |pending| {
                        if (pending.request_type == .release) {
                            try self.sendDeleteSuccessResponse(pending.client_id);
                            _ = self.pending_requests.remove(result.request_id);
                        }
                    }
                },
                .get_address_result => |result| {
                    // Получили offset и size - начинаем file transfer
                    if (self.pending_requests.get(result.request_id)) |pending| {
                        if (pending.request_type == .get_address) {
                            try self.startFileTransfer(pending.client_id, result.offset, result.size);
                            _ = self.pending_requests.remove(result.request_id);
                        }
                    }
                },
                .error_result => |result| {
                    // Ошибка от Controller - отправляем 500 клиенту
                    if (self.pending_requests.get(result.request_id)) |pending| {
                        try self.sendErrorResponse(pending.client_id, result.code);
                        _ = self.pending_requests.remove(result.request_id);
                    }
                },
                else => {}, // Игнорируем некорректные сообщения
            }
        }
    }

    fn handleAccept(self: *HttpWorker, result: i32) !void {
        if (result < 0) return error.AcceptFailed;

        const client_socket: posix.fd_t = @intCast(result);
        const buffer = try self.allocator.alloc(u8, 8192);

        const client_id = self.next_client_id;
        self.next_client_id += 1;

        const client = try self.allocator.create(Client);
        client.* = Client.init(client_socket, buffer, self.allocator);

        try self.clients.put(client_id, client);

        // Submit read
        const read_user_data = (OP_READ << 32) | client_id;
        _ = try self.ring.read(read_user_data, client_socket, .{ .buffer = buffer }, 0);
    }

    fn handleClientRead(self: *HttpWorker, client_id: u64, result: i32) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        if (result <= 0) {
            self.closeClient(client_id);
            return;
        }

        const bytes_read: usize = @intCast(result);
        try client.*.data.appendSlice(client.*.allocator, client.*.buffer[0..bytes_read]);

        // Check for complete HTTP request
        if (std.mem.indexOf(u8, client.*.data.items, "\r\n\r\n")) |_| {
            // Simple HTTP method detection
            const is_put = std.mem.startsWith(u8, client.*.data.items, "PUT /block");
            const is_get = std.mem.startsWith(u8, client.*.data.items, "GET /block/");
            const is_delete = std.mem.startsWith(u8, client.*.data.items, "DELETE /block/");

            if (is_put) {
                try self.handlePutRequest(client_id);
                return;
            } else if (is_get) {
                try self.handleGetRequest(client_id);
                return;
            } else if (is_delete) {
                try self.handleDeleteRequest(client_id);
                return;
            } else {
                // Root handler
                const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 24\r\n\r\nFastBlock Storage Worker";
                _ = try posix.write(client.*.socket, response);
                client.*.reset();
                const read_user_data = (OP_READ << 32) | client_id;
                _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
                return;
            }
        } else {
            // Headers not complete, continue reading
            const read_user_data = (OP_READ << 32) | client_id;
            _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
            return;
        }
    }

    fn handleClientWrite(self: *HttpWorker, client_id: u64, result: i32) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        if (result < 0) {
            self.closeClient(client_id);
            return;
        }

        if (!client.*.keep_alive) {
            self.closeClient(client_id);
            return;
        }

        // Reset for next request
        client.*.reset();

        // Submit next read
        const read_user_data = (OP_READ << 32) | client_id;
        _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
    }

    fn handlePutRequest(self: *HttpWorker, client_id: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;
        const request = client.*.data.items;

        // Find body (after \r\n\r\n)
        const body_start = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try self.sendErrorResponse(client_id, .invalid_size);
            return;
        };
        const body = request[body_start + 4 ..];

        if (body.len == 0) {
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 10\r\n\r\nEmpty body";
            _ = try posix.write(client.*.socket, response);
            self.closeClient(client_id);
            return;
        }

        // Check size limit (512KB)
        if (body.len > 524288) {
            const response = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 28\r\n\r\nPayload too large (max 512KB)";
            _ = try posix.write(client.*.socket, response);
            self.closeClient(client_id);
            return;
        }

        // Compute SHA256 hash
        var hash: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(body);
        hasher.final(&hash);

        // Send occupy request to Controller
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const msg = messages.Message{
            .occupy_block = .{
                .worker_id = self.id,
                .request_id = request_id,
                .hash = hash,
                .data_size = body.len,
            },
        };

        _ = self.to_controller.push(msg);

        // Save pending request with hash and body pointer
        try self.pending_requests.put(request_id, .{
            .request_id = request_id,
            .client_id = client_id,
            .request_type = .occupy,
            .hash = hash,
        });
    }

    fn handleGetRequest(self: *HttpWorker, client_id: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;
        const request = client.*.data.items;

        // Extract hash from path: GET /block/<hash>
        const path_start = std.mem.indexOf(u8, request, "GET /block/") orelse return error.InvalidRequest;
        const path_offset = path_start + "GET /block/".len;

        var hash_end = path_offset;
        while (hash_end < request.len and request[hash_end] != ' ' and request[hash_end] != '\r') : (hash_end += 1) {}

        const hash_hex = request[path_offset..hash_end];
        if (hash_hex.len != 64) {
            try self.sendErrorResponse(client_id, .invalid_size);
            return;
        }

        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch {
            try self.sendErrorResponse(client_id, .invalid_size);
            return;
        };

        // Send get_address request to Controller
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const msg = messages.Message{
            .get_address = .{
                .worker_id = self.id,
                .request_id = request_id,
                .hash = hash,
            },
        };

        _ = self.to_controller.push(msg);

        // Save pending request
        try self.pending_requests.put(request_id, .{
            .request_id = request_id,
            .client_id = client_id,
            .request_type = .get_address,
        });
    }

    fn handleDeleteRequest(self: *HttpWorker, client_id: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;
        const request = client.*.data.items;

        // Extract hash from path: DELETE /block/<hash>
        const path_start = std.mem.indexOf(u8, request, "DELETE /block/") orelse return error.InvalidRequest;
        const path_offset = path_start + "DELETE /block/".len;

        var hash_end = path_offset;
        while (hash_end < request.len and request[hash_end] != ' ' and request[hash_end] != '\r') : (hash_end += 1) {}

        const hash_hex = request[path_offset..hash_end];
        if (hash_hex.len != 64) {
            try self.sendErrorResponse(client_id, .invalid_size);
            return;
        }

        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch {
            try self.sendErrorResponse(client_id, .invalid_size);
            return;
        };

        // Send release request to Controller
        const request_id = self.next_request_id;
        self.next_request_id += 1;

        const msg = messages.Message{
            .release_block = .{
                .worker_id = self.id,
                .request_id = request_id,
                .hash = hash,
            },
        };

        _ = self.to_controller.push(msg);

        // Save pending request
        try self.pending_requests.put(request_id, .{
            .request_id = request_id,
            .client_id = client_id,
            .request_type = .release,
            .hash = hash,
        });
    }

    fn startFileTransfer(self: *HttpWorker, client_id: u64, offset: u64, size: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        const transfer_id = self.next_transfer_id;
        self.next_transfer_id += 1;

        const transfer = try self.allocator.create(FileTransfer);
        const buffer = try self.allocator.alloc(u8, 4096);

        transfer.* = .{
            .client_id = client_id,
            .file_fd = self.file_fd,
            .socket_fd = client.*.socket,
            .file_offset = offset,
            .remaining = size,
            .buffer = buffer,
            .allocator = self.allocator,
            .header_sent = false,
        };

        try self.file_transfers.put(transfer_id, transfer);

        // Submit file read
        const chunk_size = @min(size, buffer.len);
        const read_user_data = (OP_FILE_READ << 32) | transfer_id;
        _ = try self.ring.read(read_user_data, self.file_fd, .{ .buffer = buffer[0..chunk_size] }, offset);
    }

    fn handleFileRead(self: *HttpWorker, transfer_id: u64, result: i32) !void {
        const transfer = self.file_transfers.get(transfer_id) orelse return;

        if (result <= 0) {
            self.cleanupFileTransfer(transfer_id);
            return;
        }

        const bytes_read: usize = @intCast(result);

        // Send header if not sent
        if (!transfer.header_sent) {
            const header = try std.fmt.allocPrint(
                self.allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n",
                .{transfer.remaining},
            );
            defer self.allocator.free(header);

            _ = try posix.write(transfer.socket_fd, header);
            transfer.header_sent = true;
        }

        // Update state
        transfer.remaining -= bytes_read;
        transfer.file_offset += bytes_read;

        // Submit socket write
        const write_user_data = (OP_FILE_WRITE << 32) | transfer_id;
        _ = try self.ring.write(write_user_data, transfer.socket_fd, transfer.buffer[0..bytes_read], 0);
    }

    fn handleFileWrite(self: *HttpWorker, transfer_id: u64, result: i32) !void {
        const transfer = self.file_transfers.get(transfer_id) orelse return;

        if (result <= 0) {
            self.cleanupFileTransfer(transfer_id);
            return;
        }

        if (transfer.remaining > 0) {
            // Read next chunk
            const chunk_size = @min(transfer.remaining, transfer.buffer.len);
            const read_user_data = (OP_FILE_READ << 32) | transfer_id;
            _ = try self.ring.read(read_user_data, self.file_fd, .{ .buffer = transfer.buffer[0..chunk_size] }, transfer.file_offset);
        } else {
            // Transfer complete
            const client_id = transfer.client_id;
            self.cleanupFileTransfer(transfer_id);

            const client = self.clients.getPtr(client_id) orelse return;

            if (!client.*.keep_alive) {
                self.closeClient(client_id);
                return;
            }

            // Reset and read next request
            client.*.reset();
            const read_user_data = (OP_READ << 32) | client_id;
            _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
        }
    }

    fn cleanupFileTransfer(self: *HttpWorker, transfer_id: u64) void {
        if (self.file_transfers.fetchRemove(transfer_id)) |entry| {
            const client_id = entry.value.client_id;
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.closeClient(client_id);
        }
    }

    fn handlePutWrite(self: *HttpWorker, put_write_id: u64, result: i32) !void {
        const put_write = self.put_writes.get(put_write_id) orelse return;

        if (result < 0) {
            // Write failed - send error
            try self.sendErrorResponse(put_write.client_id, .internal_error);
            self.cleanupPutWrite(put_write_id);
            return;
        }

        const bytes_written: usize = @intCast(result);
        if (bytes_written != put_write.data.len) {
            // Partial write - send error
            try self.sendErrorResponse(put_write.client_id, .internal_error);
            self.cleanupPutWrite(put_write_id);
            return;
        }

        // Write successful - send hash to client
        try self.sendPutSuccessResponse(put_write.client_id, put_write.hash);
        self.cleanupPutWrite(put_write_id);
    }

    fn cleanupPutWrite(self: *HttpWorker, put_write_id: u64) void {
        if (self.put_writes.fetchRemove(put_write_id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }

    fn closeClient(self: *HttpWorker, client_id: u64) void {
        if (self.clients.fetchRemove(client_id)) |entry| {
            posix.close(entry.value.socket);
            entry.value.deinit();
            self.allocator.free(entry.value.buffer);
            self.allocator.destroy(entry.value);
        }
    }

    fn sendErrorResponse(self: *HttpWorker, client_id: u64, error_code: messages.ErrorCode) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        const response = switch (error_code) {
            .block_not_found => "HTTP/1.1 404 Not Found\r\nContent-Length: 15\r\n\r\nBlock not found",
            .allocation_failed => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 18\r\n\r\nAllocation failed",
            .invalid_size => "HTTP/1.1 400 Bad Request\r\nContent-Length: 12\r\n\r\nInvalid size",
            .internal_error => "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 14\r\n\r\nInternal error",
        };

        _ = try posix.write(client.*.socket, response);
        self.closeClient(client_id);
    }

    fn sendPutSuccessResponse(self: *HttpWorker, client_id: u64, hash: [32]u8) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        // Convert hash to hex
        const hex_hash = std.fmt.bytesToHex(hash, std.fmt.Case.lower);

        // Send response with hash
        const response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ hex_hash.len, hex_hash },
        );
        defer self.allocator.free(response);

        _ = try posix.write(client.*.socket, response);

        if (!client.*.keep_alive) {
            self.closeClient(client_id);
        } else {
            client.*.reset();
            const read_user_data = (OP_READ << 32) | client_id;
            _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
        }
    }

    fn sendDeleteSuccessResponse(self: *HttpWorker, client_id: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        const response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nBlock deleted";
        _ = try posix.write(client.*.socket, response);

        if (!client.*.keep_alive) {
            self.closeClient(client_id);
        } else {
            client.*.reset();
            const read_user_data = (OP_READ << 32) | client_id;
            _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
        }
    }
};

/// Mock Worker для тестов
pub const MockWorker = struct {
    run_called: bool = false,
    shutdown_called: bool = false,

    pub fn init() MockWorker {
        return .{};
    }

    pub fn run(self: *MockWorker) !void {
        self.run_called = true;
    }

    pub fn shutdown(self: *MockWorker) void {
        self.shutdown_called = true;
    }
};

fn createServerSocket(port: u16) !posix.fd_t {
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    const yes: i32 = 1;
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&yes));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&yes));

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &address.any, address.getOsSockLen());
    try posix.listen(socket, 1024);

    return socket;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const message_queue = @import("../messaging/message_queue.zig");
const block_pool = @import("block_pool.zig");

test "MockWorker - basic functionality" {
    var mock = MockWorker.init();

    try testing.expect(!mock.run_called);
    try testing.expect(!mock.shutdown_called);

    try mock.run();
    try testing.expect(mock.run_called);

    mock.shutdown();
    try testing.expect(mock.shutdown_called);
}

test "HttpWorker - refillPools отправляет allocate запросы" {
    // Настраиваем mock пулы (некоторые нуждаются в refill)
    var pools_mock: [8]block_pool.MockBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_mock, 0..) |*pool, i| {
        pool.* = block_pool.MockBlockPool.init(testing.allocator, @intCast(i));
        // Пулы 0, 2, 5 нуждаются в пополнении
        if (i == 0 or i == 2 or i == 5) {
            pool.needs_refill_response = true;
        } else {
            pool.needs_refill_response = false;
        }
        pools[i] = pool.interface();
    }
    defer for (&pools_mock) |*pool| pool.deinit();

    // Mock очереди
    var to_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer to_controller_mock.deinit();
    var from_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer from_controller_mock.deinit();

    // Создаем worker (без реального socket и io_uring)
    // Для теста нам нужен только частичный init
    var worker = HttpWorker{
        .id = 0,
        .allocator = testing.allocator,
        .ring = undefined, // Не используется в refillPools
        .server_socket = undefined,
        .clients = std.AutoHashMap(u64, *Client).init(testing.allocator),
        .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(testing.allocator),
        .put_writes = std.AutoHashMap(u64, *PutWrite).init(testing.allocator),
        .next_client_id = 1,
        .next_transfer_id = 1,
        .next_put_write_id = 1,
        .file_fd = undefined,
        .port = 10001,
        .block_pools = pools,
        .to_controller = to_controller_mock.interface(),
        .from_controller = from_controller_mock.interface(),
        .pending_requests = std.AutoHashMap(u64, PendingRequest).init(testing.allocator),
        .next_request_id = 1,
        .before_run = 0,
        .cycle_interval_ns = 100_000,
        .running = std.atomic.Value(bool).init(true),
    };
    defer worker.clients.deinit();
    defer worker.file_transfers.deinit();
    defer worker.put_writes.deinit();
    defer worker.pending_requests.deinit();

    // Вызываем refillPools
    try worker.refillPools();

    // Проверяем что отправлены allocate запросы для пулов 0, 2, 5
    try testing.expectEqual(@as(usize, 3), to_controller_mock.interface().len());

    // Проверяем содержимое сообщений
    var msg: messages.Message = undefined;

    try testing.expect(to_controller_mock.interface().pop(&msg));
    try testing.expectEqual(std.meta.Tag(messages.Message).allocate_block, std.meta.activeTag(msg));
    try testing.expectEqual(@as(u8, 0), msg.allocate_block.size);

    try testing.expect(to_controller_mock.interface().pop(&msg));
    try testing.expectEqual(@as(u8, 2), msg.allocate_block.size);

    try testing.expect(to_controller_mock.interface().pop(&msg));
    try testing.expectEqual(@as(u8, 5), msg.allocate_block.size);
}

test "HttpWorker - checkControllerMessages обрабатывает allocate_result" {
    var pools_mock: [8]block_pool.MockBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_mock, 0..) |*pool, i| {
        pool.* = block_pool.MockBlockPool.init(testing.allocator, @intCast(i));
        pools[i] = pool.interface();
    }
    defer for (&pools_mock) |*pool| pool.deinit();

    var to_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer to_controller_mock.deinit();
    var from_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer from_controller_mock.deinit();

    var worker = HttpWorker{
        .id = 0,
        .allocator = testing.allocator,
        .ring = undefined,
        .server_socket = undefined,
        .clients = std.AutoHashMap(u64, *Client).init(testing.allocator),
        .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(testing.allocator),
        .put_writes = std.AutoHashMap(u64, *PutWrite).init(testing.allocator),
        .next_client_id = 1,
        .next_transfer_id = 1,
        .next_put_write_id = 1,
        .file_fd = undefined,
        .port = 10001,
        .block_pools = pools,
        .to_controller = to_controller_mock.interface(),
        .from_controller = from_controller_mock.interface(),
        .pending_requests = std.AutoHashMap(u64, PendingRequest).init(testing.allocator),
        .next_request_id = 1,
        .before_run = 0,
        .cycle_interval_ns = 100_000,
        .running = std.atomic.Value(bool).init(true),
    };
    defer worker.clients.deinit();
    defer worker.file_transfers.deinit();
    defer worker.put_writes.deinit();
    defer worker.pending_requests.deinit();

    // Отправляем allocate_result в очередь from_controller
    const allocate_msg = messages.Message{
        .allocate_result = .{
            .worker_id = 0,
            .request_id = 1,
            .offset = 4096,
            .size = 2,
            .block_num = 100,
        },
    };
    _ = from_controller_mock.interface().push(allocate_msg);

    // Вызываем checkControllerMessages
    try worker.checkControllerMessages();

    // Проверяем что блок добавлен в пул размера 2
    const block_from_pool = pools[2].acquire();
    try testing.expect(block_from_pool != null);
    try testing.expectEqual(@as(u64, 4096), block_from_pool.?.offset);
    try testing.expectEqual(@as(u64, 100), block_from_pool.?.block_num);
}

test "HttpWorker - checkControllerMessages обрабатывает error_result" {
    var pools_mock: [8]block_pool.MockBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_mock, 0..) |*pool, i| {
        pool.* = block_pool.MockBlockPool.init(testing.allocator, @intCast(i));
        pools[i] = pool.interface();
    }
    defer for (&pools_mock) |*pool| pool.deinit();

    var to_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer to_controller_mock.deinit();
    var from_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer from_controller_mock.deinit();

    var worker = HttpWorker{
        .id = 0,
        .allocator = testing.allocator,
        .ring = undefined,
        .server_socket = undefined,
        .clients = std.AutoHashMap(u64, *Client).init(testing.allocator),
        .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(testing.allocator),
        .put_writes = std.AutoHashMap(u64, *PutWrite).init(testing.allocator),
        .next_client_id = 1,
        .next_transfer_id = 1,
        .next_put_write_id = 1,
        .file_fd = undefined,
        .port = 10001,
        .block_pools = pools,
        .to_controller = to_controller_mock.interface(),
        .from_controller = from_controller_mock.interface(),
        .pending_requests = std.AutoHashMap(u64, PendingRequest).init(testing.allocator),
        .next_request_id = 1,
        .before_run = 0,
        .cycle_interval_ns = 100_000,
        .running = std.atomic.Value(bool).init(true),
    };
    defer worker.clients.deinit();
    defer worker.file_transfers.deinit();
    defer worker.put_writes.deinit();
    defer worker.pending_requests.deinit();

    // Добавляем pending request
    try worker.pending_requests.put(42, .{
        .request_id = 42,
        .client_id = 1,
        .request_type = .get_address,
    });

    // Отправляем error_result
    const error_msg = messages.Message{
        .error_result = .{
            .worker_id = 0,
            .request_id = 42,
            .code = .block_not_found,
        },
    };
    _ = from_controller_mock.interface().push(error_msg);

    // Вызываем checkControllerMessages
    try worker.checkControllerMessages();

    // Проверяем что pending request удален
    try testing.expect(worker.pending_requests.get(42) == null);
}

test "HttpWorker - pending requests добавление и удаление" {
    var pools_mock: [8]block_pool.MockBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_mock, 0..) |*pool, i| {
        pool.* = block_pool.MockBlockPool.init(testing.allocator, @intCast(i));
        pools[i] = pool.interface();
    }
    defer for (&pools_mock) |*pool| pool.deinit();

    var to_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer to_controller_mock.deinit();
    var from_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer from_controller_mock.deinit();

    var worker = HttpWorker{
        .id = 0,
        .allocator = testing.allocator,
        .ring = undefined,
        .server_socket = undefined,
        .clients = std.AutoHashMap(u64, *Client).init(testing.allocator),
        .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(testing.allocator),
        .put_writes = std.AutoHashMap(u64, *PutWrite).init(testing.allocator),
        .next_client_id = 1,
        .next_transfer_id = 1,
        .next_put_write_id = 1,
        .file_fd = undefined,
        .port = 10001,
        .block_pools = pools,
        .to_controller = to_controller_mock.interface(),
        .from_controller = from_controller_mock.interface(),
        .pending_requests = std.AutoHashMap(u64, PendingRequest).init(testing.allocator),
        .next_request_id = 1,
        .before_run = 0,
        .cycle_interval_ns = 100_000,
        .running = std.atomic.Value(bool).init(true),
    };
    defer worker.clients.deinit();
    defer worker.file_transfers.deinit();
    defer worker.put_writes.deinit();
    defer worker.pending_requests.deinit();

    // Добавляем несколько pending requests
    try worker.pending_requests.put(1, .{
        .request_id = 1,
        .client_id = 100,
        .request_type = .allocate,
    });

    try worker.pending_requests.put(2, .{
        .request_id = 2,
        .client_id = 200,
        .request_type = .get_address,
    });

    try worker.pending_requests.put(3, .{
        .request_id = 3,
        .client_id = 300,
        .request_type = .release,
    });

    // Проверяем что все добавлены
    try testing.expectEqual(@as(usize, 3), worker.pending_requests.count());

    const req1 = worker.pending_requests.get(1).?;
    try testing.expectEqual(@as(u64, 100), req1.client_id);
    try testing.expectEqual(PendingRequest.RequestType.allocate, req1.request_type);

    const req2 = worker.pending_requests.get(2).?;
    try testing.expectEqual(@as(u64, 200), req2.client_id);
    try testing.expectEqual(PendingRequest.RequestType.get_address, req2.request_type);

    // Удаляем один
    _ = worker.pending_requests.remove(2);
    try testing.expectEqual(@as(usize, 2), worker.pending_requests.count());
    try testing.expect(worker.pending_requests.get(2) == null);
}

test "HttpWorker - multiple refillPools calls не дублируют запросы" {
    var pools_mock: [8]block_pool.MockBlockPool = undefined;
    var pools: [8]IBlockPool = undefined;
    for (&pools_mock, 0..) |*pool, i| {
        pool.* = block_pool.MockBlockPool.init(testing.allocator, @intCast(i));
        // Только пул 0 нуждается в refill
        pool.needs_refill_response = (i == 0);
        pools[i] = pool.interface();
    }
    defer for (&pools_mock) |*pool| pool.deinit();

    var to_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer to_controller_mock.deinit();
    var from_controller_mock = message_queue.MockMessageQueue.init(testing.allocator);
    defer from_controller_mock.deinit();

    var worker = HttpWorker{
        .id = 0,
        .allocator = testing.allocator,
        .ring = undefined,
        .server_socket = undefined,
        .clients = std.AutoHashMap(u64, *Client).init(testing.allocator),
        .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(testing.allocator),
        .put_writes = std.AutoHashMap(u64, *PutWrite).init(testing.allocator),
        .next_client_id = 1,
        .next_transfer_id = 1,
        .next_put_write_id = 1,
        .file_fd = undefined,
        .port = 10001,
        .block_pools = pools,
        .to_controller = to_controller_mock.interface(),
        .from_controller = from_controller_mock.interface(),
        .pending_requests = std.AutoHashMap(u64, PendingRequest).init(testing.allocator),
        .next_request_id = 1,
        .before_run = 0,
        .cycle_interval_ns = 100_000,
        .running = std.atomic.Value(bool).init(true),
    };
    defer worker.clients.deinit();
    defer worker.file_transfers.deinit();
    defer worker.put_writes.deinit();
    defer worker.pending_requests.deinit();

    // Первый вызов refillPools
    try worker.refillPools();
    try testing.expectEqual(@as(usize, 1), to_controller_mock.interface().len());

    // Второй вызов refillPools (пул все еще нуждается в refill)
    try worker.refillPools();
    try testing.expectEqual(@as(usize, 2), to_controller_mock.interface().len());

    // Проверяем что оба запроса имеют разные request_id
    var msg1: messages.Message = undefined;
    var msg2: messages.Message = undefined;
    try testing.expect(to_controller_mock.interface().pop(&msg1));
    try testing.expect(to_controller_mock.interface().pop(&msg2));

    try testing.expect(msg1.allocate_block.request_id != msg2.allocate_block.request_id);
}
