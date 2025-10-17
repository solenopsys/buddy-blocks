const std = @import("std");
const messages = @import("messages.zig");

/// Интерфейс для SPSC очереди сообщений
pub const IMessageQueue = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push: *const fn (ptr: *anyopaque, msg: messages.Message) bool,
        pop: *const fn (ptr: *anyopaque, out: *messages.Message) bool,
        len: *const fn (ptr: *anyopaque) usize,
    };

    pub fn push(self: IMessageQueue, msg: messages.Message) bool {
        return self.vtable.push(self.ptr, msg);
    }

    pub fn pop(self: IMessageQueue, out: *messages.Message) bool {
        return self.vtable.pop(self.ptr, out);
    }

    pub fn len(self: IMessageQueue) usize {
        return self.vtable.len(self.ptr);
    }
};

/// Интерфейс для обработчика сообщений Controller'а
pub const IControllerHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle_allocate: *const fn (ptr: *anyopaque, msg: messages.AllocateRequest) anyerror!messages.AllocateResult,
        handle_occupy: *const fn (ptr: *anyopaque, msg: messages.OccupyRequest) anyerror!messages.OccupyResult,
        handle_release: *const fn (ptr: *anyopaque, msg: messages.ReleaseRequest) anyerror!void,
        handle_get_address: *const fn (ptr: *anyopaque, msg: messages.GetAddressRequest) anyerror!messages.GetAddressResult,
    };

    pub fn handleAllocate(self: IControllerHandler, msg: messages.AllocateRequest) !messages.AllocateResult {
        return self.vtable.handle_allocate(self.ptr, msg);
    }

    pub fn handleOccupy(self: IControllerHandler, msg: messages.OccupyRequest) !messages.OccupyResult {
        return self.vtable.handle_occupy(self.ptr, msg);
    }

    pub fn handleRelease(self: IControllerHandler, msg: messages.ReleaseRequest) !void {
        return self.vtable.handle_release(self.ptr, msg);
    }

    pub fn handleGetAddress(self: IControllerHandler, msg: messages.GetAddressRequest) !messages.GetAddressResult {
        return self.vtable.handle_get_address(self.ptr, msg);
    }
};

/// Информация о блоке для пула Worker'а
pub const BlockInfo = struct {
    offset: u64,
    size: u8,
    block_num: u64,
};

/// Интерфейс для пула блоков Worker'а
pub const IBlockPool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        acquire: *const fn (ptr: *anyopaque) ?BlockInfo,
        release: *const fn (ptr: *anyopaque, block: BlockInfo) void,
        needs_refill: *const fn (ptr: *anyopaque) bool,
        get_size: *const fn (ptr: *anyopaque) u8,
    };

    pub fn acquire(self: IBlockPool) ?BlockInfo {
        return self.vtable.acquire(self.ptr);
    }

    pub fn release(self: IBlockPool, block: BlockInfo) void {
        self.vtable.release(self.ptr, block);
    }

    pub fn needsRefill(self: IBlockPool) bool {
        return self.vtable.needs_refill(self.ptr);
    }

    pub fn getSize(self: IBlockPool) u8 {
        return self.vtable.get_size(self.ptr);
    }
};
