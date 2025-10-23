#!/usr/bin/env python3
import requests
import hashlib
import random

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

# Цикл из 10 итераций
ITERATIONS = 10
print(f"\nЗапуск {ITERATIONS} итераций (чередование блоков 1 и 2)...")

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

    print(f"\n[Итерация {i+1}] Отправка блока {block_num}")

    try:
        # PUT запрос
        response = requests.put(f"{SERVER_URL}", data=current_block, timeout=5)
        print(f"  PUT статус: {response.status_code}")

        if response.status_code == 200:
            returned_hash = response.text.strip()
            print(f"  Возвращенный хеш: {returned_hash}")
            print(f"  Ожидаемый хеш:   {expected_hash}")

            if returned_hash == expected_hash:
                print(f"  ✓ Хеш совпадает!")
                stored_hashes.append(returned_hash)

                # GET запрос для проверки
                get_response = requests.get(f"{SERVER_URL}/{returned_hash}", timeout=5)
                print(f"  GET статус: {get_response.status_code}")

                if get_response.status_code == 200:
                    if get_response.content == current_block:
                        print(f"  ✓ Данные совпадают!")
                    else:
                        print(f"  ✗ Данные не совпадают!")
                else:
                    print(f"  ✗ Ошибка чтения: {get_response.text[:100]}")
            else:
                print(f"  ✗ Хеш не совпадает!")
        else:
            print(f"  ✗ Ошибка: {response.text[:100]}")

    except Exception as e:
        print(f"  ✗ Исключение: {e}")

print("\n" + "="*60)
print(f"Тестирование завершено. Сохранено блоков: {len(stored_hashes)}")
print("="*60)
