# Buddy Blocks Storage Server

High-performance HTTP server for block data storage using io_uring, lock-free queues, and buddy allocator.

## Features

- **io_uring**: Asynchronous I/O for maximum performance
- **Lock-free architecture**: SPSC queues for inter-thread communication without locks
- **Buddy Allocator**: Efficient management of data blocks from 4KB to 512KB
- **LMDBX**: Fast database for storing block metadata
- **Multi-threaded**: Multiple HTTP worker threads with SO_REUSEPORT + single controller thread
- **Batch processing**: Controller processes requests in batches to minimize DB operations

## Requirements

- Zig 0.15.1 or newer
- Linux with io_uring support (kernel 5.1+)
- liblmdbx (built automatically from zig-lmdbx dependency)

## Building

### Building for host (GNU/Linux)

```bash
# Clone dependencies
git clone https://github.com/your-repo/zig-lmdbx ../zig-lmdbx
git clone https://github.com/your-repo/zig-pico ../zig-pico

# Build liblmdbx for all architectures
cd ../zig-lmdbx
zig build -Dall=true
cd ../buddy-blocks

# Build server for GNU (default)
zig build -Doptimize=ReleaseFast

# Binary: zig-out/bin/buddy-blocks-gnu
```

### Building for Alpine/musl

```bash
# Build for musl
zig build -Dmusl=true -Doptimize=ReleaseFast

# Binary: zig-out/bin/buddy-blocks-musl
```

### Building container (Podman/Docker)

```bash
# Build both binaries
zig build -Doptimize=ReleaseFast
zig build -Dmusl=true -Doptimize=ReleaseFast

# Build container
podman build -t buddy-blocks:latest .
# or
docker build -t buddy-blocks:latest .
```

## Running

### Running on host

```bash
# Run GNU version
LD_LIBRARY_PATH=../zig-lmdbx/zig-out/lib ./zig-out/bin/buddy-blocks-gnu

# Or via zig build
zig build run
```

Server will listen on `0.0.0.0:10001`

### Running in container

```bash
# Run with privileges (required for io_uring)
podman run -d --name buddy-blocks \
  --privileged \
  -p 10001:10001 \
  buddy-blocks:latest

# Or with Docker
docker run -d --name buddy-blocks \
  --privileged \
  -p 10001:10001 \
  buddy-blocks:latest
```

**Important**: The `--privileged` flag is required for io_uring to work in containers.

### Checking operation

```bash
# Check logs
podman logs buddy-blocks

# Test PUT request
curl -X PUT http://localhost:10001/block -d "test data"

# Get block by hash
curl http://localhost:10001/block/<hash>
```

## API

### PUT /block - Upload block

Uploads a data block and returns SHA256 hash.

```bash
# Upload file
curl -X PUT --data-binary @file.bin http://localhost:10001/block

# Upload text data
echo "Hello, World!" | curl -X PUT --data-binary @- http://localhost:10001/block
```

**Response:**
```
HTTP/1.1 200 OK
Content-Type: text/plain

a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

**Limitations:**
- Maximum block size: 512KB

### GET /block/\<hash\> - Download block

Downloads data block by SHA256 hash.

```bash
curl http://localhost:10001/block/a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e -o output.bin
```

**Response:**
```
HTTP/1.1 200 OK
Content-Type: application/octet-stream

<binary data>
```

### DELETE /block/\<hash\> - Delete block

Deletes data block.

```bash
curl -X DELETE http://localhost:10001/block/a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

**Response:**
```
HTTP/1.1 200 OK
Content-Type: text/plain

Block deleted
```

## Architecture

```
  ┌─────────────────────┐
  │   Client Requests   │
  │    (port 10001)     │
  └──────────┬──────────┘
             │ Kernel load balancing (SO_REUSEPORT)
       ┌─────┴─────┬─────┬─────┐
       │           │     │     │
  ┌────▼───┐ ┌────▼┐ ┌──▼──┐ ┌▼────┐
  │Worker 0│ │Wkr 1│ │Wkr 2│ │Wkr 3│  ← HTTP workers (io_uring)
  └────┬───┘ └────┬┘ └──┬──┘ └┬────┘
       │         │     │     │
       │    SPSC Queues (lock-free)
       │         │     │     │
       └─────────┴─────┴─────┘
                 │
          ┌──────▼───────┐
          │  Controller  │  ← Batch processing, single
          │   Thread     │     LMDBX accessor
          └──────┬───────┘
                 │
          ┌──────▼───────┐
          │    LMDBX     │  ← Block metadata
          │   Database   │
          └──────────────┘
```

### Components

- **HttpWorker (src/worker/)**: HTTP worker with io_uring, handles client requests
- **BatchController (src/controller/)**: Batch controller, single thread with LMDBX access
- **BuddyAllocator (buddy_allocator/)**: Buddy allocator for efficient block management
- **SPSC Queues**: Lock-free queues for inter-thread communication
- **Block Pools**: Cache of free blocks for each worker

### Data flow

**PUT request:**
1. Worker accepts HTTP request via io_uring
2. Calculates SHA256 hash of request body
3. Sends `occupy_block` message to controller via SPSC queue
4. Controller reserves block in LMDBX and returns offset
5. Worker writes data to file via io_uring at received offset
6. Returns hash to client

**GET request:**
1. Worker accepts HTTP request
2. Sends `get_address` message to controller
3. Controller returns offset and size from LMDBX
4. Worker reads data from file via io_uring and sends to client

## Configuration

Parameters can be changed in `src/main.zig`:

```zig
const Config = struct {
    port: u16 = 10001,                    // Server port
    num_workers: u8 = 4,                  // Number of HTTP workers
    controller_cycle_ns: i128 = 20_000,   // Controller cycle interval (20µs)
    queue_capacity: usize = 4096,         // SPSC queue capacity
};
```

## Performance

Tests conducted on system with Zig 0.15.1, Linux 6.16.11:

**In container (Alpine musl, --privileged):**
- PUT: 3,398 ops/sec (13.27 MB/s)
- GET: 1,774 rps (sustained load)
- Average latency: 1.13ms

**On host (GNU glibc):**
- PUT: 3,567 ops/sec (13.93 MB/s)
- GET: 1,753 rps (sustained load)
- Average latency: 1.14ms

### Performance testing

```bash
# Run Go benchmark
cd tests
go run rps.go -blocks 1000 -concurrency 2

# Parameters:
# -blocks N       - number of unique blocks for test
# -concurrency N  - number of concurrent workers
# -duration 10s   - sustained load test duration
```

## Testing

```bash
# Run unit tests
zig build test

# Integration test
cd tests
python3 test_basic_operations.py
```

## License

Apache 2.0
