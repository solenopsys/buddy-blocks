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
        handle_has_block: *const fn (ptr: *anyopaque, msg: messages.HasBlockRequest) anyerror!messages.HasBlockResult,
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

    pub fn handleHasBlock(self: IControllerHandler, msg: messages.HasBlockRequest) !messages.HasBlockResult {
        return self.vtable.handle_has_block(self.ptr, msg);
    }
};

/// Информация о блоке для пула Worker'а
pub const BlockInfo = struct {
    size: u8, // Индекс размера блока (0=4k, 1=8k, ..., 7=512k)
    block_num: u64,

    /// Вычисляет offset в файле данных
    pub fn getOffset(self: BlockInfo) u64 {
        const size_bytes = sizeToBytes(self.size);
        return self.block_num * size_bytes;
    }

    /// Конвертирует индекс размера в байты
    fn sizeToBytes(size_index: u8) u64 {
        return switch (size_index) {
            0 => 4096,      // 4KB
            1 => 8192,      // 8KB
            2 => 16384,     // 16KB
            3 => 32768,     // 32KB
            4 => 65536,     // 64KB
            5 => 131072,    // 128KB
            6 => 262144,    // 256KB
            7 => 524288,    // 512KB
            else => 4096,   // default to 4KB
        };
    }
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
