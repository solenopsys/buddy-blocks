//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

// Infrastructure
pub const types = @import("infrastructure/types.zig");
pub const buddy_allocator = @import("infrastructure/buddy_allocator.zig");
pub const file_controller = @import("infrastructure/file_controller.zig");

// Use lmdbx from buddy_allocator module instead of local implementation
const buddy_mod = @import("buddy_allocator");
pub const lmdbx = buddy_mod.lmdbx;

// Messaging
pub const messages = @import("messaging/messages.zig");
pub const message_queue = @import("messaging/message_queue.zig");
pub const interfaces = @import("messaging/interfaces.zig");

// Controller
pub const controller_handler = @import("controller/handler.zig");
pub const controller = @import("controller/controller.zig");

// Worker
pub const block_pool = @import("worker/block_pool.zig");
pub const worker = @import("worker/worker.zig");

// Re-export for convenience
pub const Message = messages.Message;
pub const IMessageQueue = interfaces.IMessageQueue;
pub const IControllerHandler = interfaces.IControllerHandler;
pub const IBlockPool = interfaces.IBlockPool;
pub const BlockInfo = interfaces.BlockInfo;

// Test imports to trigger test discovery
test {
    std.testing.refAllDecls(@This());
    _ = messages;
    _ = message_queue;
    _ = controller_handler;
    _ = controller;
    _ = block_pool;
    _ = worker;
}
