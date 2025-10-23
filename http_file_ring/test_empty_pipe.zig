const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub fn main() !void {
    std.debug.print("=== Testing what happens with EMPTY pipe ===\n\n", .{});

    // Создаем AF_ALG socket
    const AF_ALG = 38;
    const bind_sock = try posix.socket(AF_ALG, posix.SOCK.SEQPACKET, 0);
    defer posix.close(bind_sock);

    var addr: [88]u8 align(4) = std.mem.zeroes([88]u8);
    addr[0] = AF_ALG;
    addr[1] = 0;
    @memcpy(addr[2..6], "hash");
    @memcpy(addr[24..30], "sha256");
    try posix.bind(bind_sock, @ptrCast(&addr), 88);

    const hash_sock = try posix.accept(bind_sock, null, null, 0);
    defer posix.close(hash_sock);

    // Создаем pipes
    const pipe1 = try posix.pipe();
    const pipe2 = try posix.pipe();

    std.debug.print("Created pipes, but NOT writing any data to pipe1!\n\n", .{});

    // НЕ пишем данные! Просто закрываем write-конец
    posix.close(pipe1[1]);
    std.debug.print("Closed pipe1[write] without writing anything\n\n", .{});

    // Запускаем операции на ПУСТОМ pipe
    std.debug.print("Running operations on EMPTY pipe:\n", .{});

    const tee_result = linux.syscall4(.tee, @intCast(pipe1[0]), @intCast(pipe2[1]), 1024, 0);
    std.debug.print("tee() = {d}\n", .{@as(isize, @bitCast(tee_result))});

    posix.close(pipe2[1]);

    const splice_result = linux.syscall6(.splice, @intCast(pipe2[0]), 0, @intCast(hash_sock), 0, 1024, 0);
    std.debug.print("splice(pipe2 -> hash) = {d}\n\n", .{@as(isize, @bitCast(splice_result))});

    posix.close(pipe1[0]);
    posix.close(pipe2[0]);

    // Пытаемся прочитать хеш
    var actual_hash: [32]u8 = undefined;
    const hash_len = try posix.recv(hash_sock, &actual_hash, 0);
    std.debug.print("recv() from hash socket: {d} bytes\n", .{hash_len});

    if (hash_len == 32) {
        std.debug.print("Received hash: ", .{});
        for (actual_hash) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n\n", .{});

        // Это хеш пустой строки?
        var empty_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("", &empty_hash, .{});

        if (std.mem.eql(u8, &empty_hash, &actual_hash)) {
            std.debug.print("✓ This is SHA256 of EMPTY string!\n", .{});
            std.debug.print("  This is what we see in the server logs!\n", .{});
        }
    }
}
