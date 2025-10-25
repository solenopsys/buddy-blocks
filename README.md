![Logo](logo.svg)

# Buddy Blocks Node 



Buddy Blocks is a content-addressed block storage server written in Zig. It relies on Linux `io_uring`, LMDBX, and a custom buddy allocator to provide S3-class throughput on commodity hardware (even single-board computers).

## Overview

- High-performance HTTP API for PUT/GET/DELETE of 4 KB – 512 Kb blocks
- `io_uring`-driven workers with lock-free SPSC queues
- Single controller thread owns LMDBX metadata transactions
- Buddy allocator keeps one preallocated data file fragment-free
- Designed for decentralised networks and resource-constrained nodes

## Project Goals

- Deliver production-grade block storage for decentralised networks
- Run comfortably on $10 SBCs (Orange Pi / Raspberry Pi) with 1–2 GB RAM
- Match the operational profile of professional S3-compatible systems while remaining simple to operate and audit

## Current performance

Benchmarks (Zig 0.15.1, Linux 6.16.11): laptop 8 core processor

512K blocks
 - write 1449.09 ops/s | 724.55 MB/s ~ 6 Gb/s
 - read 2010.02 ops/s | 1100.50 MB/s ~ 9 Gb/s
 - ~1ms latency
 - only ~10Mb memory usage 


Currently, there are many bottlenecks and inefficiencies, so after addressing them, performance will increase by 5-10 times.




## Design Principles

1. **Stand on expert shoulders** – `io_uring` (~50k LOC) for async I/O, LMDBX (~40k LOC) for B-tree metadata, ~1k lines of Zig glue code.
2. **Let the kernel work** – batched syscalls, ring buffers, memory-mapped LMDBX, direct offset writes keep CPU usage low.
3. **One file, millions of blocks** – all payloads live inside a single data file, eliminating filesystem path churn and inode pressure.
4. **Adaptive block sizes** – buddy allocator serves 4 KB–512Kb chunks to minimise internal fragmentation.
5. **Cryptographic integrity** – SHA-256 hashes are first-class identifiers, proven in adversarial environments.
6. **Scale by layering** – a compact foundation today, ready for replication, DHT discovery, erasure coding, and proofs tomorrow.

## Architecture Overview

```
  ┌────────────────────┐
  │   Client Requests  │   port 10001
  └──────────┬─────────┘
             │  SO_REUSEPORT
       ┌─────┴─────┬─────┬─────┐
  ┌────▼───┐ ┌────▼┐ ┌──▼──┐ ┌▼────┐
  │Worker0 │ │Wkr1 │ │Wkr2 │ │Wkr3 │   io_uring HTTP workers
  └────┬───┘ └────┬┘ └──┬──┘ └┬────┘
       │ Lock-free SPSC queues (in/out per worker)
       └───────────┬───────────┬───────────┘
                   │
            ┌──────▼───────┐
            │  Controller  │   batches LMDBX ops
            └──────┬───────┘
                   │
            ┌──────▼───────┐
            │   LMDBX DB   │   hash → {offset, size}
            └──────────────┘
```

### Component Roles

- **HTTP workers (`src/worker/`)** – accept connections, compute SHA-256, manage local pools of free blocks, and issue I/O via `io_uring`.
- **Controller (`src/controller/`)** – the sole LMDBX accessor; batches allocate/free/get operations inside one transaction, then responds to workers.
- **Buddy allocator (`buddy_allocator/`)** – tracks block availability per size class and recycles freed space immediately.
- **Queues (`lib/` SPSC)** – per-worker request/response channels with no locks or contention.
- **Block pools** – each worker caches right-sized blocks so writes can stream directly into the data file.

### Worker Lifecycle

1. **Startup priming** – each worker inspects its per-size-class pools. If the free count for a class falls below the configured `target_free` threshold it sends an `allocate_block` request to the controller. The controller returns fresh blocks and the worker keeps them cached.
2. **Main loop** – HTTP parsing, hashing, and `io_uring` submission run inside one loop driven by completion events. At the top of the loop a fast check renews block pools the same way as during startup, so allocation happens opportunistically without adding latency to user requests.
3. **Streaming writes** – when a PUT arrives the worker immediately pops a preallocated block from the correct size class and streams the body straight into that offset inside the single data file. No extra copies, no filesystem metadata calls.
4. **Responses** – controller replies (e.g. occupation confirmation, lookup results) are consumed from the outbound queue, completing the request lifecycle.

The pools ensure that writes never stall on allocation as long as the controller keeps the pools topped up, and the worker never touches LMDBX directly.

### Controller Cycle

1. **Adaptive pause** – before each cycle the controller applies a rate-based pause regulator to balance CPU usage and latency under current load.
2. **Collect messages** – it drains every inbound queue, grouping messages by type (`get_address`, `allocate_block`, `free_block`, `occupy_block`) without sorting.
3. **Single transaction** – opens one LMDBX transaction and processes batched operations:
   - Reads (`get_address`) are handled immediately so GET latency remains tiny.
   - Frees are applied to LMDBX and returned blocks are handed back to the buddy allocator.
   - Allocation requests draw from the buddy allocator and are queued for response.
   - Occupy requests commit the final metadata binding `{hash → offset, size}`.
4. **Commit & reply** – the transaction is committed once, results are fanned out to worker outbound queues, and the controller returns to step 1.

With just one thread touching LMDBX there is no contention, while batching keeps transaction overhead negligible even at high RPS.

### Request Paths

**PUT**
1. Worker receives body, streams it into a reserved block.
2. SHA-256 hash is computed while reading.
3. Worker enqueues `occupy_block` to controller.
4. Controller reserves the block in LMDBX, returns success.
5. Worker responds with the hash identifier.

**GET**
1. Worker asks controller for `{offset, size}` via `get_address`.
2. Controller looks up LMDBX and replies from its batch.
3. Worker performs a zero-copy read via `io_uring` and streams the payload back.

**DELETE**
1. Worker sends `free_block`.
2. Controller clears metadata, hands the block back to the allocator.

## Resource Model

- One data file holds every block; no per-object files or directory traversal.
- Buddy allocator supports size classes: 4 KB, 8 KB, 16 KB, 32 KB, 64 KB, 128 KB, 256 KB, 512 KB.
- Target free counts per worker keep hot pools replenished without synchronisation.
- LMDBX stores hashes, offsets, and sizes (~110 bytes per record at 10M entries).

## LMDB Storage Structure

Buddy allocator uses LMDBX with three logical tables (all in one database):

### 1. Free List (available blocks)

**Key format:** `free_{size}_{block_num}`
- Example: `free_4k_123`, `free_8k_456`
- Size: `4k`, `8k`, `16k`, `32k`, `64k`, `128k`, `256k`, `512k`
- block_num: unique within size class

**Value:** 8 bytes
- buddy_num (u64, little-endian)

**Purpose:** Tracks available blocks ready for allocation

### 2. Temp List (allocated but not yet occupied)

**Key format:** `t_{size}_{block_num}`
- Example: `t_4k_123`, `t_8k_456`
- Block has been removed from free list and assigned to a worker
- Not yet written with data or bound to content hash

**Value:** 8 bytes
- buddy_num (u64, little-endian)

**Purpose:** Crash-safe intermediate state
- If process crashes: recovery scans `t_*` prefix and moves blocks back to free list
- Prevents double-allocation: same block can't be given to multiple workers
- Prevents block loss: block is always in exactly one of three states

### 3. Hash Table (occupied blocks)

**Key format:** 32 bytes (SHA-256 hash)
- Raw binary hash of block content

**Value:** BlockMetadata (encoded)
- block_size: enum (1 byte)
- block_num: u64 (8 bytes)
- buddy_num: u64 (8 bytes)
- data_size: u64 (8 bytes) - actual content size

**Purpose:** Maps content hash to physical block location

### State Transitions

```
[free_4k_123] --allocate--> [t_4k_123] --occupy--> [hash → metadata]
                                ↑                         |
                                |                         |
                                +--------free-------------+
```

**Crash Recovery:**
- Scan all keys with prefix `t_`
- For each `t_{size}_{block_num}`, read buddy_num
- Write `free_{size}_{block_num}` = buddy_num
- Delete `t_{size}_{block_num}`
- Result: all temp blocks returned to free list

## Building

Requires Zig 0.15.1+, Linux 5.1+ with `io_uring`, and LMDBX (fetched via `zig-lmdbx` dependency).

### GNU/Linux host (glibc)

```bash
# Build LMDBX (single time)
git clone https://github.com/your-repo/zig-lmdbx ../zig-lmdbx
(cd ../zig-lmdbx && zig build -Dall=true)

# Build Buddy Blocks
zig build -Doptimize=ReleaseFast
# Output: zig-out/bin/buddy-blocks-gnu
```

### Alpine / musl target

```bash
zig build -Dmusl=true -Doptimize=ReleaseFast
# Output: zig-out/bin/buddy-blocks-musl
```

### Container image (Podman / Docker)

```bash
zig build -Doptimize=ReleaseFast
zig build -Dmusl=true -Doptimize=ReleaseFast
podman build -t buddy-blocks:latest .
# or
docker build -t buddy-blocks:latest .
```

## Running

### Local binary

```bash
LD_LIBRARY_PATH=../zig-lmdbx/zig-out/lib ./zig-out/bin/buddy-blocks-gnu
# or
zig build run
```

The server listens on `0.0.0.0:10001`.

### Container

```bash
podman run -d --name buddy-blocks \
  --privileged \
  -p 10001:10001 \
  buddy-blocks:latest
# or
docker run -d --name buddy-blocks \
  --privileged \
  -p 10001:10001 \
  buddy-blocks:latest
```

`--privileged` is required for `io_uring` inside containers.

### Quick Checks

```bash
podman logs buddy-blocks
curl -X PUT http://localhost:10001/block -d "test data"
curl http://localhost:10001/block/<hash>
```

## API Reference

### PUT `/block`

Uploads a block and returns its SHA-256 hash.

```bash
curl -X PUT --data-binary @file.bin http://localhost:10001/block
echo "Hello, World!" | curl -X PUT --data-binary @- http://localhost:10001/block
```

Response:
```
HTTP/1.1 200 OK
Content-Type: text/plain

a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

Limits: maximum block size is 1 MB (size-class dependent).

### GET `/block/<hash>`

Fetches a block by its content hash.

```bash
curl http://localhost:10001/block/<hash> -o output.bin
```

### DELETE `/block/<hash>`

Removes a stored block and returns the space to the allocator.

```bash
curl -X DELETE http://localhost:10001/block/<hash>
```

## Runtime Configuration

Edit `src/main.zig` to tweak runtime parameters:

```zig
const Config = struct {
    port: u16 = 10001,
    num_workers: u8 = 4,
    controller_cycle_ns: i128 = 20_000,
    queue_capacity: usize = 4096,
};
```

The controller dynamically adapts its sleep interval based on recent RPS to balance latency and CPU usage.


 

### Running Load Tests

```bash
cd tests
go run rps.go -blocks 1000 -concurrency 2
# -duration 10s for sustained load
```

## Roadmap

- Replication between peers
- DHT / gossip discovery
- Erasure coding on top of fixed-size blocks
- Proof-of-storage integrations

## Testing

```bash
zig build test
cd tests && python3 test_basic_operations.py
```

## License

Apache 2.0
