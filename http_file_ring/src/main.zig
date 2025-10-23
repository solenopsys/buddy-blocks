const std = @import("std");
const Ring = @import("uring.zig").Ring;
const HttpServer = @import("http.zig").HttpServer;
const FileStorage = @import("file.zig").FileStorage;
const MockWorkerService = @import("mock_service.zig").MockWorkerService;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ring = try Ring.init(256);
    defer ring.deinit();

    var file_storage = try FileStorage.init(&ring, "storage.dat");
    defer file_storage.deinit();

    var mock_service = MockWorkerService.init();
    const service = mock_service.interface();

    var server = try HttpServer.init(allocator, &ring, 8080, service, &file_storage);
    defer server.deinit();

    std.debug.print("Server starting on port 8080...\n", .{});
    std.debug.print("Storage file: storage.dat\n", .{});

    try server.run();
}
