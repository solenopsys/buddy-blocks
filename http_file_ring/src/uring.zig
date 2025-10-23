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

    /// Получить SQE для новой операции
    pub fn getSqe(self: *Ring) !*linux.io_uring_sqe {
        return try self.ring.get_sqe();
    }

    /// Отправить операции в ядро
    pub fn submit(self: *Ring) !u32 {
        return try self.ring.submit();
    }

    /// Ждать и получить completion event
    pub fn waitCqe(self: *Ring) !linux.io_uring_cqe {
        return try self.ring.copy_cqe();
    }

    /// Пометить CQE как обработанный
    pub fn cqeSeen(self: *Ring, cqe: *linux.io_uring_cqe) void {
        self.ring.cqe_seen(cqe);
    }

    /// Accept connection
    pub fn queueAccept(self: *Ring, fd: i32, addr: *posix.sockaddr, addrlen: *posix.socklen_t, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.* = linux.io_uring_sqe{
            .opcode = .ACCEPT,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = 0,
            .addr = @intFromPtr(addr),
            .len = 0,
            .rw_flags = 0,
            .user_data = user_data,
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = 0,
            .addr3 = @intFromPtr(addrlen),
            .resv = 0,
        };
    }

    /// Recv data
    pub fn queueRecv(self: *Ring, fd: i32, buffer: []u8, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.* = linux.io_uring_sqe{
            .opcode = .RECV,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = 0,
            .addr = @intFromPtr(buffer.ptr),
            .len = @intCast(buffer.len),
            .rw_flags = 0,
            .user_data = user_data,
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = 0,
            .addr3 = 0,
            .resv = 0,
        };
    }

    /// Splice data
    pub fn queueSplice(self: *Ring, fd_in: i32, off_in: i64, fd_out: i32, off_out: i64, len: u32, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.* = linux.io_uring_sqe{
            .opcode = .SPLICE,
            .flags = 0,
            .ioprio = 0,
            .fd = fd_out,
            .off = @bitCast(off_out),
            .addr = 0,
            .len = len,
            .rw_flags = 0,
            .user_data = user_data,
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = fd_in,
            .addr3 = @bitCast(@as(i64, off_in)),
            .resv = 0,
        };
    }

    /// Tee data (split pipe)
    pub fn queueTee(self: *Ring, fd_in: i32, fd_out: i32, len: u32, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.* = linux.io_uring_sqe{
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
        const sqe = try self.getSqe();
        sqe.* = linux.io_uring_sqe{
            .opcode = .READ,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = offset,
            .addr = @intFromPtr(buffer.ptr),
            .len = @intCast(buffer.len),
            .rw_flags = 0,
            .user_data = user_data,
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = 0,
            .addr3 = 0,
            .resv = 0,
        };
    }
};
