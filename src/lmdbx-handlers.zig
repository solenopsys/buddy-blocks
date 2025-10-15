const std = @import("std");
const picoRoot = @import("picozig");
const picozig = picoRoot.picozig;
const generateHttpResponse = picoRoot.response.generateHttpResponse;
const HttpRequest = picozig.HttpRequest;

// C API from liblmdbx.so
extern fn lmdbx_open(path: [*:0]const u8, db_ptr: *?*anyopaque) c_int;
extern fn lmdbx_close(db_ptr: ?*anyopaque) void;
extern fn lmdbx_put(db_ptr: ?*anyopaque, key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) c_int;
extern fn lmdbx_get(db_ptr: ?*anyopaque, key: [*]const u8, key_len: usize, value_ptr: *?[*]u8, value_len: *usize) c_int;
extern fn lmdbx_del(db_ptr: ?*anyopaque, key: [*]const u8, key_len: usize) c_int;
extern fn lmdbx_free(ptr: ?[*]u8, len: usize) void;

var db_handle: ?*anyopaque = null;

pub fn initDatabase(path: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const rc = lmdbx_open(@ptrCast(&path_buf), &db_handle);
    if (rc != 0) {
        return error.DatabaseOpenFailed;
    }
}

pub fn deinitDatabase() void {
    if (db_handle) |db| {
        lmdbx_close(db);
        db_handle = null;
    }
}

pub fn getDatabase() ?*anyopaque {
    return db_handle;
}

// Вычисляем SHA256 хеш от данных
fn computeHash(data: []const u8, hash_out: *[32]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    hasher.final(hash_out);
}

// PUT /block - сохраняет блок, возвращает хеш
pub fn handlePut(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
    if (db_handle == null) {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Database not initialized",
        );
    }

    const body = request.body;
    if (body.len == 0) {
        return try generateHttpResponse(
            allocator,
            400,
            "text/plain",
            "Empty body",
        );
    }

    // Вычисляем хеш
    var hash: [32]u8 = undefined;
    computeHash(body, &hash);

    // Сохраняем в БД
    const rc = lmdbx_put(db_handle, &hash, hash.len, body.ptr, body.len);
    if (rc != 0) {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Database put failed",
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

// GET /block/<hash> - получает блок по хешу
pub fn handleGet(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
    if (db_handle == null) {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Database not initialized",
        );
    }

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

    // Получаем из БД
    var value_ptr: ?[*]u8 = null;
    var value_len: usize = 0;
    const rc = lmdbx_get(db_handle, &hash, hash.len, &value_ptr, &value_len);

    if (rc == -2) {
        return try generateHttpResponse(
            allocator,
            404,
            "text/plain",
            "Block not found",
        );
    }

    if (rc != 0) {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Database get failed",
        );
    }

    // Копируем данные (т.к. они из C allocator)
    const data = value_ptr.?[0..value_len];
    const owned_data = try allocator.dupe(u8, data);

    // Освобождаем C память
    lmdbx_free(value_ptr, value_len);

    // Возвращаем бинарные данные
    return try generateHttpResponse(
        allocator,
        200,
        "application/octet-stream",
        owned_data,
    );
}

// DELETE /block/<hash> - удаляет блок
pub fn handleDelete(request: HttpRequest, allocator: std.mem.Allocator) ![]const u8 {
    if (db_handle == null) {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Database not initialized",
        );
    }

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

    // Удаляем из БД
    const rc = lmdbx_del(db_handle, &hash, hash.len);

    if (rc == -2) {
        return try generateHttpResponse(
            allocator,
            404,
            "text/plain",
            "Block not found",
        );
    }

    if (rc != 0) {
        return try generateHttpResponse(
            allocator,
            500,
            "text/plain",
            "Database delete failed",
        );
    }

    return try generateHttpResponse(
        allocator,
        200,
        "text/plain",
        "Block deleted",
    );
}
