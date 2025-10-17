const std = @import("std");

/// Общий тип для всех сообщений (передается через SPSC напрямую)
pub const Message = union(enum) {
    // От Worker → Controller
    allocate_block: AllocateRequest,
    occupy_block: OccupyRequest,
    release_block: ReleaseRequest,
    get_address: GetAddressRequest,

    // От Controller → Worker
    allocate_result: AllocateResult,
    occupy_result: OccupyResult,
    release_result: ReleaseResult,
    get_address_result: GetAddressResult,
    error_result: ErrorResult,
};

// === Запросы от Worker → Controller ===

pub const AllocateRequest = struct {
    worker_id: u8,
    request_id: u64,
    size: u8, // размер блока (enum index)
};

pub const OccupyRequest = struct {
    worker_id: u8,
    request_id: u64,
    hash: [32]u8,
    data_size: u64,
};

pub const ReleaseRequest = struct {
    worker_id: u8,
    request_id: u64,
    hash: [32]u8,
};

pub const GetAddressRequest = struct {
    worker_id: u8,
    request_id: u64,
    hash: [32]u8,
};

// === Ответы от Controller → Worker ===

pub const AllocateResult = struct {
    worker_id: u8,
    request_id: u64,
    offset: u64,
    size: u8,
    block_num: u64,
};

pub const OccupyResult = struct {
    worker_id: u8,
    request_id: u64,
    offset: u64,
    size: u64,
};

pub const ReleaseResult = struct {
    worker_id: u8,
    request_id: u64,
};

pub const GetAddressResult = struct {
    worker_id: u8,
    request_id: u64,
    offset: u64,
    size: u64,
};

pub const ErrorResult = struct {
    worker_id: u8,
    request_id: u64,
    code: ErrorCode,
};

pub const ErrorCode = enum(u8) {
    block_not_found = 0,
    allocation_failed = 1,
    invalid_size = 2,
    internal_error = 3,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Message types - basic structure" {
    const msg = Message{
        .allocate_block = .{
            .worker_id = 1,
            .request_id = 100,
            .size = 5,
        },
    };

    try testing.expectEqual(std.meta.Tag(Message).allocate_block, std.meta.activeTag(msg));
    try testing.expectEqual(@as(u8, 1), msg.allocate_block.worker_id);
    try testing.expectEqual(@as(u64, 100), msg.allocate_block.request_id);
    try testing.expectEqual(@as(u8, 5), msg.allocate_block.size);
}

test "ErrorCode enum" {
    const code = ErrorCode.block_not_found;
    try testing.expectEqual(@as(u8, 0), @intFromEnum(code));

    const code2 = ErrorCode.allocation_failed;
    try testing.expectEqual(@as(u8, 1), @intFromEnum(code2));
}
