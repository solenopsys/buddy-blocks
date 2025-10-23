const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

pub const Ring = struct {
    ring: IoUring,

    pub fn init(entries: u13) !Ring {
        return Ring{
            .ring = try IoUring.init(entries, 0),
        };
    }

    pub fn deinit(self: *Ring) void {
        self.ring.deinit();
    }

    /// Отправить операции в ядро
    pub fn submit(self: *Ring) !u32 {
        return try self.ring.submit();
    }

    /// Ждать и получить completion event
    pub fn waitCqe(self: *Ring) !linux.io_uring_cqe {
        return try self.ring.copy_cqe();
    }

    /// Accept connection
    pub fn queueAccept(self: *Ring, fd: i32, addr: *posix.sockaddr, addrlen: *posix.socklen_t, user_data: u64) !void {
        _ = try self.ring.accept(user_data, fd, addr, addrlen, 0);
    }

    /// Recv data
    pub fn queueRecv(self: *Ring, fd: i32, buffer: []u8, user_data: u64) !void {
        _ = try self.ring.recv(user_data, fd, .{ .buffer = buffer }, 0);
    }

    /// Splice data
    pub fn queueSplice(self: *Ring, fd_in: i32, off_in: i64, fd_out: i32, off_out: i64, len: u32, user_data: u64) !void {
        const off_in_u64 = if (off_in < 0) std.math.maxInt(u64) else @as(u64, @intCast(off_in));
        const off_out_u64 = if (off_out < 0) std.math.maxInt(u64) else @as(u64, @intCast(off_out));
        _ = try self.ring.splice(user_data, fd_in, off_in_u64, fd_out, off_out_u64, len);
    }

    /// Tee data (split pipe) - нет в stdlib, делаем вручную
    pub fn queueTee(self: *Ring, fd_in: i32, fd_out: i32, len: u32, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        sqe.* = .{
            .opcode = .TEE,
            .flags = 0,
            .ioprio = 0,
            .fd = fd_out,
            .off = 0,
            .addr = 0,
            .len = len,
            .rw_flags = 0,
            .user_data = user_data,
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = fd_in,
            .addr3 = 0,
            .resv = 0,
        };
    }

    /// Read data
    pub fn queueRead(self: *Ring, fd: i32, buffer: []u8, offset: u64, user_data: u64) !void {
        _ = try self.ring.read(user_data, fd, .{ .buffer = buffer }, offset);
    }
};
