const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

// Тест: splice с MSG_MORE через io_uring
test "io_uring splice to AF_ALG with MSG_MORE" {
    const data1 = "First chunk!";
    const data2 = "Second chunk";
    const full_data = data1 ++ data2;

    var ring = try IoUring.init(16, 0);
    defer ring.deinit();

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

    // Первый splice с MSG_MORE через rw_flags
    const MSG_MORE: u32 = 0x8000;
    const sqe1 = try ring.splice(1, pipe1[0], std.math.maxInt(u64), op_sock, std.math.maxInt(u64), data1.len);
    sqe1.rw_flags = MSG_MORE; // Устанавливаем MSG_MORE

    _ = try ring.submit();
    const cqe1 = try ring.copy_cqe();
    std.debug.print("Splice 1 result: {d} bytes\n", .{cqe1.res});
    try std.testing.expect(cqe1.res == data1.len);

    // Второй splice без MSG_MORE (последний)
    const sqe2 = try ring.splice(2, pipe2[0], std.math.maxInt(u64), op_sock, std.math.maxInt(u64), data2.len);
    sqe2.rw_flags = 0; // Без флага - финализируем

    _ = try ring.submit();
    const cqe2 = try ring.copy_cqe();
    std.debug.print("Splice 2 result: {d} bytes\n", .{cqe2.res});
    try std.testing.expect(cqe2.res == data2.len);

    // Читаем хеш
    var hash: [32]u8 = undefined;
    const len = try posix.recv(op_sock, &hash, 0);
    try std.testing.expectEqual(@as(usize, 32), len);

    // Проверяем
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(full_data);
    var expected: [32]u8 = undefined;
    hasher.final(&expected);

    std.debug.print("Expected hash: {any}\n", .{expected});
    std.debug.print("AF_ALG hash:   {any}\n", .{hash});

    try std.testing.expectEqualSlices(u8, &expected, &hash);
    std.debug.print("✓ io_uring splice with MSG_MORE test passed\n", .{});
}
