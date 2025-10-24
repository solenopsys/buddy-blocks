const std = @import("std");
const posix = std.posix;
const Thread = std.Thread;

// Import components from buddy-blocks module
const bb = @import("buddy-blocks");
const lmdbx = bb.lmdbx;
const FileController = bb.file_controller.FileController;
const BuddyAllocator = bb.buddy_allocator.BuddyAllocator;
const messages = bb.messages;
const message_queue = bb.message_queue;
const controller = bb.controller;
const controller_handler = bb.controller_handler;
const worker = bb.worker;
const block_pool = bb.block_pool;

/// Configuration
const Config = struct {
    port: u16 = 10001,
    num_workers: u8 = 4,
    data_file: [:0]const u8 = "/tmp/fastblock.data",
    db_path: [:0]const u8 = "/tmp/buddy-blocks.db",

    /// Block pool target sizes for each block size (0-7)
    pool_targets: [8]usize = .{
        10, // 4KB
        10, // 8KB
        10, // 16KB
        5, // 32KB
        5, // 64KB
        3, // 128KB
        2, // 256KB
        2, // 512KB
    },

    /// Controller cycle interval in nanoseconds (20µs)
    controller_cycle_ns: i128 = 20_000,

    /// SPSC queue capacity
    queue_capacity: usize = 4096,
};

/// System state
const System = struct {
    allocator: std.mem.Allocator,
    config: Config,

    // Infrastructure
    db: *lmdbx.Database,
    file_controller: *FileController,
    buddy_allocator: *BuddyAllocator,
    data_file_fd: posix.fd_t,

    // Controller
    controller_handler: *controller_handler.BuddyControllerHandler,
    batch_controller: *controller.BatchController,
    controller_thread: ?Thread,

    // Workers
    workers: []worker.HttpWorker,
    worker_threads: []Thread,

    // SPSC Queues (lifetime management)
    queues_storage: []QueuePair,
    worker_queues: []controller.WorkerQueues,

    // Block pools (lifetime management)
    pools_storage: [][8]block_pool.SimpleBlockPool,
    pools_interfaces: [][8]bb.interfaces.IBlockPool,

    fn deinit(self: *System) void {
        std.debug.print("Shutting down system...\n", .{});

        // Signal shutdown
        self.batch_controller.shutdown();
        for (self.workers) |*w| {
            w.shutdown();
        }

        // Wait for threads
        if (self.controller_thread) |t| {
            t.join();
        }
        for (self.worker_threads) |t| {
            t.join();
        }

        // Cleanup workers
        for (self.workers) |*w| {
            w.deinit();
        }
        self.allocator.free(self.workers);
        self.allocator.free(self.worker_threads);

        // Cleanup pools
        for (self.pools_storage) |*pools| {
            for (pools) |*pool| {
                pool.deinit();
            }
        }
        self.allocator.free(self.pools_storage);
        self.allocator.free(self.pools_interfaces);

        // Cleanup queues
        for (self.queues_storage) |*qpair| {
            qpair.from_worker.deinit();
            qpair.to_worker.deinit();
        }
        self.allocator.free(self.queues_storage);
        self.allocator.free(self.worker_queues);

        // Cleanup controller
        self.batch_controller.deinit();
        self.allocator.destroy(self.batch_controller);
        self.allocator.destroy(self.controller_handler);

        // Cleanup infrastructure
        self.buddy_allocator.deinit();
        self.file_controller.deinit();
        self.allocator.destroy(self.file_controller);
        self.db.close();
        self.allocator.destroy(self.db);
        posix.close(self.data_file_fd);

        std.debug.print("Shutdown complete\n", .{});
    }
};

const QueuePair = struct {
    from_worker: message_queue.RealMessageQueue,
    to_worker: message_queue.RealMessageQueue,
};

/// Initialize complete system
fn initSystem(allocator: std.mem.Allocator, config: Config) !System {
    std.debug.print("Initializing buddy-blocks system...\n", .{});
    std.debug.print("  Port: {d}\n", .{config.port});
    std.debug.print("  Workers: {d}\n", .{config.num_workers});
    const data_file_path = std.mem.sliceTo(config.data_file, 0);
    const db_path = std.mem.sliceTo(config.db_path, 0);
    std.debug.print("  Data file: {s}\n", .{data_file_path});
    std.debug.print("  DB path: {s}\n", .{db_path});

    // Initialize LMDBX
    std.debug.print("Opening LMDBX database...\n", .{});
    const db = try allocator.create(lmdbx.Database);
    errdefer allocator.destroy(db);
    db.* = try lmdbx.Database.open(config.db_path);

    // Initialize FileController
    std.debug.print("Opening data file...\n", .{});
    const file_controller = try allocator.create(FileController);
    errdefer allocator.destroy(file_controller);
    file_controller.* = try FileController.init(allocator, data_file_path);

    // Get data file FD for workers
    const data_file_fd = file_controller.fd;

    // Initialize BuddyAllocator
    std.debug.print("Initializing BuddyAllocator...\n", .{});
    const buddy_allocator = try BuddyAllocator.init(
        allocator,
        db,
        file_controller.interface(),
    );

    // Recover temp blocks (crash recovery)
    std.debug.print("Recovering temp blocks...\n", .{});
    try buddy_allocator.recoverTempBlocks();

    // Initialize controller handler
    const ctrl_handler = try allocator.create(controller_handler.BuddyControllerHandler);
    ctrl_handler.* = controller_handler.BuddyControllerHandler.init(buddy_allocator);

    // Create SPSC queues for each worker
    std.debug.print("Creating SPSC queues for {d} workers...\n", .{config.num_workers});
    const queues_storage = try allocator.alloc(QueuePair, config.num_workers);
    errdefer allocator.free(queues_storage);

    const worker_queues = try allocator.alloc(controller.WorkerQueues, config.num_workers);
    errdefer allocator.free(worker_queues);

    for (queues_storage, 0..) |*qpair, i| {
        qpair.from_worker = try message_queue.RealMessageQueue.init(allocator, config.queue_capacity);
        errdefer qpair.from_worker.deinit();

        qpair.to_worker = try message_queue.RealMessageQueue.init(allocator, config.queue_capacity);
        errdefer qpair.to_worker.deinit();

        worker_queues[i] = .{
            .from_worker = qpair.from_worker.interface(),
            .to_worker = qpair.to_worker.interface(),
        };
    }

    // Create BatchController
    std.debug.print("Creating BatchController...\n", .{});
    const batch_controller = try allocator.create(controller.BatchController);
    batch_controller.* = try controller.BatchController.init(
        allocator,
        ctrl_handler.interface(),
        worker_queues,
        config.controller_cycle_ns,
        db,
    );

    // Create block pools for each worker
    std.debug.print("Creating block pools...\n", .{});
    const pools_storage = try allocator.alloc([8]block_pool.SimpleBlockPool, config.num_workers);
    errdefer allocator.free(pools_storage);

    const pools_interfaces = try allocator.alloc([8]bb.interfaces.IBlockPool, config.num_workers);
    errdefer allocator.free(pools_interfaces);

    for (pools_storage, 0..) |*pools, worker_idx| {
        for (pools, 0..) |*pool, size_idx| {
            pool.* = try block_pool.SimpleBlockPool.init(
                allocator,
                @intCast(size_idx),
                config.pool_targets[size_idx],
            );
            pools_interfaces[worker_idx][size_idx] = pool.interface();
        }
    }

    // Create workers (without starting HTTP servers yet)
    std.debug.print("Creating {d} HTTP workers...\n", .{config.num_workers});
    const workers = try allocator.alloc(worker.HttpWorker, config.num_workers);
    errdefer allocator.free(workers);

    for (workers, 0..) |*w, i| {
        const worker_id: u8 = @intCast(i);

        try worker.HttpWorker.init(
            w,
            worker_id,
            allocator,
            config.port, // All workers listen on the SAME port (SO_REUSEPORT)
            data_file_fd,
            pools_interfaces[i],
            worker_queues[i].from_worker, // worker writes here
            worker_queues[i].to_worker, // worker reads from here
            config.controller_cycle_ns, // timing interval
        );

        std.debug.print("  Worker {d} initialized (port will be opened after pool prefill)\n", .{worker_id});
    }

    return .{
        .allocator = allocator,
        .config = config,
        .db = db,
        .file_controller = file_controller,
        .buddy_allocator = buddy_allocator,
        .data_file_fd = data_file_fd,
        .controller_handler = ctrl_handler,
        .batch_controller = batch_controller,
        .controller_thread = null,
        .workers = workers,
        .worker_threads = &.{},
        .queues_storage = queues_storage,
        .worker_queues = worker_queues,
        .pools_storage = pools_storage,
        .pools_interfaces = pools_interfaces,
    };
}

/// Prefill worker pools before starting HTTP servers
fn prefillWorkerPools(sys: *System) !void {
    std.debug.print("\nPrefilling worker block pools...\n", .{});

    // Start controller thread first (needed for pool prefilling)
    std.debug.print("  Starting controller thread...\n", .{});
    sys.controller_thread = try Thread.spawn(.{}, runController, .{sys.batch_controller});

    // Give controller time to start
    std.Thread.sleep(std.time.ns_per_ms * 100);

    // Prefill each worker's pools
    for (sys.workers) |*w| {
        try w.prefillPools(sys.config.pool_targets);
    }

    std.debug.print("Pool prefilling complete\n\n", .{});
}

/// Start HTTP servers on all workers
fn startHttpServers(sys: *System) !void {
    std.debug.print("Starting HTTP servers...\n", .{});

    for (sys.workers, 0..) |*w, i| {
        try w.startServer();
        std.debug.print("  Worker {d} listening on port {d} (SO_REUSEPORT)\n", .{ i, sys.config.port });
    }

    std.debug.print("All HTTP servers started\n\n", .{});
}

/// Start worker threads
fn startThreads(sys: *System) !void {
    std.debug.print("Starting worker threads...\n", .{});

    sys.worker_threads = try sys.allocator.alloc(Thread, sys.workers.len);

    for (sys.workers, 0..) |*w, i| {
        sys.worker_threads[i] = try Thread.spawn(.{}, runWorker, .{w});
    }

    std.debug.print("All worker threads started\n\n", .{});
}

fn runController(ctrl: *controller.BatchController) !void {
    std.debug.print("Controller thread started\n", .{});
    ctrl.run() catch |err| {
        std.debug.print("Controller error: {any}\n", .{err});
        return err;
    };
}

fn runWorker(w: *worker.HttpWorker) !void {
    w.run() catch |err| {
        std.debug.print("Worker {d} error: {any}\n", .{ w.id, err });
        return err;
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse config (can be extended to read from args/file)
    const config = Config{};

    // Initialize system
    var sys = try initSystem(allocator, config);
    defer sys.deinit();

    // Prefill worker pools (controller thread starts here)
    try prefillWorkerPools(&sys);

    // Start HTTP servers (opens ports)
    try startHttpServers(&sys);

    // Start worker threads
    try startThreads(&sys);

    // Print banner
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║      Buddy Blocks Storage Server v0.1.0      ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Multi-threaded architecture with:            ║\n", .{});
    std.debug.print("║  • {d} Worker threads (port {d}, SO_REUSEPORT) ║\n", .{
        config.num_workers,
        config.port,
    });
    std.debug.print("║  • 1 Controller thread (batch processing)    ║\n", .{});
    std.debug.print("║  • Lock-free SPSC queues                     ║\n", .{});
    std.debug.print("║  • Buddy allocator with LMDBX                ║\n", .{});
    std.debug.print("║  • io_uring for async I/O                    ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ API:                                          ║\n", .{});
    std.debug.print("║  PUT    /           - Upload block            ║\n", .{});
    std.debug.print("║  GET    /<hash>     - Download block          ║\n", .{});
    std.debug.print("║  DELETE /<hash>     - Delete block            ║\n", .{});
    std.debug.print("╠═══════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ Press Ctrl+C to shutdown                      ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server is running...\n\n", .{});

    // Wait for Ctrl+C
    // TODO: Implement signal handler for graceful shutdown
    // For now, just wait for controller thread
    if (sys.controller_thread) |t| {
        t.join();
    }
}
