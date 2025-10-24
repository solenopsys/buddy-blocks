#!/usr/bin/env python3
import httpx
import hashlib
import time
import struct
import asyncio
from concurrent.futures import ThreadPoolExecutor

SERVER_URL = "http://localhost:10001"
BLOCK_SIZE = 4096
NUM_BLOCKS = 100
NUM_WORKERS = 10  # Параллельные потоки

print(f"=== FastBlock Parallel Benchmark: {NUM_BLOCKS} blocks x {BLOCK_SIZE} bytes, {NUM_WORKERS} workers ===")

# Генерируем уникальные блоки
blocks = []
hashes = []

for i in range(NUM_BLOCKS):
    block = struct.pack('<Q', i) + b'A' * (BLOCK_SIZE - 8)
    expected_hash = hashlib.sha256(block).hexdigest()
    blocks.append(block)
    hashes.append(expected_hash)

# Создаем HTTP клиент с connection pooling
client = httpx.Client(
    timeout=10.0,
    limits=httpx.Limits(max_keepalive_connections=NUM_WORKERS * 2, max_connections=NUM_WORKERS * 2),
    http2=False
)

def put_block(index):
    try:
        response = client.put(f"{SERVER_URL}/", content=blocks[index])
        if response.status_code == 200:
            returned_hash = response.text.strip()
            if returned_hash == hashes[index]:
                return (index, True, None)
            else:
                return (index, False, f"Hash mismatch: expected {hashes[index]}, got {returned_hash}")
        else:
            return (index, False, f"Status {response.status_code}")
    except Exception as e:
        return (index, False, str(e))

def get_block(index):
    try:
        response = client.get(f"{SERVER_URL}/{hashes[index]}")
        if response.status_code == 200:
            retrieved_data = response.content
            if len(retrieved_data) == BLOCK_SIZE and retrieved_data == blocks[index]:
                return (index, True, None)
            else:
                actual_hash = hashlib.sha256(retrieved_data).hexdigest() if len(retrieved_data) == BLOCK_SIZE else "size_mismatch"
                return (index, False, f"Data mismatch: expected {hashes[index]}, got {actual_hash}, size {len(retrieved_data)}")
        else:
            return (index, False, f"Status {response.status_code}")
    except Exception as e:
        return (index, False, str(e))

def delete_block(index):
    try:
        response = client.delete(f"{SERVER_URL}/{hashes[index]}")
        if response.status_code == 200:
            return (index, True, None)
        else:
            return (index, False, f"Status {response.status_code}")
    except Exception as e:
        return (index, False, str(e))

try:
    with ThreadPoolExecutor(max_workers=NUM_WORKERS) as executor:
        # === ТЕСТ PUT ===
        put_start = time.time()
        results = list(executor.map(put_block, range(NUM_BLOCKS)))
        put_end = time.time()

        put_success = sum(1 for _, success, _ in results if success)
        put_failed = sum(1 for _, success, _ in results if not success)

        for index, success, error in results:
            if not success:
                print(f"  Block {index}: PUT failed: {error}")

        put_duration = put_end - put_start
        put_rate = put_success / put_duration if put_duration > 0 else 0
        put_throughput_mb = (put_success * BLOCK_SIZE) / (1024 * 1024) / put_duration if put_duration > 0 else 0

        print(f"PUT: {put_success}/{NUM_BLOCKS} success, {put_failed} failed | {put_rate:.2f} blocks/sec ({put_throughput_mb:.2f} MB/s) | {put_duration:.2f}s")

        # === ТЕСТ GET ===
        get_start = time.time()
        results = list(executor.map(get_block, range(NUM_BLOCKS)))
        get_end = time.time()

        get_success = sum(1 for _, success, _ in results if success)
        get_failed = sum(1 for _, success, _ in results if not success)

        for index, success, error in results:
            if not success:
                print(f"  Block {index}: GET failed: {error}")

        get_duration = get_end - get_start
        get_rate = get_success / get_duration if get_duration > 0 else 0
        get_throughput_mb = (get_success * BLOCK_SIZE) / (1024 * 1024) / get_duration if get_duration > 0 else 0

        print(f"GET: {get_success}/{NUM_BLOCKS} success, {get_failed} failed | {get_rate:.2f} blocks/sec ({get_throughput_mb:.2f} MB/s) | {get_duration:.2f}s")

        # === ТЕСТ DELETE ===
        delete_start = time.time()
        results = list(executor.map(delete_block, range(NUM_BLOCKS)))
        delete_end = time.time()

        delete_success = sum(1 for _, success, _ in results if success)
        delete_failed = sum(1 for _, success, _ in results if not success)

        for index, success, error in results:
            if not success:
                print(f"  Block {index}: DELETE failed: {error}")

        delete_duration = delete_end - delete_start
        delete_rate = delete_success / delete_duration if delete_duration > 0 else 0

        print(f"DELETE: {delete_success}/{NUM_BLOCKS} success, {delete_failed} failed | {delete_rate:.2f} blocks/sec | {delete_duration:.2f}s")

        print()
        total_duration = delete_end - put_start
        print(f"Total time: {total_duration:.2f}s")

finally:
    client.close()
