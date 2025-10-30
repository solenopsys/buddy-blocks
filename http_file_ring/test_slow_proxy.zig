const std = @import("std");
const posix = std.posix;
const net = std.net;

// Тест эмулирует медленный прокси:
// - Открывает TCP соединение
// - Отправляет HTTP заголовки нормально
// - Тело отправляет маленькими порциями (например 1KB) с задержками
// Это воспроизводит проблему когда splice() возвращает 0 байт

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Testing slow proxy behavior ===\n", .{});
    std.debug.print("Connecting to localhost:8080...\n", .{});

    // Подключаемся к серверу
    const address = try net.Address.parseIp4("127.0.0.1", 8080);
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());
    std.debug.print("Connected!\n", .{});

    // Подготовим данные
    const content_size: usize = 512 * 1024; // 512 KB
    const data = try allocator.alloc(u8, content_size);
    defer allocator.free(data);

    // Заполняем простыми данными
    @memset(data, 'A');

    // Отправляем HTTP заголовки
    var header_buf: [256]u8 = undefined;
    const headers = try std.fmt.bufPrint(&header_buf, "PUT / HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{content_size});
    _ = try posix.send(socket, headers, 0);
    std.debug.print("Sent headers: Content-Length: {d}\n", .{content_size});

    // ЭМУЛИРУЕМ МЕДЛЕННЫЙ ПРОКСИ:
    // Отправляем тело маленькими кусками БЕЗ задержек - просто много мелких send()
    const chunk_size: usize = 512; // 512 bytes - очень мелкие!
    var sent: usize = 0;

    std.debug.print("Sending body in {d} byte chunks (no delays)...\n", .{chunk_size});

    while (sent < content_size) {
        const remaining = content_size - sent;
        const to_send = @min(chunk_size, remaining);

        const n = try posix.send(socket, data[sent .. sent + to_send], 0);
        sent += n;
    }

    std.debug.print("All {d} bytes sent in small chunks\n", .{sent});

    std.debug.print("All {d} bytes sent!\n", .{sent});

    // Читаем ответ
    std.debug.print("Waiting for response...\n", .{});
    var response_buf: [4096]u8 = undefined;
    const response_len = try posix.recv(socket, &response_buf, 0);

    if (response_len > 0) {
        const response = response_buf[0..response_len];
        std.debug.print("Response received ({d} bytes):\n{s}\n", .{ response_len, response });

        // Проверяем что получили 200 OK
        if (std.mem.indexOf(u8, response, "200 OK")) |_| {
            std.debug.print("✓ SUCCESS: Got 200 OK response\n", .{});
        } else {
            std.debug.print("✗ FAILED: Expected 200 OK\n", .{});
            return error.TestFailed;
        }
    } else {
        std.debug.print("✗ FAILED: No response received\n", .{});
        return error.NoResponse;
    }

    std.debug.print("=== Test completed successfully ===\n", .{});
}
