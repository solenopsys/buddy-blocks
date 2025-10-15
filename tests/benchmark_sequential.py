#!/usr/bin/env python3
import httpx
import hashlib
import time
import struct

SERVER_URL = "http://localhost:10001"
BLOCK_SIZE = 4096
NUM_BLOCKS = 1000

print(f"=== FastBlock Benchmark: {NUM_BLOCKS} blocks x {BLOCK_SIZE} bytes ===")

# Генерируем уникальные блоки
blocks = []
hashes = []

for i in range(NUM_BLOCKS):
    # Создаем блок с уникальными первыми 8 байтами (номер блока)
    block = struct.pack('<Q', i) + b'A' * (BLOCK_SIZE - 8)
    expected_hash = hashlib.sha256(block).hexdigest()
    blocks.append(block)
    hashes.append(expected_hash)

# Создаем HTTP клиент с connection pooling и keep-alive
client = httpx.Client(
    timeout=5.0,
    limits=httpx.Limits(max_keepalive_connections=10, max_connections=10),
    http2=False  # HTTP/1.1 для совместимости
)

try:
    # === ТЕСТ PUT ===
    put_start = time.time()
    put_success = 0
    put_failed = 0

    for i, block in enumerate(blocks):
        try:
            response = client.put(f"{SERVER_URL}/block", content=block)
            if response.status_code == 200:
                returned_hash = response.text.strip()
                if returned_hash == hashes[i]:
                    put_success += 1
                else:
                    put_failed += 1
                    print(f"  Block {i}: Hash mismatch!")
            else:
                put_failed += 1
                print(f"  Block {i}: PUT failed with status {response.status_code}")
        except Exception as e:
            put_failed += 1
            print(f"  Block {i}: Exception: {e}")

    put_end = time.time()
    put_duration = put_end - put_start
    put_rate = put_success / put_duration if put_duration > 0 else 0
    put_throughput_mb = (put_success * BLOCK_SIZE) / (1024 * 1024) / put_duration if put_duration > 0 else 0

    print(f"PUT: {put_success}/{NUM_BLOCKS} success, {put_failed} failed | {put_rate:.2f} blocks/sec ({put_throughput_mb:.2f} MB/s) | {put_duration:.2f}s")

    # === ТЕСТ GET ===
    get_start = time.time()
    get_success = 0
    get_failed = 0

    for i, expected_hash in enumerate(hashes):
        try:
            response = client.get(f"{SERVER_URL}/block/{expected_hash}")
            if response.status_code == 200:
                retrieved_data = response.content
                if len(retrieved_data) == BLOCK_SIZE and retrieved_data == blocks[i]:
                    get_success += 1
                else:
                    get_failed += 1
                    print(f"  Block {i}: Data mismatch!")
            else:
                get_failed += 1
                print(f"  Block {i}: GET failed with status {response.status_code}")
        except Exception as e:
            get_failed += 1
            print(f"  Block {i}: Exception: {e}")

    get_end = time.time()
    get_duration = get_end - get_start
    get_rate = get_success / get_duration if get_duration > 0 else 0
    get_throughput_mb = (get_success * BLOCK_SIZE) / (1024 * 1024) / get_duration if get_duration > 0 else 0

    print(f"GET: {get_success}/{NUM_BLOCKS} success, {get_failed} failed | {get_rate:.2f} blocks/sec ({get_throughput_mb:.2f} MB/s) | {get_duration:.2f}s")

    # === ТЕСТ DELETE ===
    delete_start = time.time()
    delete_success = 0
    delete_failed = 0

    for i, expected_hash in enumerate(hashes):
        try:
            response = client.delete(f"{SERVER_URL}/block/{expected_hash}")
            if response.status_code == 200:
                delete_success += 1
            else:
                delete_failed += 1
                print(f"  Block {i}: DELETE failed with status {response.status_code}")
        except Exception as e:
            delete_failed += 1
            print(f"  Block {i}: Exception: {e}")

    delete_end = time.time()
    delete_duration = delete_end - delete_start
    delete_rate = delete_success / delete_duration if delete_duration > 0 else 0

    print(f"DELETE: {delete_success}/{NUM_BLOCKS} success, {delete_failed} failed | {delete_rate:.2f} blocks/sec | {delete_duration:.2f}s")

    print()
    total_duration = delete_end - put_start
    print(f"Total time: {total_duration:.2f}s")

finally:
    client.close()
