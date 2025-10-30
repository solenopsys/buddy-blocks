#!/usr/bin/env python3
import requests

import hashlib

SERVER_URL = "http://localhost:10001"

def push_block(data: bytes) -> str:
    """Вспомогательная функция, которая выполняет PUT и проверяет хеш."""
    print(f"Отправка {len(data)} байт...")
    response = requests.put(f"{SERVER_URL}/", data=data, timeout=5)
    response.raise_for_status()
    hash_value = response.text.strip()

    expected_hash = hashlib.sha256(data).hexdigest()
    if hash_value != expected_hash:
        raise AssertionError(
            f"Хеш от сервера {hash_value} не совпадает с ожидаемым {expected_hash}"
        )
    print(f"Хеш совпадает: {hash_value}")
    return hash_value


def fetch_block(hash_value: str, expected_data: bytes) -> None:
    response = requests.get(f"{SERVER_URL}/{hash_value}", timeout=5)
    response.raise_for_status()
    retrieved_data = response.content
    if retrieved_data != expected_data:
        raise AssertionError(
            f"Данные по хешу {hash_value} не совпадают с отправленными"
        )
    print(f"GET ok ({len(retrieved_data)} байт)")


def delete_block(hash_value: str) -> None:
    response = requests.delete(f"{SERVER_URL}/{hash_value}", timeout=5)
    response.raise_for_status()
    print("DELETE ok")

    response = requests.get(f"{SERVER_URL}/{hash_value}", timeout=5)
    if response.status_code != 404:
        raise AssertionError("Блок после удаления должен отдавать 404")
    print("Проверка удаления OK (404)")


def basic_put_get_delete():
    data = b"A" * (4 * 1024)
    hash_value = push_block(data)
    fetch_block(hash_value, data)
    delete_block(hash_value)


def sequential_block_sizes():
    sizes_kb = [ 256, 128, 64, 32, 16, 8, 4] #512,
    hashes = []

    for idx, size_kb in enumerate(sizes_kb):
        pattern = bytes([(65 + idx) % 256])
        data = pattern * (size_kb * 1024)
        print(f"\n=== Блок #{idx + 1}: {size_kb} KB ===")
        block_hash = push_block(data)
        fetch_block(block_hash, data)
        hashes.append((block_hash, size_kb))

    for idx, size_kb in enumerate(sizes_kb): 
        pattern = bytes([(65 + idx) % 256])
        data = pattern * ((size_kb * 1024) -256)
        print(f"\n=== Блок #{idx + 1}: {size_kb}  -256 KB ===")
        block_hash = push_block(data)
        fetch_block(block_hash, data)
        hashes.append((block_hash, size_kb))    

    print("\nУдаляем блоки в обратном порядке...")
    for block_hash, size_kb in reversed(hashes):
        print(f"DELETE {size_kb} KB (hash {block_hash})")
        delete_block(block_hash)


if __name__ == "__main__":
    basic_put_get_delete()
    sequential_block_sizes()
