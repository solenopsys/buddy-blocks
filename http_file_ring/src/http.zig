const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const picozig = @import("picozig").picozig;
const Ring = @import("uring.zig").Ring;
const interfaces = @import("interfaces.zig");
const OpContext = interfaces.OpContext;
const OpType = interfaces.OpType;
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
        var addr: posix.sockaddr = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);

        const ctx = try self.allocator.create(OpContext);
        ctx.* = .{
            .op_type = .accept,
            .conn_fd = -1,
            .block_info = .{ .block_num = 0 },
            .content_length = 0,
            .hash = undefined,
        };

        try self.ring.queueAccept(self.socket, &addr, &addrlen, @intFromPtr(ctx));
        _ = try self.ring.submit();

        // Event loop
        while (true) {
            const cqe = try self.ring.waitCqe();
            const context = @as(*OpContext, @ptrFromInt(cqe.user_data));

            switch (context.op_type) {
                .accept => try self.handleAccept(cqe.res),
                .recv_header => try self.handleHeader(context, cqe.res),
                else => {},
            }
        }
    }

    fn handleAccept(self: *HttpServer, res: i32) !void {
        if (res < 0) return error.AcceptFailed;

        const conn_fd = res;
        const buffer = try self.allocator.alloc(u8, 8192);

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
        var addr: posix.sockaddr = undefined;
        var addrlen: posix.socklen_t = @sizeOf(posix.sockaddr);

        const accept_ctx = try self.allocator.create(OpContext);
        accept_ctx.* = .{
            .op_type = .accept,
            .conn_fd = -1,
            .block_info = .{ .block_num = 0 },
            .content_length = 0,
            .hash = undefined,
        };

        try self.ring.queueAccept(self.socket, &addr, &addrlen, @intFromPtr(accept_ctx));
        _ = try self.ring.submit();
    }

    fn handleHeader(self: *HttpServer, ctx: *OpContext, bytes_read: i32) !void {
        if (bytes_read <= 0) {
            posix.close(ctx.conn_fd);
            if (ctx.buffer) |buf| self.allocator.free(buf);
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

        _ = picozig.parseRequest(data, &httpRequest);

        // Получаем Content-Length
        const content_length = getContentLength(&httpRequest);
        if (content_length == 0) {
            posix.close(ctx.conn_fd);
            self.allocator.free(buffer);
            return;
        }

        ctx.content_length = content_length;

        // Запрашиваем блок у сервиса
        const block_info = self.service.onBlockInputRequest(0);
        ctx.block_info = block_info;

        // Создаем pipes для pipeline
        const pipes1 = try posix.pipe();
        const pipes2 = try posix.pipe();

        const pipe1_read = pipes1[0];
        const pipe1_write = pipes1[1];
        const pipe2_read = pipes2[0];
        const pipe2_write = pipes2[1];

        // Pipeline: splice(socket→pipe1)
        const splice_ctx = try self.allocator.create(OpContext);
        splice_ctx.* = .{
            .op_type = .splice_to_pipe,
            .conn_fd = ctx.conn_fd,
            .block_info = block_info,
            .content_length = content_length,
            .hash = undefined,
            .buffer = null,
        };

        const offset = block_info.block_num * 4096;
        try self.ring.queueSplice(ctx.conn_fd, -1, pipe1_write, -1, @intCast(content_length), @intFromPtr(splice_ctx));

        // tee(pipe1→pipe2)
        try self.ring.queueTee(pipe1_read, pipe2_write, @intCast(content_length), 0);

        // splice(pipe1→file)
        try self.file_storage.queueSplice(pipe1_read, offset, @intCast(content_length), 0);

        // splice(pipe2→hash_socket)
        try self.ring.queueSplice(pipe2_read, -1, self.hash_socket, -1, @intCast(content_length), 0);

        _ = try self.ring.submit();

        self.allocator.free(buffer);

        // TODO: read hash после завершения splice
        posix.close(pipe1_write);
        posix.close(pipe2_write);
    }
};

fn createSocket(port: u16) !posix.fd_t {
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    const yes: i32 = 1;
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&yes));

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &address.any, address.getOsSockLen());
    try posix.listen(socket, 128);

    return socket;
}

fn createHashSocket() !posix.fd_t {
    const AF_ALG = 38;
    const sock = try posix.socket(AF_ALG, posix.SOCK.SEQPACKET, 0);
    errdefer posix.close(sock);

    // struct sockaddr_alg
    var addr: [88]u8 = std.mem.zeroes([88]u8);
    addr[0] = AF_ALG; // sa_family (u16)
    addr[1] = 0;

    // salg_type = "hash"
    @memcpy(addr[2..6], "hash");

    // salg_name = "sha256"
    @memcpy(addr[66..72], "sha256");

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

