const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// Тест: использование MSG_MORE с AF_ALG
test "AF_ALG with MSG_MORE flag" {
    const data1 = "First chunk!";
    const data2 = "Second chunk";
    const full_data = data1 ++ data2;

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

    // Отправляем первый chunk с MSG_MORE
    const MSG_MORE = 0x8000;
    _ = try posix.send(op_sock, data1, MSG_MORE);
    std.debug.print("Sent chunk 1 with MSG_MORE\n", .{});

    // Отправляем второй chunk без флага (последний)
    _ = try posix.send(op_sock, data2, 0);
    std.debug.print("Sent chunk 2 (final)\n", .{});

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
    std.debug.print("✓ MSG_MORE test passed\n", .{});
}
