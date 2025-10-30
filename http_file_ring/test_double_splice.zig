const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

fn splice(fd_in: i32, off_in: ?*i64, fd_out: i32, off_out: ?*i64, len: usize, flags: u32) i64 {
    const result = linux.syscall6(.splice, @as(usize, @bitCast(@as(isize, fd_in))), @intFromPtr(off_in), @as(usize, @bitCast(@as(isize, fd_out))), @intFromPtr(off_out), len, flags);
    return @bitCast(result);
}

// Тест: два последовательных splice в один AF_ALG socket
test "two sequential splices to AF_ALG socket" {
    const data1 = "First chunk!";
    const data2 = "Second chunk";

    // Полные данные
    const full_data = data1 ++ data2;

    // Создаём два pipes
    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);

    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);

    // Создаём AF_ALG socket
    const AF_ALG = 38;
    const sock = try posix.socket(AF_ALG, posix.SOCK.SEQPACKET, 0);
    defer posix.close(sock);

    var addr: [88]u8 = std.mem.zeroes([88]u8);
    addr[0] = AF_ALG;
    addr[1] = 0;
    @memcpy(addr[2..6], "hash");
    @memcpy(addr[24..30], "sha256");

    try posix.bind(sock, @ptrCast(@alignCast(&addr)), 88);
    const op_sock = try posix.accept(sock, null, null, 0);
    defer posix.close(op_sock);

    // Записываем данные в pipes
    _ = try posix.write(pipe1[1], data1);
    posix.close(pipe1[1]);

    _ = try posix.write(pipe2[1], data2);
    posix.close(pipe2[1]);

    // Первый splice
    const spliced1 = splice(pipe1[0], null, op_sock, null, data1.len, 0);
    std.debug.print("Spliced chunk 1: {d} bytes\n", .{spliced1});
    try std.testing.expectEqual(@as(i64, data1.len), spliced1);

    // Второй splice
    const spliced2 = splice(pipe2[0], null, op_sock, null, data2.len, 0);
    std.debug.print("Spliced chunk 2: {d} bytes\n", .{spliced2});
    try std.testing.expectEqual(@as(i64, data2.len), spliced2);

    // Читаем хеш
    var hash: [32]u8 = undefined;
    const len = try posix.recv(op_sock, &hash, 0);
    try std.testing.expectEqual(@as(usize, 32), len);

    // Проверяем с полными данными
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(full_data);
    var expected: [32]u8 = undefined;
    hasher.final(&expected);

    std.debug.print("Expected hash: {any}\n", .{expected});
    std.debug.print("AF_ALG hash:   {any}\n", .{hash});

    try std.testing.expectEqualSlices(u8, &expected, &hash);
    std.debug.print("✓ Two sequential splices test passed\n", .{});
}
