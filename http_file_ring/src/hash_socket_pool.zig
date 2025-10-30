const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const HashSocketPool = struct {
    allocator: std.mem.Allocator,
    free_sockets: std.ArrayList(i32),
    mutex: std.Thread.Mutex,
    total_created: std.atomic.Value(u32),

    const SOFT_LIMIT = 100;
    const HARD_LIMIT = 256;

    pub fn init(allocator: std.mem.Allocator) HashSocketPool {
        return .{
            .allocator = allocator,
            .free_sockets = .{},
            .mutex = .{},
            .total_created = std.atomic.Value(u32).init(0),
        };
    }

    pub fn acquire(self: *HashSocketPool) !i32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Сначала пытаемся взять из пула
        if (self.free_sockets.items.len > 0) {
            return self.free_sockets.pop() orelse unreachable; // Не может быть null если len > 0
        }

        // Проверяем лимиты
        const current = self.total_created.load(.monotonic);
        if (current >= HARD_LIMIT) {
            std.debug.print("ERROR: Hash socket pool exhausted! ({d}/{d})\n", .{ current, HARD_LIMIT });
            return error.PoolExhausted;
        }

        if (current >= SOFT_LIMIT) {
            std.debug.print("WARNING: Hash socket pool approaching limit ({d}/{d})\n", .{ current, HARD_LIMIT });
        }

        // Создаем новый
        const fd = try createHashSocket();
        _ = self.total_created.fetchAdd(1, .monotonic);
        return fd;
    }

    pub fn release(self: *HashSocketPool, fd: i32) void {
        // AF_ALG socket нельзя переиспользовать после вычисления хеша
        // Закрываем старый socket вместо возврата в пул
        posix.close(fd);

        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.total_created.fetchSub(1, .monotonic);
    }

    pub fn deinit(self: *HashSocketPool) void {
        for (self.free_sockets.items) |fd| {
            posix.close(fd);
        }
        self.free_sockets.deinit(self.allocator);
    }
};

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
