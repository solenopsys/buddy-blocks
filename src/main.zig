const std = @import("std");
const Server = @import("./server.zig").Server;
const Thread = std.Thread;
const lmdbx_handlers = @import("./lmdbx-handlers.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = 10001;

    // Инициализируем БД один раз в главном потоке
    // LMDBX поддерживает множественные читатели, но открытие должно быть в одном процессе
    lmdbx_handlers.initDatabase("/tmp/fastblock.db") catch |err| {
        std.debug.print("Failed to initialize database: {}\n", .{err});
        return;
    };
    defer lmdbx_handlers.deinitDatabase();

    // Определяем количество воркеров
    const num_workers: usize = 4;

    std.debug.print("Starting {d} workers\n", .{num_workers});

    // Создаем воркеры
    const workers = try allocator.alloc(Server, num_workers);
    defer allocator.free(workers);

    for (workers) |*worker| {
        worker.* = try Server.init(allocator, port);
    }
    defer for (workers) |*worker| worker.deinit();

    // Создаем потоки
    const threads = try allocator.alloc(Thread, num_workers);
    defer allocator.free(threads);

    // Запускаем каждый воркер в отдельном потоке
    for (threads, 0..) |*thread, i| {
        thread.* = try Thread.spawn(.{}, workerMain, .{&workers[i]});
    }

    // Ждем завершения всех потоков
    for (threads) |thread| {
        thread.join();
    }
}

fn workerMain(server: *Server) void {
    server.start() catch |err| {
        std.debug.print("Worker error: {}\n", .{err});
    };
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
