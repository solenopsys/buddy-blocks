#!/bin/bash

echo "Building and running Buddy Allocator Benchmark..."
echo ""

# Build benchmark
zig build-exe src/benchmark.zig \
    --dep lmdbx --mod lmdbx:root:../../zig-lmdbx/src/lmdbx.zig \
    --dep types --mod types:root:src/types.zig \
    --dep buddy_allocator --mod buddy_allocator:root:src/buddy_allocator.zig \
    -lc \
    -I../../zig-lmdbx/libmdbx \
    -L../../zig-lmdbx/zig-out/lib \
    -lmdbx \
    -O ReleaseFast \
    -femit-bin=benchmark

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Build successful! Running benchmark..."
echo ""

# Run benchmark
./benchmark

# Cleanup
rm -f benchmark benchmark.o
