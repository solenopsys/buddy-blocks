const std = @import("std");
const BuddyAllocator = @import("src/buddy_allocator.zig").BuddyAllocator;
const lmdbx = @import("src/lmdbx_wrapper.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Открываем БД
    var db = try lmdbx.Database.open("/tmp/test-buddy.db");
    defer db.close();

    // Создаем простой file controller
    var file_controller = BuddyAllocator.SimpleFileController.init();

    // Создаем buddy allocator
    var buddy = try BuddyAllocator.init(allocator, &db, file_controller.interface());
    defer buddy.deinit();

    // Тест 1: allocate 4KB блок
    var hash: [32]u8 = undefined;
    @memset(&hash, 0xAA);

    std.debug.print("Allocating 4KB block...\n", .{});
    const metadata = buddy.allocate(hash, 4096) catch |err| {
        std.debug.print("Allocate failed: {}\n", .{err});
        return err;
    };
    std.debug.print("Allocated! block_size={s}, block_num={}, offset={}\n",
        .{metadata.block_size.toString(), metadata.block_num, BuddyAllocator.getOffset(metadata)});

    // Тест 2: free блок
    std.debug.print("Freeing block...\n", .{});
    try buddy.free(hash);
    std.debug.print("Freed successfully!\n", .{});

    std.debug.print("All tests passed!\n", .{});
}
