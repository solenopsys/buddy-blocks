const std = @import("std");
const lmdbx = @import("lmdbx");
const types = @import("types.zig");
const buddy = @import("buddy_allocator.zig");

const BuddyAllocator = buddy.BuddyAllocator;
const SimpleFileController = buddy.SimpleFileController;
const Database = lmdbx.Database;

fn cleanupTestFiles() void {
    std.fs.cwd().deleteFile("/tmp/buddy_bench.db") catch {};
    std.fs.cwd().deleteFile("/tmp/buddy_bench.db-lock") catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== BUDDY ALLOCATOR BENCHMARK ===\n", .{});

    cleanupTestFiles();
    defer cleanupTestFiles();

    std.debug.print("Opening database...\n", .{});
    var db = try Database.open("/tmp/buddy_bench.db");
    defer db.close();

    std.debug.print("Initializing file controller...\n", .{});
    var file_controller = SimpleFileController.init();
    const file_iface = file_controller.interface();

    std.debug.print("Initializing buddy allocator...\n", .{});
    var buddy_alloc = try BuddyAllocator.init(allocator, &db, file_iface);
    defer buddy_alloc.deinit();

    // Parameters
    const init_count_blocks: u64 = 10000000; // Database initialization size
    const test_count_blocks: u64 = 10000;    // Test operations count

    // === PHASE 1: DATABASE INITIALIZATION ===
    std.debug.print("\n[INIT] Initializing database with {d} blocks...\n", .{init_count_blocks});

    var init_hashes = try allocator.alloc([32]u8, init_count_blocks);
    defer allocator.free(init_hashes);

    for (0..init_count_blocks) |i| {
        std.crypto.random.bytes(&init_hashes[i]);
    }

    const init_start = std.time.nanoTimestamp();
    for (0..init_count_blocks) |i| {
        _ = try buddy_alloc.allocate(init_hashes[i], 100);

        // Progress indicator
        if ((i + 1) % 100000 == 0) {
            std.debug.print("[INIT] Loaded {d}/{d} blocks...\n", .{ i + 1, init_count_blocks });
        }
    }
    const init_end = std.time.nanoTimestamp();
    const init_time = @as(f64, @floatFromInt(init_end - init_start)) / 1_000_000_000.0;
    std.debug.print("[INIT] ✓ Database initialized: {d} blocks in {d:.2}s\n", .{ init_count_blocks, init_time });

    // Measure database size on disk
    const db_file = try std.fs.cwd().openFile("/tmp/buddy_bench.db", .{});
    defer db_file.close();
    const db_stat = try db_file.stat();
    const db_size_mb = @as(f64, @floatFromInt(db_stat.size)) / (1024.0 * 1024.0);
    std.debug.print("[INIT] Database size on disk: {d:.2} MB\n", .{db_size_mb});

    // === PHASE 2: PERFORMANCE TEST ===
    std.debug.print("\n[TEST] Starting performance test with {d} operations...\n", .{test_count_blocks});

    // Prepare test hashes
    var hashes = try allocator.alloc([32]u8, test_count_blocks);
    defer allocator.free(hashes);

    for (0..test_count_blocks) |i| {
        std.crypto.random.bytes(&hashes[i]);
    }

    // ALLOCATE
    std.debug.print("[TEST] Allocating...\n", .{});
    const alloc_start = std.time.nanoTimestamp();

    for (0..test_count_blocks) |i| {
        _ = try buddy_alloc.allocate(hashes[i], 100);
    }

    const alloc_end = std.time.nanoTimestamp();
    const alloc_time = @as(f64, @floatFromInt(alloc_end - alloc_start)) / 1_000_000_000.0;
    const alloc_ops = @as(f64, @floatFromInt(test_count_blocks)) / alloc_time;
    std.debug.print("[TEST] Allocate: {d:.0} ops/sec ({d} ops in {d:.2}s)\n", .{ alloc_ops, test_count_blocks, alloc_time });

    // GET
    std.debug.print("[TEST] Reading...\n", .{});
    const get_start = std.time.nanoTimestamp();

    for (0..test_count_blocks) |i| {
        _ = try buddy_alloc.getBlock(hashes[i]);
    }

    const get_end = std.time.nanoTimestamp();
    const get_time = @as(f64, @floatFromInt(get_end - get_start)) / 1_000_000_000.0;
    const get_ops = @as(f64, @floatFromInt(test_count_blocks)) / get_time;
    std.debug.print("[TEST] Get: {d:.0} ops/sec ({d} ops in {d:.2}s)\n", .{ get_ops, test_count_blocks, get_time });

    // FREE
    std.debug.print("[TEST] Freeing...\n", .{});
    const free_start = std.time.nanoTimestamp();

    for (0..test_count_blocks) |i| {
        try buddy_alloc.free(hashes[i]);
    }

    const free_end = std.time.nanoTimestamp();
    const free_time = @as(f64, @floatFromInt(free_end - free_start)) / 1_000_000_000.0;
    const free_ops = @as(f64, @floatFromInt(test_count_blocks)) / free_time;
    std.debug.print("[TEST] Free: {d:.0} ops/sec ({d} ops in {d:.2}s)\n", .{ free_ops, test_count_blocks, free_time });

    std.debug.print("\n[TEST] ✓ Performance test completed\n", .{});
    std.debug.print("\n=== SUMMARY ===\n", .{});
    std.debug.print("Database size: {d} blocks ({d:.2} MB on disk)\n", .{ init_count_blocks + test_count_blocks, db_size_mb });
    std.debug.print("Test operations: {d}\n", .{test_count_blocks});
    std.debug.print("Allocate: {d:.0} ops/sec\n", .{alloc_ops});
    std.debug.print("Get: {d:.0} ops/sec\n", .{get_ops});
    std.debug.print("Free: {d:.0} ops/sec\n", .{free_ops});
}
