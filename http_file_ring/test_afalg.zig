const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    std.debug.print("=== Testing AF_ALG + splice + tee ===\n", .{});

    // Создаем тестовые данные
    const test_data = "Hello, World! This is a test message for SHA256 hashing.";
    std.debug.print("Test data: {s}\n", .{test_data});
    std.debug.print("Test data length: {d}\n", .{test_data.len});

    // Вычисляем ожидаемый хеш с помощью std.crypto
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(test_data, &expected_hash, .{});
    std.debug.print("Expected hash: ", .{});
    for (expected_hash) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n\n", .{});

    // Создаем AF_ALG bind socket
    const AF_ALG = 38;
    const bind_sock = try posix.socket(AF_ALG, posix.SOCK.SEQPACKET, 0);
    defer posix.close(bind_sock);

    var addr: [88]u8 align(4) = std.mem.zeroes([88]u8);
    addr[0] = AF_ALG; // sa_family
    addr[1] = 0;
    @memcpy(addr[2..6], "hash");
    @memcpy(addr[24..30], "sha256");

    try posix.bind(bind_sock, @ptrCast(&addr), 88);
    std.debug.print("✓ AF_ALG bind socket created\n", .{});

    // Создаем operation socket
    const op_sock = try posix.accept(bind_sock, null, null, 0);
    defer posix.close(op_sock);
    std.debug.print("✓ AF_ALG operation socket created\n", .{});

    // Создаем две пары pipe
    const pipe1 = try posix.pipe();
    const pipe2 = try posix.pipe();
    defer {
        posix.close(pipe1[0]);
        posix.close(pipe1[1]);
        posix.close(pipe2[0]);
        posix.close(pipe2[1]);
    }
    std.debug.print("✓ Two pipe pairs created\n", .{});

    // Записываем данные в pipe1
    const written = try posix.write(pipe1[1], test_data);
    std.debug.print("✓ Written {d} bytes to pipe1\n", .{written});

    // Закрываем write-конец pipe1 чтобы показать EOF
    posix.close(pipe1[1]);

    // Теперь делаем tee: pipe1 -> pipe2 (syscall напрямую)
    const linux = std.os.linux;
    const tee_result = linux.syscall4(.tee, @intCast(pipe1[0]), @intCast(pipe2[1]), test_data.len, 0);
    std.debug.print("tee() result: {d}\n", .{@as(isize, @bitCast(tee_result))});

    if (@as(isize, @bitCast(tee_result)) < 0) {
        std.debug.print("✗ tee() failed with error: {d}\n", .{@as(isize, @bitCast(tee_result))});
        return error.TeeFailed;
    }
    std.debug.print("✓ tee() copied {d} bytes to pipe2\n", .{tee_result});

    // Закрываем write-конец pipe2
    posix.close(pipe2[1]);

    // Теперь splice из pipe2 в AF_ALG socket (syscall напрямую)
    const splice_result = linux.syscall6(.splice, @intCast(pipe2[0]), 0, @intCast(op_sock), 0, test_data.len, 0);
    std.debug.print("splice(pipe2 -> hash_socket) result: {d}\n", .{@as(isize, @bitCast(splice_result))});

    if (@as(isize, @bitCast(splice_result)) < 0) {
        std.debug.print("✗ splice() failed with error: {d}\n", .{@as(isize, @bitCast(splice_result))});
        return error.SpliceFailed;
    }
    std.debug.print("✓ splice() sent {d} bytes to hash socket\n", .{splice_result});

    // Закрываем read-конец pipe2
    posix.close(pipe2[0]);

    // Читаем хеш из AF_ALG socket
    var actual_hash: [32]u8 = undefined;
    const hash_len = try posix.recv(op_sock, &actual_hash, 0);
    std.debug.print("recv() from hash socket: {d} bytes\n", .{hash_len});

    if (hash_len != 32) {
        std.debug.print("✗ Expected 32 bytes, got {d}\n", .{hash_len});
        return error.InvalidHashLength;
    }

    std.debug.print("Actual hash:   ", .{});
    for (actual_hash) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    // Сравниваем хеши
    if (std.mem.eql(u8, &expected_hash, &actual_hash)) {
        std.debug.print("\n✓✓✓ SUCCESS! Hashes match! ✓✓✓\n", .{});
    } else {
        std.debug.print("\n✗✗✗ FAILURE! Hashes don't match! ✗✗✗\n", .{});
        return error.HashMismatch;
    }

    // ===== ВТОРОЙ ПРОХОД - проверяем переиспользование socket =====
    std.debug.print("\n=== Testing socket reuse (second hash) ===\n", .{});

    const test_data2 = "Different data for second hash calculation test!";
    std.debug.print("Test data 2: {s}\n", .{test_data2});

    var expected_hash2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(test_data2, &expected_hash2, .{});
    std.debug.print("Expected hash 2: ", .{});
    for (expected_hash2) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n\n", .{});

    // Создаем новые pipes
    const pipe3 = try posix.pipe();
    const pipe4 = try posix.pipe();
    defer {
        posix.close(pipe3[0]);
        posix.close(pipe4[0]);
    }

    // Записываем данные в pipe3
    const written2 = try posix.write(pipe3[1], test_data2);
    std.debug.print("✓ Written {d} bytes to pipe3\n", .{written2});
    posix.close(pipe3[1]);

    // tee: pipe3 -> pipe4
    const tee_result2 = linux.syscall4(.tee, @intCast(pipe3[0]), @intCast(pipe4[1]), test_data2.len, 0);
    std.debug.print("tee() result: {d}\n", .{@as(isize, @bitCast(tee_result2))});
    if (@as(isize, @bitCast(tee_result2)) < 0) {
        std.debug.print("✗ tee() failed\n", .{});
        return error.TeeFailed;
    }
    posix.close(pipe4[1]);

    // splice: pipe4 -> SAME hash socket (op_sock)
    const splice_result2 = linux.syscall6(.splice, @intCast(pipe4[0]), 0, @intCast(op_sock), 0, test_data2.len, 0);
    std.debug.print("splice(pipe4 -> hash_socket) result: {d}\n", .{@as(isize, @bitCast(splice_result2))});
    if (@as(isize, @bitCast(splice_result2)) < 0) {
        std.debug.print("✗ splice() failed\n", .{});
        return error.SpliceFailed;
    }
    std.debug.print("✓ splice() sent {d} bytes to hash socket\n", .{splice_result2});

    // Читаем хеш из того же AF_ALG socket
    var actual_hash2: [32]u8 = undefined;
    const hash_len2 = try posix.recv(op_sock, &actual_hash2, 0);
    std.debug.print("recv() from hash socket: {d} bytes\n", .{hash_len2});

    std.debug.print("Actual hash 2: ", .{});
    for (actual_hash2) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    if (std.mem.eql(u8, &expected_hash2, &actual_hash2)) {
        std.debug.print("\n✓✓✓ SUCCESS! Second hash also matches! Socket reuse works! ✓✓✓\n", .{});
    } else {
        std.debug.print("\n✗✗✗ FAILURE! Second hash doesn't match! Socket reuse BROKEN! ✗✗✗\n", .{});
        return error.HashMismatch;
    }
}
