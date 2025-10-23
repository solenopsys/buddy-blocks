#!/usr/bin/env python3
import requests
import hashlib
import random
import time

SERVER_URL = "http://localhost:8080"

print("="*60)
print("Тестирование HTTP сервера с io_uring + splice + AF_ALG")
print("="*60)

# Генерируем 2 случайных блока по 4KB
print("\nГенерация 2 блоков данных по 4KB...")
block1 = bytes(random.getrandbits(8) for _ in range(4 * 1024))
block2 = bytes(random.getrandbits(8) for _ in range(4 * 1024))

hash1 = hashlib.sha256(block1).hexdigest()
hash2 = hashlib.sha256(block2).hexdigest()

print(f"Блок 1 - SHA256: {hash1}")
print(f"Блок 2 - SHA256: {hash2}")

# Словарь для хранения хешей
stored_hashes = []

# Цикл из 1000 итераций
ITERATIONS = 1000
print(f"\nЗапуск {ITERATIONS} итераций (чередование блоков 1 и 2)...")

start_time = time.time()

for i in range(ITERATIONS):
    # Выбираем блок: четные итерации - блок 1, нечетные - блок 2
    if i % 2 == 0:
        current_block = block1
        block_num = 1
        expected_hash = hash1
    else:
        current_block = block2
        block_num = 2
        expected_hash = hash2

    if (i + 1) % 100 == 0:
        print(f"[Итерация {i+1}] Отправка блока {block_num}")

    try:
        # PUT запрос
        response = requests.put(f"{SERVER_URL}", data=current_block, timeout=5)

        if response.status_code == 200:
            returned_hash = response.text.strip()
            if returned_hash == expected_hash:
                stored_hashes.append(returned_hash)
            else:
                print(f"  ✗ Хеш не совпадает на итерации {i+1}!")
        else:
            print(f"  ✗ Ошибка на итерации {i+1}: {response.status_code}")

    except Exception as e:
        print(f"  ✗ Исключение на итерации {i+1}: {e}")

end_time = time.time()
elapsed = end_time - start_time

print("\n" + "="*60)
print(f"Тестирование завершено")
print(f"Сохранено блоков: {len(stored_hashes)}")
print(f"Время выполнения: {elapsed:.2f} секунд")
print(f"Скорость: {ITERATIONS / elapsed:.2f} блоков/сек")
print(f"Пропускная способность: {(ITERATIONS * 4096) / (1024 * 1024 * elapsed):.2f} МБ/сек")
print("="*60)
