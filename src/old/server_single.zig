const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const picozig = @import("picozig").picozig;
const httpHandler = @import("./http-hendler.zig").httpHandler;
const BlockController = @import("./block_controller_adapter.zig").BlockController;

// Operation types in user_data (top 32 bits)
const OP_ACCEPT: u64 = 0;
const OP_READ: u64 = 1;
const OP_WRITE: u64 = 2;
const OP_FILE_READ: u64 = 3;
const OP_FILE_WRITE: u64 = 4;

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

pub const Server = struct {
    allocator: Allocator,
    ring: linux.IoUring,
    server_socket: posix.fd_t,
    clients: std.AutoHashMap(u64, *Client),
    file_transfers: std.AutoHashMap(u64, *FileTransfer),
    next_client_id: u64,
    next_transfer_id: u64,
    file_fd: posix.fd_t,
    block_controller: *BlockController,
    port: u16,

    pub fn init(
        allocator: Allocator,
        port: u16,
        file_fd: posix.fd_t,
        block_controller: *BlockController,
    ) !Server {
        const server_socket = try createServerSocket(port);
        errdefer posix.close(server_socket);

        const ring = try linux.IoUring.init(512, 0);
        errdefer ring.deinit();

        return .{
            .allocator = allocator,
            .ring = ring,
            .server_socket = server_socket,
            .clients = std.AutoHashMap(u64, *Client).init(allocator),
            .file_transfers = std.AutoHashMap(u64, *FileTransfer).init(allocator),
            .next_client_id = 1,
            .next_transfer_id = 1,
            .file_fd = file_fd,
            .block_controller = block_controller,
            .port = port,
        };
    }

    pub fn deinit(self: *Server) void {
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

        self.ring.deinit();
        posix.close(self.server_socket);
    }

    pub fn run(self: *Server) !void {
        std.debug.print("Single-threaded server started on port {d}\n", .{self.port});

        // Submit initial accept
        const accept_user_data = (OP_ACCEPT << 32) | 0;
        _ = try self.ring.accept(accept_user_data, self.server_socket, null, null, 0);

        while (true) {
            _ = try self.ring.submit_and_wait(1);

            while (self.ring.cq_ready() > 0) {
                const cqe = try self.ring.copy_cqe();

                const op_type = cqe.user_data >> 32;
                const id = cqe.user_data & 0xFFFFFFFF;

                if (op_type == OP_ACCEPT) {
                    self.handleAccept(cqe.res) catch |err| {
                        std.debug.print("Accept error: {any}\n", .{err});
                    };
                    // Re-submit accept
                    _ = self.ring.accept(accept_user_data, self.server_socket, null, null, 0) catch {};
                } else if (op_type == OP_READ) {
                    self.handleClientRead(id, cqe.res) catch |err| {
                        std.debug.print("Read error for client {d}: {any}\n", .{ id, err });
                    };
                } else if (op_type == OP_WRITE) {
                    self.handleClientWrite(id, cqe.res) catch |err| {
                        std.debug.print("Write error for client {d}: {any}\n", .{ id, err });
                    };
                } else if (op_type == OP_FILE_READ) {
                    self.handleFileRead(id, cqe.res) catch |err| {
                        std.debug.print("File read error for transfer {d}: {any}\n", .{ id, err });
                    };
                } else if (op_type == OP_FILE_WRITE) {
                    self.handleFileWrite(id, cqe.res) catch |err| {
                        std.debug.print("File write error for transfer {d}: {any}\n", .{ id, err });
                    };
                }
            }
        }
    }

    fn handleAccept(self: *Server, result: i32) !void {
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

    fn handleClientRead(self: *Server, client_id: u64, result: i32) !void {
        const client = self.clients.getPtr(client_id) orelse return;

        if (result <= 0) {
            self.closeClient(client_id);
            return;
        }

        const bytes_read: usize = @intCast(result);
        try client.*.data.appendSlice(client.*.allocator, client.*.buffer[0..bytes_read]);

        // Check for complete request
        if (std.mem.indexOf(u8, client.*.data.items, "\r\n\r\n")) |header_end| {
            // Parse headers
            var headers_buf: [32]picozig.Header = undefined;
            var http_request = picozig.HttpRequest{
                .params = .{
                    .method = "",
                    .path = "",
                    .minor_version = 0,
                    .num_headers = 0,
                    .bytes_read = 0,
                },
                .headers = &headers_buf,
                .body = "",
            };
            _ = picozig.parseRequest(client.*.data.items, &http_request);

            const is_get_block = std.mem.startsWith(u8, client.*.data.items, "GET /block/");

            if (is_get_block) {
                // Start async file transfer
                try self.startAsyncGetTransfer(client_id);
                return;
            }

            // For other requests, check Content-Length
            var content_length: ?u64 = null;
            for (headers_buf[0..http_request.params.num_headers]) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) {
                    content_length = std.fmt.parseInt(u64, header.value, 10) catch null;
                    break;
                }
            }

            const body_start = header_end + 4;
            const body_received = if (client.*.data.items.len > body_start)
                client.*.data.items.len - body_start
            else
                0;

            if (content_length) |cl| {
                if (body_received < cl) {
                    // Need more data
                    const read_user_data = (OP_READ << 32) | client_id;
                    _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
                    return;
                }
            }

            client.*.is_complete = true;
        } else {
            // Headers not complete, continue reading
            const read_user_data = (OP_READ << 32) | client_id;
            _ = try self.ring.read(read_user_data, client.*.socket, .{ .buffer = client.*.buffer }, 0);
            return;
        }

        // Process request
        const response = try httpHandler(self.allocator, client.*.data.items);

        // Check keep-alive
        client.*.keep_alive = true;
        if (std.mem.indexOf(u8, client.*.data.items, "Connection: close") != null) {
            client.*.keep_alive = false;
        }

        // Submit write
        const write_user_data = (OP_WRITE << 32) | client_id;
        _ = try self.ring.write(write_user_data, client.*.socket, response, 0);
    }

    fn handleClientWrite(self: *Server, client_id: u64, result: i32) !void {
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

    fn startAsyncGetTransfer(self: *Server, client_id: u64) !void {
        const client = self.clients.getPtr(client_id) orelse return;
        const request = client.*.data.items;

        // Extract hash from path
        const path_start = std.mem.indexOf(u8, request, "GET /block/") orelse return error.InvalidRequest;
        const path_offset = path_start + "GET /block/".len;

        var hash_end = path_offset;
        while (hash_end < request.len and request[hash_end] != ' ' and request[hash_end] != '\r') : (hash_end += 1) {}

        const hash_hex = request[path_offset..hash_end];
        if (hash_hex.len != 64) return error.InvalidHashLength;

        var hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash, hash_hex) catch return error.InvalidHexHash;

        // Get block metadata
        const buddy_mod = @import("buddy_allocator");
        const metadata = self.block_controller.buddy_allocator.getBlock(hash) catch |err| {
            const response = if (err == error.BlockNotFound)
                "HTTP/1.1 404 Not Found\r\nContent-Length: 15\r\n\r\nBlock not found"
            else
                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal server error";

            const write_user_data = (OP_WRITE << 32) | client_id;
            _ = try self.ring.write(write_user_data, client.*.socket, response, 0);
            return;
        };

        const offset = buddy_mod.BuddyAllocator.getOffset(metadata);
        const size = metadata.data_size;

        // Create transfer state
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

    fn handleFileRead(self: *Server, transfer_id: u64, result: i32) !void {
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

    fn handleFileWrite(self: *Server, transfer_id: u64, result: i32) !void {
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

    fn cleanupFileTransfer(self: *Server, transfer_id: u64) void {
        if (self.file_transfers.fetchRemove(transfer_id)) |entry| {
            const client_id = entry.value.client_id;
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.closeClient(client_id);
        }
    }

    fn closeClient(self: *Server, client_id: u64) void {
        if (self.clients.fetchRemove(client_id)) |entry| {
            posix.close(entry.value.socket);
            entry.value.deinit();
            self.allocator.free(entry.value.buffer);
            self.allocator.destroy(entry.value);
        }
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
