const std = @import("std");
const picoRoot = @import("picozig");
const picozig = picoRoot.picozig;

pub const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: []picozig.Header,
    body: []const u8,
    content_length: ?usize,
};

/// Парсит HTTP запрос и извлекает body
pub fn parseHttpRequest(allocator: std.mem.Allocator, data: []const u8) !ParsedRequest {
    var headers: [32]picozig.Header = undefined;
    const httpParams = picozig.HttpParams{
        .method = "",
        .path = "",
        .minor_version = 0,
        .num_headers = 0,
        .bytes_read = 0,
    };

    var httpRequest = picozig.HttpRequest{
        .params = httpParams,
        .headers = &headers,
        .body = "",
    };

    const result = picozig.parseRequest(data, &httpRequest);
    if (result < 0) {
        return error.ParseFailed;
    }

    // Ищем Content-Length заголовок
    var content_length: ?usize = null;
    for (headers[0..httpRequest.params.num_headers]) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, header.value, 10) catch null;
            break;
        }
    }

    // Извлекаем body
    var body: []const u8 = "";
    if (httpRequest.params.bytes_read < data.len) {
        const body_start = httpRequest.params.bytes_read;

        // Если есть Content-Length, используем его
        if (content_length) |len| {
            const body_end = @min(body_start + len, data.len);
            body = data[body_start..body_end];
        } else {
            // Иначе берем все что осталось
            body = data[body_start..];
        }
    }

    // Копируем заголовки в динамический массив
    const headers_copy = try allocator.alloc(picozig.Header, httpRequest.params.num_headers);
    @memcpy(headers_copy, headers[0..httpRequest.params.num_headers]);

    return ParsedRequest{
        .method = httpRequest.params.method,
        .path = httpRequest.params.path,
        .headers = headers_copy,
        .body = body,
        .content_length = content_length,
    };
}

pub fn freeRequest(allocator: std.mem.Allocator, request: ParsedRequest) void {
    allocator.free(request.headers);
}

// ============ ТЕСТЫ ============

test "parse GET request without body" {
    const allocator = std.testing.allocator;

    const request_data =
        \\GET / HTTP/1.1
        \\Host: localhost
        \\
        \\
    ;

    const parsed = try parseHttpRequest(allocator, request_data);
    defer freeRequest(allocator, parsed);

    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/", parsed.path);
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
    try std.testing.expect(parsed.content_length == null);
}

test "parse PUT request with body" {
    const allocator = std.testing.allocator;

    const body_data = "Hello, World!";
    const request_data = std.fmt.allocPrint(allocator,
        \\PUT /block/ HTTP/1.1
        \\Host: localhost
        \\Content-Length: {d}
        \\
        \\{s}
    , .{ body_data.len, body_data }) catch unreachable;
    defer allocator.free(request_data);

    const parsed = try parseHttpRequest(allocator, request_data);
    defer freeRequest(allocator, parsed);

    try std.testing.expectEqualStrings("PUT", parsed.method);
    try std.testing.expectEqualStrings("/block/", parsed.path);
    try std.testing.expectEqualStrings(body_data, parsed.body);
    try std.testing.expectEqual(@as(?usize, body_data.len), parsed.content_length);
}

test "parse PUT request with binary body" {
    const allocator = std.testing.allocator;

    const body_data = "AAAAAAAAAA"; // Бинарные данные (повторяющиеся байты)
    const request_data = std.fmt.allocPrint(allocator,
        \\PUT /block/ HTTP/1.1
        \\Content-Length: {d}
        \\Content-Type: application/octet-stream
        \\
        \\{s}
    , .{ body_data.len, body_data }) catch unreachable;
    defer allocator.free(request_data);

    const parsed = try parseHttpRequest(allocator, request_data);
    defer freeRequest(allocator, parsed);

    try std.testing.expectEqualStrings("PUT", parsed.method);
    try std.testing.expectEqualStrings("/block/", parsed.path);
    try std.testing.expectEqual(@as(usize, body_data.len), parsed.body.len);
    try std.testing.expectEqualStrings(body_data, parsed.body);
}

test "parse DELETE request" {
    const allocator = std.testing.allocator;

    const request_data =
        \\DELETE /block/abc123 HTTP/1.1
        \\Host: localhost
        \\
        \\
    ;

    const parsed = try parseHttpRequest(allocator, request_data);
    defer freeRequest(allocator, parsed);

    try std.testing.expectEqualStrings("DELETE", parsed.method);
    try std.testing.expectEqualStrings("/block/abc123", parsed.path);
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
}

test "parse POST with large body" {
    const allocator = std.testing.allocator;

    // Создаем большое тело 4KB
    const body_data = try allocator.alloc(u8, 4096);
    defer allocator.free(body_data);
    @memset(body_data, 'A');

    const request_data = try std.fmt.allocPrint(allocator,
        \\POST /data HTTP/1.1
        \\Content-Length: {d}
        \\
        \\{s}
    , .{ body_data.len, body_data });
    defer allocator.free(request_data);

    const parsed = try parseHttpRequest(allocator, request_data);
    defer freeRequest(allocator, parsed);

    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqual(@as(usize, 4096), parsed.body.len);
    try std.testing.expectEqual(@as(?usize, 4096), parsed.content_length);

    // Проверяем что все байты правильные
    for (parsed.body) |byte| {
        try std.testing.expectEqual(@as(u8, 'A'), byte);
    }
}

test "parse request with multiple headers" {
    const allocator = std.testing.allocator;

    const request_data =
        \\GET /test HTTP/1.1
        \\Host: example.com
        \\User-Agent: TestClient/1.0
        \\Accept: */*
        \\Connection: keep-alive
        \\
        \\
    ;

    const parsed = try parseHttpRequest(allocator, request_data);
    defer freeRequest(allocator, parsed);

    try std.testing.expectEqual(@as(usize, 4), parsed.headers.len);

    // Проверяем что заголовки распарсились
    var found_host = false;
    var found_connection = false;

    for (parsed.headers) |header| {
        if (std.mem.eql(u8, header.name, "Host")) {
            found_host = true;
            try std.testing.expectEqualStrings("example.com", header.value);
        }
        if (std.mem.eql(u8, header.name, "Connection")) {
            found_connection = true;
            try std.testing.expectEqualStrings("keep-alive", header.value);
        }
    }

    try std.testing.expect(found_host);
    try std.testing.expect(found_connection);
}
