const std = @import("std");
const Ring = @import("uring.zig").Ring;
const HttpServer = @import("http.zig").HttpServer;
const FileStorage = @import("file.zig").FileStorage;
const MockWorkerService = @import("mock_service.zig").MockWorkerService;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring = Ring.init(256) catch {
        std.process.exit(1);
    };
    defer ring.deinit();

    const storage_path = std.posix.getenv("STORAGE_FILE") orelse "/data/storage.dat";
    var file_storage = FileStorage.init(&ring, storage_path) catch |err| {
        std.debug.print("ERROR: Failed to open storage file '{s}': {}\n", .{ storage_path, err });
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
    std.debug.print("Storage file: {s}\n", .{storage_path});

    server.run() catch |err| {
        std.debug.print("ERROR: Server run failed: {}\n", .{err});
        std.process.exit(1);
    };
}
