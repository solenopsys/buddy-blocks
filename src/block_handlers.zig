const std = @import("std");
const picoRoot = @import("picozig");
const picozig = picoRoot.picozig;
const generateHttpResponse = picoRoot.response.generateHttpResponse;
const HttpRequest = picozig.HttpRequest;
const BlockController = @import("./block_controller_adapter.zig").BlockController;

var block_controller: ?*BlockController = null;

/// Инициализирует BlockController (вызывается один раз при старте)
pub fn initBlockController(controller: *BlockController) void {
    block_controller = controller;
}

/// Вычисляем SHA256 хеш от данных
fn computeHash(data: []const u8, hash_out: *[32]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.final(hash_out);
}

/// PUT /block - сохраняет блок, возвращает хеш
pub fn handlePut(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
    const controller = block_controller orelse {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "BlockController not initialized",
        );
    };

    const body = request.body;
    if (body.len == 0) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Empty body",
        );
    }

    // Проверяем размер данных (максимум 512KB)
    if (body.len > 524288) {
        return try generateHttpResponse(
            allocator,
            413,
            "text/plain",
            "Payload too large (max 512KB)",
        );
    }

    // Вычисляем хеш
    var hash: [32]u8 = undefined;
    computeHash(body, &hash);

    // Записываем через BlockController
    controller.writeBlock(hash, body) catch |err| {
        std.debug.print("writeBlock failed: {any}\n", .{err});
        const error_msg = switch (err) {
            error.DataTooLarge => "Data too large for block",
            error.DatabasePutFailed => "Database operation failed",
            else => "Internal server error",
        };
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            error_msg,
        );
    };

    // Проверяем хеш записанных данных
    const read_data = controller.readBlock(hash, allocator) catch |err| {
        std.debug.print("readBlock failed: {any}\n", .{err});
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Hash verification failed",
        );
    };
    defer allocator.free(read_data);

    var verify_hash: [32]u8 = undefined;
    computeHash(read_data, &verify_hash);

    if (!std.mem.eql(u8, &hash, &verify_hash)) {
        // Откатываем запись при несовпадении хеша
        controller.deleteBlock(hash) catch {};
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Hash mismatch - transaction rolled back",
        );
    }

    // Возвращаем хеш в hex формате
    const hex_hash = std.fmt.bytesToHex(hash, std.fmt.Case.lower);

    return try generateHttpResponse(
        allocator,
        200,
        "text/plain",
        &hex_hash,
    );
}

/// GET /block/<hash> - получает блок по хешу
pub fn handleGet(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
    const controller = block_controller orelse {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "BlockController not initialized",
        );
    };

    // Извлекаем хеш из пути: /block/<hash>
    const path = request.params.path;
    const prefix = "/block/";

    if (!std.mem.startsWith(u8, path, prefix)) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid path format",
        );
    }

    const hex_hash = path[prefix.len..];
    if (hex_hash.len != 64) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid hash length (expected 64 hex chars)",
        );
    }

    // Конвертируем hex в bytes
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hex_hash) catch {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid hex hash",
        );
    };

    // Читаем через BlockController
    const data = controller.readBlock(hash, allocator) catch |err| {
        const status: u16 = if (err == error.BlockNotFound) 404 else 500;
        const msg = if (err == error.BlockNotFound)
            "Block not found"
        else
            "Internal server error";

        return try generateHttpResponse(
            allocator,
            status,
            "text/plain",
            msg,
        );
    };

    // Возвращаем бинарные данные с Content-Length
    const header = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n",
        .{data.len},
    );
    defer allocator.free(header);

    const response = try allocator.alloc(u8, header.len + data.len);
    @memcpy(response[0..header.len], header);
    @memcpy(response[header.len..], data);

    return response;
}

/// PUT /block (streaming version) - сохраняет блок напрямую из socket, возвращает хеш
pub fn handlePutStreaming(
    socket_fd: std.posix.fd_t,
    content_length: u64,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const controller = block_controller orelse {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "BlockController not initialized",
        );
    };

    if (content_length == 0) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Empty body",
        );
    }

    // Проверяем размер данных (максимум 512KB)
    if (content_length > 524288) {
        return try generateHttpResponse(
            allocator,
            413,
            "text/plain",
            "Payload too large (max 512KB)",
        );
    }

    // Потоково записываем из socket в файл с вычислением хеша
    const hash = controller.writeBlockFromSocket(socket_fd, content_length) catch |err| {
        const error_msg = switch (err) {
            error.DataTooLarge => "Data too large for block",
            error.DatabasePutFailed => "Database operation failed",
            error.SocketReadError => "Failed to read from socket",
            error.FileWriteError => "Failed to write to file",
            else => "Internal server error",
        };
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            error_msg,
        );
    };

    // Возвращаем хеш в hex формате
    const hex_hash = std.fmt.bytesToHex(hash, std.fmt.Case.lower);

    return try generateHttpResponse(
        allocator,
        200,
        "text/plain",
        &hex_hash,
    );
}

/// GET /block/<hash> (streaming version) - отправляет блок напрямую в socket
pub fn handleGetStreaming(
    socket_fd: std.posix.fd_t,
    hash_hex: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const controller = block_controller orelse {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "BlockController not initialized",
        );
    };

    if (hash_hex.len != 64) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid hash length (expected 64 hex chars)",
        );
    }

    // Конвертируем hex в bytes
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hash_hex) catch {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid hex hash",
        );
    };

    // Получаем metadata чтобы узнать размер (проверяем существование блока)
    const metadata = controller.buddy_allocator.getBlock(hash) catch |err| {
        const status: u16 = if (err == error.BlockNotFound) 404 else 500;
        const msg = if (err == error.BlockNotFound)
            "Block not found"
        else
            "Internal server error";

        const error_response = try generateHttpResponse(
            allocator,
            status,
            "text/plain",
            msg,
        );
        _ = try std.posix.write(socket_fd, error_response);
        return &[_]u8{};
    };
    const data_size = metadata.data_size;

    // Сначала отправляем HTTP заголовок с Content-Length
    const header = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n",
        .{data_size},
    );
    defer allocator.free(header);

    // Отправляем заголовок в socket (через обычный write, не io_uring)
    _ = try std.posix.write(socket_fd, header);

    // Потоково читаем из файла и пишем в socket
    controller.readBlockToSocket(hash, socket_fd) catch |err| {
        // Ошибка уже после отправки заголовка - просто закрываем соединение
        std.debug.print("Error streaming block to socket: {}\n", .{err});
        return error.StreamError;
    };

    // Возвращаем пустой ответ - данные уже отправлены
    return &[_]u8{};
}

/// DELETE /block/<hash> - удаляет блок
pub fn handleDelete(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
    const controller = block_controller orelse {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "BlockController not initialized",
        );
    };

    // Извлекаем хеш из пути
    const path = request.params.path;
    const prefix = "/block/";

    if (!std.mem.startsWith(u8, path, prefix)) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid path format",
        );
    }

    const hex_hash = path[prefix.len..];
    if (hex_hash.len != 64) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid hash length",
        );
    }

    // Конвертируем hex в bytes
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hex_hash) catch {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Invalid hex hash",
        );
    };

    // Удаляем через BlockController
    controller.deleteBlock(hash) catch |err| {
        const status: u16 = if (err == error.BlockNotFound) 404 else 500;
        const msg = if (err == error.BlockNotFound)
            "Block not found"
        else
            "Internal server error";

        return try generateHttpResponse(
            allocator,
            status,
            "text/plain",
            msg,
        );
    };

    return try generateHttpResponse(
        allocator,
        200,
        "text/plain",
        "Block deleted",
    );
}
