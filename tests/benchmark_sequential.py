#!/usr/bin/env python3
import requests
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

# Используем requests с session для keep-alive
session = requests.Session()

try:
    # === ТЕСТ PUT + GET (записать блок N, потом N+1, потом прочитать N) ===
    put_start = time.time()
    put_success = 0
    put_failed = 0
    get_success = 0
    get_failed = 0

    for i, block in enumerate(blocks):
        # PUT текущего блока
        try:
            response = session.put(f"{SERVER_URL}/", data=block, timeout=5)
            if response.status_code == 200:
                returned_hash = response.text.strip()
                if returned_hash == hashes[i]:
                    put_success += 1
                else:
                    put_failed += 1
                    print(f"  Block {i}: Hash mismatch on PUT!")
                    print(f"    Expected: {hashes[i]}")
                    print(f"    Got:      {returned_hash}")
                    break
            else:
                put_failed += 1
                print(f"  Block {i}: PUT failed with status {response.status_code}")
                break
        except Exception as e:
            put_failed += 1
            print(f"  Block {i}: PUT Exception: {e}")
            break

        # GET предыдущего блока (если есть)
        if i > 0:
            prev_idx = i - 1
            try:
                response = session.get(f"{SERVER_URL}/{hashes[prev_idx]}", timeout=5)
                if response.status_code == 200:
                    retrieved_data = response.content
                    if len(retrieved_data) == BLOCK_SIZE and retrieved_data == blocks[prev_idx]:
                        get_success += 1
                    else:
                        get_failed += 1
                        print(f"  Block {prev_idx}: GET data mismatch after writing block {i}!")
                        print(f"    Expected hash: {hashes[prev_idx]}")
                        print(f"    Expected size: {BLOCK_SIZE}, got: {len(retrieved_data)}")
                        if len(retrieved_data) == BLOCK_SIZE:
                            actual_hash = hashlib.sha256(retrieved_data).hexdigest()
                            print(f"    Actual hash:   {actual_hash}")
                        break
                else:
                    get_failed += 1
                    print(f"  Block {prev_idx}: GET failed with status {response.status_code}")
                    break
            except Exception as e:
                get_failed += 1
                print(f"  Block {prev_idx}: GET Exception: {e}")
                break

    put_end = time.time()
    put_duration = put_end - put_start
    put_rate = put_success / put_duration if put_duration > 0 else 0
    put_throughput_mb = (put_success * BLOCK_SIZE) / (1024 * 1024) / put_duration if put_duration > 0 else 0

    print(f"PUT: {put_success}/{NUM_BLOCKS} success, {put_failed} failed | {put_rate:.2f} blocks/sec ({put_throughput_mb:.2f} MB/s) | {put_duration:.2f}s")
    print(f"GET (interleaved): {get_success}/{NUM_BLOCKS-1} success, {get_failed} failed")

    # === ТЕСТ GET (все блоки) ===
    get_start = time.time()
    get_success = 0
    get_failed = 0

    for i, expected_hash in enumerate(hashes):
        try:
            response = session.get(f"{SERVER_URL}/{expected_hash}", timeout=5)
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
            response = session.delete(f"{SERVER_URL}/{expected_hash}", timeout=5)
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
    session.close()
