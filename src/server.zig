const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const picozig = @import("picozig").picozig;
const httpHandler = @import("./http-hendler.zig").httpHandler;

// Глобальные счётчики для профилирования
var total_handler_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub const ServerConfig = struct {
    port: u16,
    num_workers: usize,
};

const LocalBufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList([]u8),

    pub fn init(allocator: Allocator, initial_size: usize, buffer_size: usize) !LocalBufferPool {
        var buffers = try std.ArrayList([]u8).initCapacity(allocator, initial_size);
        for (0..initial_size) |_| {
            const buffer = try allocator.alloc(u8, buffer_size);
            try buffers.append(allocator, buffer);
        }
        return LocalBufferPool{ .allocator = allocator, .buffers = buffers };
    }

    pub fn deinit(self: *LocalBufferPool) void {
        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit(self.allocator);
    }

    pub fn getBuffer(self: *LocalBufferPool, buffer_size: usize) ![]u8 {
        if (self.buffers.items.len > 0) {
            return self.buffers.pop() orelse error.BufferNotAvailable;
        }
        return try self.allocator.alloc(u8, buffer_size);
    }

    pub fn returnBuffer(self: *LocalBufferPool, buffer: []u8) !void {
        try self.buffers.append(self.allocator, buffer);
    }
};

const Client = struct {
    socket: posix.fd_t,
    buffer: []u8,
    data: std.ArrayList(u8),
    is_complete: bool,
    keep_alive: bool,
    allocator: Allocator,

    pub fn init(socket: posix.fd_t, buffer: []u8, allocator: Allocator) Client {
        return Client{
            .socket = socket,
            .buffer = buffer,
            .data = std.ArrayList(u8).empty,
            .is_complete = false,
            .keep_alive = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Client, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn reset(self: *Client) void {
        self.data.clearRetainingCapacity();
        self.is_complete = false;
    }
};

const Worker = struct {
    id: usize,
    allocator: Allocator,
    server_socket: posix.fd_t,
    ring: linux.IoUring,
    clients: std.AutoHashMap(u64, Client),
    next_client_id: u64,
    buffer_pool: LocalBufferPool,
    buffer_size: usize,

    pub fn init(allocator: Allocator, id: usize, port: u16, buffer_size: usize, initial_pool_size: usize) !Worker {
        const server_socket = try createServerSocket(port);

        const ring_size: u13 = 256;
        const ring = try linux.IoUring.init(ring_size, 0);
        const buffer_pool = try LocalBufferPool.init(allocator, initial_pool_size, buffer_size);

        return Worker{
            .id = id,
            .allocator = allocator,
            .server_socket = server_socket,
            .ring = ring,
            .clients = std.AutoHashMap(u64, Client).init(allocator),
            .next_client_id = 1,
            .buffer_pool = buffer_pool,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Worker) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            posix.close(entry.value_ptr.socket);
            entry.value_ptr.deinit(self.allocator);
            self.buffer_pool.returnBuffer(entry.value_ptr.buffer) catch {};
        }
        self.clients.deinit();
        self.ring.deinit();
        self.buffer_pool.deinit();
        posix.close(self.server_socket);
    }

    pub fn run(self: *Worker) !void {
        std.debug.print("Worker {d} started\n", .{self.id});
        const accept_user_data: u64 = 0;
        _ = try self.ring.accept(accept_user_data, self.server_socket, null, null, 0);

        while (true) {
            const submitted = self.ring.submit_and_wait(1) catch |err| {
                std.debug.print("Worker {d}: submit_and_wait error: {any}\n", .{ self.id, err });
                continue;
            };
            _ = submitted;

            while (self.ring.cq_ready() > 0) {
                const cqe = self.ring.copy_cqe() catch |err| {
                    std.debug.print("Worker {d}: copy_cqe error: {any}\n", .{ self.id, err });
                    continue;
                };

                if (cqe.user_data == 0) {
                    self.handleAccept(cqe.res) catch |err| {
                        std.debug.print("Worker {d}: handleAccept error: {any}\n", .{ self.id, err });
                    };
                    _ = self.ring.accept(accept_user_data, self.server_socket, null, null, 0) catch |err| {
                        std.debug.print("Worker {d}: accept registration error: {any}\n", .{ self.id, err });
                    };
                } else {
                    // Определяем тип операции
                    const op_type = cqe.user_data >> 32;
                    const client_id = cqe.user_data & 0xFFFFFFFF;

                    if (op_type == 1) { // Операция чтения
                        self.handleClientRead(client_id, cqe.res) catch |err| {
                            std.debug.print("Worker {d}: handleClientRead error: {any}\n", .{ self.id, err });
                        };
                    } else if (op_type == 2) { // Операция записи
                        self.handleClientWrite(client_id, cqe.res) catch |err| {
                            std.debug.print("Worker {d}: handleClientWrite error: {any}\n", .{ self.id, err });
                        };
                    }
                }
            }
        }
    }

    fn handleAccept(self: *Worker, result: i32) !void {
        if (result < 0) {
            std.debug.print("Worker {d}: accept error: {d}\n", .{ self.id, result });
            return;
        }

        const client_socket: i32 = @intCast(result);
        const buffer = try self.buffer_pool.getBuffer(self.buffer_size);

        const client_id = self.next_client_id & 0xFFFFFFFF;
        self.next_client_id += 1;

        const client = Client.init(client_socket, buffer, self.allocator);
        try self.clients.put(client_id, client);

        // Начинаем чтение
        const read_user_data = (1 << 32) | client_id;
        _ = self.ring.read(read_user_data, client_socket, .{ .buffer = buffer }, 0) catch |err| {
            std.debug.print("Worker {d}: read registration error: {any}\n", .{ self.id, err });
            self.closeClient(client_id);
        };
    }

    fn handleClientRead(self: *Worker, client_id: u64, result: i32) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        if (result <= 0) {
            self.closeClient(client_id);
            return;
        }

        const bytes_read: usize = @intCast(result);
        try client.data.appendSlice(client.allocator, client.buffer[0..bytes_read]);

        // Проверяем полный HTTP запрос (конец заголовков)
        if (!client.is_complete) {
            if (std.mem.indexOf(u8, client.data.items, "\r\n\r\n")) |header_end| {
                // Нашли конец заголовков
                const headers = client.data.items[0..header_end];

                // Проверяем это PUT /block, GET /block или DELETE /block
                const is_put_block = std.mem.startsWith(u8, client.data.items, "PUT /block");
                const is_get_block = std.mem.startsWith(u8, client.data.items, "GET /block/");
                const is_delete_block = std.mem.startsWith(u8, client.data.items, "DELETE /block/");

                // Для DELETE /block не ждем body - сразу обрабатываем
                if (is_delete_block) {
                    client.is_complete = true;
                    // Продолжаем обработку через httpHandler ниже
                } else if (is_put_block) {
                    if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_start| {
                        const cl_line_start = cl_start + "Content-Length:".len;
                        if (std.mem.indexOf(u8, headers[cl_line_start..], "\r\n")) |cl_line_end| {
                            const cl_value = std.mem.trim(u8, headers[cl_line_start..][0..cl_line_end], " \t");
                            const content_length = std.fmt.parseInt(u64, cl_value, 10) catch 0;

                            if (content_length > 0) {
                                // Проверяем, сколько body уже прочитано
                                const body_start = header_end + 4;
                                const body_received = if (client.data.items.len > body_start)
                                    client.data.items.len - body_start
                                else
                                    0;

                                // Если body уже полностью прочитан, используем обычный handler
                                if (body_received >= content_length) {
                                    client.is_complete = true;
                                    // Продолжаем обработку через httpHandler ниже
                                } else {
                                    // Иначе используем streaming (но нужно учесть уже прочитанную часть!)
                                    // TODO: Сейчас просто читаем весь body
                                    const read_user_data = (1 << 32) | client_id;
                                    _ = try self.ring.read(read_user_data, client.socket, .{ .buffer = client.buffer }, 0);
                                    return;
                                }
                            }
                        }
                    }
                } else if (is_get_block) {
                    // Для GET /block используем streaming (не ждем body)
                    try self.handleGetStreaming(client_id);
                    return;
                }

                // Для остальных запросов продолжаем обычную логику (ждем body если есть Content-Length)
                if (!is_delete_block) {
                    if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_start| {
                    const cl_line_start = cl_start + "Content-Length:".len;
                    if (std.mem.indexOf(u8, headers[cl_line_start..], "\r\n")) |cl_line_end| {
                        const cl_value = std.mem.trim(u8, headers[cl_line_start..][0..cl_line_end], " \t");
                        const content_length = std.fmt.parseInt(usize, cl_value, 10) catch 0;
                        const body_start = header_end + 4;
                        const body_received = if (client.data.items.len > body_start)
                            client.data.items.len - body_start
                        else
                            0;

                        if (body_received < content_length) {
                            // Нужно читать больше данных для body
                            const read_user_data = (1 << 32) | client_id;
                            _ = try self.ring.read(read_user_data, client.socket, .{ .buffer = client.buffer }, 0);
                            return;
                        }
                    }
                    }
                }

                client.is_complete = true;
            } else {
                // Заголовки не полные, читаем дальше
                const read_user_data = (1 << 32) | client_id;
                _ = try self.ring.read(read_user_data, client.socket, .{ .buffer = client.buffer }, 0);
                return;
            }
        }

        const request = client.data.items;

        // Проверяем keep-alive
        client.keep_alive = true;
        if (std.mem.indexOf(u8, request, "Connection: close") != null) {
            client.keep_alive = false;
        } else if (std.mem.indexOf(u8, request, "HTTP/1.0") != null) {
            if (std.mem.indexOf(u8, request, "Connection: keep-alive") == null) {
                client.keep_alive = false;
            }
        }

        // Обрабатываем запрос
        var timer = std.time.Timer.start() catch unreachable;

        const response = httpHandler(self.allocator, request) catch |err| {
            std.debug.print("Handler error: {}\n", .{err});
            self.closeClient(client_id);
            return;
        };

        const elapsed = timer.read();
        _ = total_handler_time.fetchAdd(elapsed, .monotonic);
        const req_count = total_requests.fetchAdd(1, .monotonic) + 1;

        if (req_count % 10000 == 0) {
            const avg_ns = total_handler_time.load(.monotonic) / req_count;
            std.debug.print("Stats: {d} requests, avg handler time: {d} µs\n", .{ req_count, avg_ns / 1000 });
        }

        // Отправляем ответ
        const write_user_data = (2 << 32) | client_id;
        _ = try self.ring.write(write_user_data, client.socket, response, 0);
    }

    fn handleClientWrite(self: *Worker, client_id: u64, result: i32) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        if (result < 0) {
            std.debug.print("Worker {d}: write error for client {d}: {d}\n", .{ self.id, client_id, result });
            self.closeClient(client_id);
            return;
        }

        // Если клиент не хочет keep-alive, закрываем
        if (!client.keep_alive) {
            self.closeClient(client_id);
            return;
        }

        // Сбрасываем состояние для следующего запроса
        client.reset();

        // Начинаем читать следующий запрос
        const read_user_data = (1 << 32) | client_id;
        _ = try self.ring.read(read_user_data, client.socket, .{ .buffer = client.buffer }, 0);
    }

    fn handlePutStreaming(self: *Worker, client_id: u64, content_length: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        // Вызываем streaming handler
        const block_handlers = @import("./block_handlers.zig");
        const response = block_handlers.handlePutStreaming(
            client.socket,
            content_length,
            self.allocator,
        ) catch |err| {
            std.debug.print("Worker {d}: handlePutStreaming error: {any}\n", .{ self.id, err });
            self.closeClient(client_id);
            return;
        };

        // Отправляем ответ
        const write_user_data = (2 << 32) | client_id;
        _ = try self.ring.write(write_user_data, client.socket, response, 0);
    }

    fn handleGetStreaming(self: *Worker, client_id: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        // Извлекаем хеш из запроса: GET /block/<hash>
        const request = client.data.items;
        const path_start = std.mem.indexOf(u8, request, "GET /block/") orelse {
            self.closeClient(client_id);
            return;
        };
        const path_offset = path_start + "GET /block/".len;

        // Находим конец пути (пробел или \r\n)
        var hash_end = path_offset;
        while (hash_end < request.len and
               request[hash_end] != ' ' and
               request[hash_end] != '\r') : (hash_end += 1) {}

        const hash_hex = request[path_offset..hash_end];

        // Вызываем streaming handler
        const block_handlers = @import("./block_handlers.zig");
        _ = block_handlers.handleGetStreaming(
            client.socket,
            hash_hex,
            self.allocator,
        ) catch |err| {
            std.debug.print("Worker {d}: handleGetStreaming error: {any}\n", .{ self.id, err });
            self.closeClient(client_id);
            return;
        };

        // Данные уже отправлены через streaming, закрываем соединение
        if (!client.keep_alive) {
            self.closeClient(client_id);
            return;
        }

        // Сбрасываем состояние для следующего запроса
        client.reset();

        // Начинаем читать следующий запрос
        const read_user_data = (1 << 32) | client_id;
        _ = try self.ring.read(read_user_data, client.socket, .{ .buffer = client.buffer }, 0);
    }

    fn closeClient(self: *Worker, client_id: u64) void {
        const client_entry = self.clients.fetchRemove(client_id) orelse return;
        var client = client_entry.value;

        posix.close(client.socket);
        client.deinit(self.allocator);
        self.buffer_pool.returnBuffer(client.buffer) catch {
            std.debug.print("Worker {d}: buffer return error for client {d}\n", .{ self.id, client_id });
        };
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

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,

    pub fn init(allocator: std.mem.Allocator, port: u16, num_workers: usize) !Server {
        return Server{
            .allocator = allocator,
            .config = .{
                .port = port,
                .num_workers = num_workers,
            },
        };
    }

    pub fn deinit(self: *Server) void {
        _ = self;
    }

    pub fn start(self: *Server) !void {
        const buffer_size = 8192;
        const initial_pool_size = 256;

        var workers = try self.allocator.alloc(Worker, self.config.num_workers);
        defer {
            for (workers) |*worker| {
                worker.deinit();
            }
            self.allocator.free(workers);
        }

        const threads = try self.allocator.alloc(Thread, self.config.num_workers);
        defer self.allocator.free(threads);

        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.init(self.allocator, i, self.config.port, buffer_size, initial_pool_size);
        }

        for (threads, 0..) |*thread, i| {
            thread.* = try Thread.spawn(.{}, workerMain, .{&workers[i]});
        }

        std.debug.print("HTTP server started on port {d} with {d} workers\n", .{ self.config.port, self.config.num_workers });

        for (threads) |thread| {
            thread.join();
        }
    }
};

fn workerMain(worker: *Worker) void {
    worker.run() catch |err| {
        std.debug.print("Worker {d} error: {any}\n", .{ worker.id, err });
    };
}
