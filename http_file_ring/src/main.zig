const std = @import("std");
const Ring = @import("uring.zig").Ring;
const HttpServer = @import("http.zig").HttpServer;
const FileStorage = @import("file.zig").FileStorage;
const MockWorkerService = @import("mock_service.zig").MockWorkerService;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring = Ring.init(256) catch |err| {
        std.debug.print("ERROR: Failed to initialize io_uring: {}\n", .{err});
        std.process.exit(1);
    };
    defer ring.deinit();

    var file_storage = FileStorage.init(&ring, "storage.dat") catch |err| {
        std.debug.print("ERROR: Failed to open storage file: {}\n", .{err});
        std.process.exit(1);
    };
    defer file_storage.deinit();

    var mock_service = MockWorkerService.init(allocator);
    defer mock_service.deinit();
    const service = mock_service.interface();

    var server = HttpServer.init(allocator, &ring, 8080, service, &file_storage) catch |err| {
        // Ошибка уже напечатана в createSocket
        if (err == error.AddressInUse) {
            std.process.exit(1);
        }
        std.debug.print("ERROR: Failed to initialize server: {}\n", .{err});
        std.process.exit(1);
    };
    defer server.deinit();

    std.debug.print("Server starting on port 8080...\n", .{});
    std.debug.print("Storage file: storage.dat\n", .{});

    server.run() catch |err| {
        std.debug.print("ERROR: Server run failed: {}\n", .{err});
        std.process.exit(1);
    };
}
