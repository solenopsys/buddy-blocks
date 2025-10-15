const std = @import("std");
const Server = @import("./server.zig").Server;
const Thread = std.Thread;
const block_handlers = @import("./block_handlers.zig");
const BlockController = @import("./block_controller_adapter.zig").BlockController;
const BuddyAllocator = @import("buddy_allocator").BuddyAllocator;
const FileController = @import("./file_controller.zig").FileController;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = 10001;

    // Инициализируем LMDBX database
    const lmdbx = @import("buddy_allocator").lmdbx;
    var db = try lmdbx.Database.open("/tmp/buddy-blocks.db");
    defer db.close();

    // Инициализируем FileController
    var file_controller = try FileController.init(allocator, "/tmp/buddy-blocks.data");
    defer file_controller.deinit();

    // Инициализируем BuddyAllocator
    var buddy_allocator = try BuddyAllocator.init(
        allocator,
        &db,
        file_controller.interface(),
    );
    defer buddy_allocator.deinit();

    // Инициализируем BlockController
    var block_controller = try BlockController.init(allocator, buddy_allocator, &file_controller);
    defer block_controller.deinit();

    // Регистрируем глобальный BlockController для handlers
    block_handlers.initBlockController(block_controller);

    // Определяем количество воркеров
    const num_workers: usize = 4;

    std.debug.print("Starting server with {d} workers\n", .{num_workers});

    // Создаем ОДИН сервер с num_workers потоками
    var server = try Server.init(allocator, port, num_workers);
    defer server.deinit();

    // Запускаем сервер (он сам создаст workers)
    try server.start();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
