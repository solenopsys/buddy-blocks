const std = @import("std");

// Минимальная версия парсера для тестирования
pub fn parseHttpRequest(data: []const u8) !struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
    content_length: ?usize,
} {
    // Найти конец первой строки (метод и путь)
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse
                           std.mem.indexOf(u8, data, "\n") orelse
                           return error.InvalidRequest;

    const first_line = data[0..first_line_end];

    // Парсим метод и путь
    var parts = std.mem.splitSequence(u8, first_line, " ");
    const method = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;

    // Найти конец заголовков (пустая строка)
    const headers_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse
                        std.mem.indexOf(u8, data, "\n\n") orelse
                        return error.InvalidRequest;

    // Определяем где начинается body
    const body_start = if (std.mem.indexOf(u8, data, "\r\n\r\n")) |_|
        headers_end + 4
    else
        headers_end + 2;

    // Извлекаем заголовки для поиска Content-Length
    const headers_text = data[first_line_end..headers_end];
    var content_length: ?usize = null;

    var lines = std.mem.splitSequence(u8, headers_text, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            const value_start = std.mem.indexOf(u8, trimmed, ":") orelse continue;
            const value = std.mem.trim(u8, trimmed[value_start + 1..], &std.ascii.whitespace);
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
            break;
        }
    }

    // Извлекаем body
    var body: []const u8 = "";
    if (body_start < data.len) {
        if (content_length) |len| {
            const body_end = @min(body_start + len, data.len);
            body = data[body_start..body_end];
        } else {
            body = data[body_start..];
        }
    }

    return .{
        .method = method,
        .path = path,
        .body = body,
        .content_length = content_length,
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== HTTP Parser Tests ===\n\n", .{});

    // Test 1: GET без body
    {
        std.debug.print("Test 1: GET без body\n", .{});
        const request_data =
            "GET / HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n";

        const parsed = try parseHttpRequest(request_data);
        std.debug.print("  Method: {s}\n", .{parsed.method});
        std.debug.print("  Path: {s}\n", .{parsed.path});
        std.debug.print("  Body length: {d}\n", .{parsed.body.len});
        std.debug.print("  Content-Length: {?}\n", .{parsed.content_length});

        if (!std.mem.eql(u8, parsed.method, "GET")) return error.TestFailed;
        if (!std.mem.eql(u8, parsed.path, "/")) return error.TestFailed;
        if (parsed.body.len != 0) return error.TestFailed;

        std.debug.print("  ✓ PASSED\n\n", .{});
    }

    // Test 2: PUT с body
    {
        std.debug.print("Test 2: PUT с body\n", .{});
        const body_data = "Hello, World!";
        const request_data = try std.fmt.allocPrint(allocator,
            "PUT /block/ HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
            .{ body_data.len, body_data }
        );
        defer allocator.free(request_data);

        const parsed = try parseHttpRequest(request_data);
        std.debug.print("  Method: {s}\n", .{parsed.method});
        std.debug.print("  Path: {s}\n", .{parsed.path});
        std.debug.print("  Body: '{s}'\n", .{parsed.body});
        std.debug.print("  Body length: {d}\n", .{parsed.body.len});
        std.debug.print("  Content-Length: {?}\n", .{parsed.content_length});

        if (!std.mem.eql(u8, parsed.method, "PUT")) return error.TestFailed;
        if (!std.mem.eql(u8, parsed.path, "/block/")) return error.TestFailed;
        if (!std.mem.eql(u8, parsed.body, body_data)) return error.TestFailed;
        if (parsed.content_length.? != body_data.len) return error.TestFailed;

        std.debug.print("  ✓ PASSED\n\n", .{});
    }

    // Test 3: PUT с бинарными данными 4KB
    {
        std.debug.print("Test 3: PUT с бинарными данными 4KB\n", .{});
        const body_data = try allocator.alloc(u8, 4096);
        defer allocator.free(body_data);
        @memset(body_data, 'A');

        const request_data = try std.fmt.allocPrint(allocator,
            "PUT /block/ HTTP/1.1\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Content-Type: application/octet-stream\r\n" ++
            "\r\n" ++
            "{s}",
            .{ body_data.len, body_data }
        );
        defer allocator.free(request_data);

        const parsed = try parseHttpRequest(request_data);
        std.debug.print("  Method: {s}\n", .{parsed.method});
        std.debug.print("  Path: {s}\n", .{parsed.path});
        std.debug.print("  Body length: {d}\n", .{parsed.body.len});
        std.debug.print("  Content-Length: {?}\n", .{parsed.content_length});

        if (!std.mem.eql(u8, parsed.method, "PUT")) return error.TestFailed;
        if (parsed.body.len != 4096) return error.TestFailed;
        if (parsed.content_length.? != 4096) return error.TestFailed;

        // Проверяем первые и последние байты
        if (parsed.body[0] != 'A') return error.TestFailed;
        if (parsed.body[4095] != 'A') return error.TestFailed;

        std.debug.print("  ✓ PASSED\n\n", .{});
    }

    // Test 4: DELETE без body
    {
        std.debug.print("Test 4: DELETE без body\n", .{});
        const request_data =
            "DELETE /block/abc123 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n";

        const parsed = try parseHttpRequest(request_data);
        std.debug.print("  Method: {s}\n", .{parsed.method});
        std.debug.print("  Path: {s}\n", .{parsed.path});
        std.debug.print("  Body length: {d}\n", .{parsed.body.len});

        if (!std.mem.eql(u8, parsed.method, "DELETE")) return error.TestFailed;
        if (!std.mem.eql(u8, parsed.path, "/block/abc123")) return error.TestFailed;
        if (parsed.body.len != 0) return error.TestFailed;

        std.debug.print("  ✓ PASSED\n\n", .{});
    }

    std.debug.print("=== Все тесты прошли успешно! ===\n", .{});
}
