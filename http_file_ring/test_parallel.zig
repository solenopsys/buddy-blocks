const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub fn main() !void {
    std.debug.print("=== Testing PARALLEL tee + splice (same as HTTP server) ===\n\n", .{});

    const test_data = "Hello, World! This is test data for parallel operations!";
    std.debug.print("Test data: {s}\n", .{test_data});
    std.debug.print("Length: {d} bytes\n\n", .{test_data.len});

    // Вычисляем ожидаемый хеш
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(test_data, &expected_hash, .{});
    std.debug.print("Expected hash: ", .{});
    for (expected_hash) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n\n", .{});

    // === Шаг 1: Создаем AF_ALG socket ===
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
    std.debug.print("✓ AF_ALG socket created\n", .{});

    // === Шаг 2: Создаем временный файл для записи ===
    const file = try posix.open("test_output.dat", .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    defer {
        posix.close(file);
        posix.unlink("test_output.dat") catch {};
    }
    std.debug.print("✓ Temp file created\n", .{});

    // === Шаг 3: Создаем pipes (как в сервере) ===
    const pipe1 = try posix.pipe(); // socket -> pipe1
    const pipe2 = try posix.pipe(); // pipe1 -tee-> pipe2 -> hash
    std.debug.print("✓ Two pipe pairs created\n", .{});
    std.debug.print("  pipe1: read={d}, write={d}\n", .{ pipe1[0], pipe1[1] });
    std.debug.print("  pipe2: read={d}, write={d}\n\n", .{ pipe2[0], pipe2[1] });

    // === Шаг 4: Пишем данные в pipe1 (эмулируем splice от socket) ===
    const written = try posix.write(pipe1[1], test_data);
    std.debug.print("STEP 1: Written {d} bytes to pipe1[write]\n", .{written});

    // Закрываем write-конец pipe1 (как делает сервер после splice_socket_to_pipe)
    posix.close(pipe1[1]);
    std.debug.print("        Closed pipe1[write]\n\n", .{});

    // === Шаг 5: ПАРАЛЛЕЛЬНО запускаем 3 операции (КАК В СЕРВЕРЕ!) ===
    std.debug.print("STEP 2: Launching 3 PARALLEL operations:\n", .{});
    std.debug.print("        1. tee(pipe1[read] -> pipe2[write])\n", .{});
    std.debug.print("        2. splice(pipe1[read] -> file)\n", .{});
    std.debug.print("        3. splice(pipe2[read] -> hash_sock)\n\n", .{});

    // Операция 1: tee (pipe1 -> pipe2)
    const tee_result = linux.syscall4(.tee, @intCast(pipe1[0]), @intCast(pipe2[1]), test_data.len, 0);
    std.debug.print("tee() = {d}\n", .{@as(isize, @bitCast(tee_result))});
    if (@as(isize, @bitCast(tee_result)) < 0) {
        std.debug.print("✗ tee() FAILED!\n", .{});
        return error.TeeFailed;
    }

    // Операция 2: splice (pipe1 -> file)
    const splice_file = linux.syscall6(.splice, @intCast(pipe1[0]), 0, @intCast(file), 0, test_data.len, 0);
    std.debug.print("splice(pipe1 -> file) = {d}\n", .{@as(isize, @bitCast(splice_file))});
    if (@as(isize, @bitCast(splice_file)) < 0) {
        std.debug.print("✗ splice to file FAILED!\n", .{});
        return error.SpliceFailed;
    }

    // Закрываем write-конец pipe2
    posix.close(pipe2[1]);

    // Операция 3: splice (pipe2 -> hash)
    const splice_hash = linux.syscall6(.splice, @intCast(pipe2[0]), 0, @intCast(hash_sock), 0, test_data.len, 0);
    std.debug.print("splice(pipe2 -> hash) = {d}\n\n", .{@as(isize, @bitCast(splice_hash))});
    if (@as(isize, @bitCast(splice_hash)) < 0) {
        std.debug.print("✗ splice to hash FAILED!\n", .{});
        return error.SpliceFailed;
    }

    // Закрываем pipes
    posix.close(pipe1[0]);
    posix.close(pipe2[0]);

    // === Шаг 6: Читаем хеш ===
    var actual_hash: [32]u8 = undefined;
    const hash_len = try posix.recv(hash_sock, &actual_hash, 0);
    std.debug.print("STEP 3: recv() from hash socket: {d} bytes\n", .{hash_len});

    if (hash_len != 32) {
        std.debug.print("✗ Expected 32 bytes, got {d}\n", .{hash_len});
        return error.InvalidHashLength;
    }

    std.debug.print("Actual hash:   ", .{});
    for (actual_hash) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    // === Шаг 7: Проверяем файл ===
    _ = linux.lseek(file, 0, linux.SEEK.SET);
    var file_buf: [256]u8 = undefined;
    const file_read = try posix.read(file, &file_buf);
    std.debug.print("\nSTEP 4: Read {d} bytes from file\n", .{file_read});
    std.debug.print("File content: {s}\n", .{file_buf[0..file_read]});

    // === Результат ===
    const hash_match = std.mem.eql(u8, &expected_hash, &actual_hash);
    const file_match = std.mem.eql(u8, test_data, file_buf[0..file_read]);

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    if (hash_match and file_match) {
        std.debug.print("✓✓✓ SUCCESS! Both hash and file are correct!\n", .{});
        std.debug.print("    This means the parallel pattern WORKS!\n", .{});
    } else {
        if (!hash_match) {
            std.debug.print("✗ Hash MISMATCH!\n", .{});
        }
        if (!file_match) {
            std.debug.print("✗ File content MISMATCH!\n", .{});
            std.debug.print("  Expected: {s}\n", .{test_data});
            std.debug.print("  Got:      {s}\n", .{file_buf[0..file_read]});
        }
        std.debug.print("    This means the parallel pattern is BROKEN!\n", .{});
        return error.TestFailed;
    }
    std.debug.print("=" ** 60 ++ "\n", .{});
}
