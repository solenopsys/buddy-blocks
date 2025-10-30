const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// Syscall wrappers
fn splice(fd_in: i32, off_in: ?*i64, fd_out: i32, off_out: ?*i64, len: usize, flags: u32) i64 {
    const result = linux.syscall6(.splice, @as(usize, @bitCast(@as(isize, fd_in))), @intFromPtr(off_in), @as(usize, @bitCast(@as(isize, fd_out))), @intFromPtr(off_out), len, flags);
    return @bitCast(result);
}

fn tee(fd_in: i32, fd_out: i32, len: usize, flags: u32) i64 {
    const result = linux.syscall4(.tee, @as(usize, @bitCast(@as(isize, fd_in))), @as(usize, @bitCast(@as(isize, fd_out))), len, flags);
    return @bitCast(result);
}

// Тест 1: AF_ALG socket работает правильно
test "AF_ALG hash socket basic" {
    const test_data = "Hello, World!";

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

    // Отправляем данные через send
    _ = try posix.send(op_sock, test_data, 0);

    // Читаем хеш
    var hash: [32]u8 = undefined;
    const len = try posix.recv(op_sock, &hash, 0);

    try std.testing.expectEqual(@as(usize, 32), len);

    // Проверяем с std.crypto
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(test_data);
    var expected: [32]u8 = undefined;
    hasher.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &hash);
    std.debug.print("✓ AF_ALG socket test passed\n", .{});
}

// Тест 2: splice через AF_ALG socket
test "splice to AF_ALG socket" {
    const test_data = "Hello from pipe!";

    // Создаём pipe
    const pipes = try posix.pipe();
    defer posix.close(pipes[0]);

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

    // Записываем данные в pipe
    _ = try posix.write(pipes[1], test_data);
    posix.close(pipes[1]);

    // splice из pipe в AF_ALG socket
    const spliced = splice(pipes[0], null, op_sock, null, test_data.len, 0);
    std.debug.print("Spliced {d} bytes\n", .{spliced});

    // Читаем хеш
    var hash: [32]u8 = undefined;
    const len = try posix.recv(op_sock, &hash, 0);

    try std.testing.expectEqual(@as(usize, 32), len);

    // Проверяем
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(test_data);
    var expected: [32]u8 = undefined;
    hasher.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &hash);
    std.debug.print("✓ splice to AF_ALG test passed\n", .{});
}

// Тест 3: tee НЕ потребляет данные
test "tee does not consume data" {
    const test_data = "Test data for tee";

    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);
    defer posix.close(pipe1[1]);

    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);
    defer posix.close(pipe2[1]);

    // Записываем в pipe1
    _ = try posix.write(pipe1[1], test_data);

    // tee из pipe1 в pipe2
    const teed_result = tee(pipe1[0], pipe2[1], test_data.len, 0);
    std.debug.print("Teed {d} bytes\n", .{teed_result});

    // Читаем из pipe1 (данные должны остаться!)
    var buf1: [100]u8 = undefined;
    const read1 = try posix.read(pipe1[0], &buf1);
    try std.testing.expectEqual(test_data.len, read1);
    try std.testing.expectEqualStrings(test_data, buf1[0..read1]);

    // Читаем из pipe2 (там копия)
    var buf2: [100]u8 = undefined;
    const read2 = try posix.read(pipe2[0], &buf2);
    try std.testing.expectEqual(test_data.len, read2);
    try std.testing.expectEqualStrings(test_data, buf2[0..read2]);

    std.debug.print("✓ tee test passed - data duplicated correctly\n", .{});
}

// Тест 4: tee + splice параллельно
test "tee and splice in parallel" {
    const test_data = "Parallel tee and splice test data";

    const pipe1 = try posix.pipe();
    defer posix.close(pipe1[0]);

    const pipe2 = try posix.pipe();
    defer posix.close(pipe2[0]);
    defer posix.close(pipe2[1]);

    // Записываем в pipe1
    _ = try posix.write(pipe1[1], test_data);
    posix.close(pipe1[1]);

    // tee из pipe1 в pipe2
    const teed_bytes = tee(pipe1[0], pipe2[1], test_data.len, 0);
    std.debug.print("Teed {d} bytes\n", .{teed_bytes});

    // splice из pipe1 куда-то (создадим третий pipe)
    const pipe3 = try posix.pipe();
    defer posix.close(pipe3[0]);
    defer posix.close(pipe3[1]);

    const spliced_bytes = splice(pipe1[0], null, pipe3[1], null, test_data.len, 0);
    std.debug.print("Spliced {d} bytes from pipe1\n", .{spliced_bytes});

    // Читаем из pipe2
    var buf2: [100]u8 = undefined;
    const read2 = try posix.read(pipe2[0], &buf2);
    try std.testing.expectEqual(test_data.len, read2);
    try std.testing.expectEqualStrings(test_data, buf2[0..read2]);

    // Читаем из pipe3
    var buf3: [100]u8 = undefined;
    const read3 = try posix.read(pipe3[0], &buf3);
    try std.testing.expectEqual(test_data.len, read3);
    try std.testing.expectEqualStrings(test_data, buf3[0..read3]);

    std.debug.print("✓ parallel tee+splice test passed\n", .{});
}
