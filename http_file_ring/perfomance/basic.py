#!/usr/bin/env python3
import requests
import hashlib
import random

SERVER_URL = "http://localhost:8080"

print("="*60)
print("Тестирование HTTP сервера с io_uring + splice + AF_ALG")
print("="*60)

# Генерируем 1 случайный блок 4KB
print("\nГенерация блока данных 4KB...")
block_data = bytes(random.getrandbits(8) for _ in range(4 * 1024))

# Вычисляем ожидаемый хеш
expected_hash = hashlib.sha256(block_data).hexdigest()
print(f"Ожидаемый SHA256: {expected_hash}")

# PUT запрос
print("\nОтправка PUT запроса...")
try:
    response = requests.put(f"{SERVER_URL}", data=block_data, timeout=5)

    if response.status_code == 200:
        returned_hash = response.text.strip()
        print(f"Полученный хеш: {returned_hash}")

        if returned_hash == expected_hash:
            print("✓ Хеш совпадает!")

            # GET запрос для получения данных обратно
            print("\nОтправка GET запроса...")
            get_response = requests.get(f"{SERVER_URL}/{returned_hash}", timeout=5)

            if get_response.status_code == 200:
                retrieved_data = get_response.content

                # Сравниваем данные
                if retrieved_data == block_data:
                    print("✓ Данные полностью совпадают!")
                    print(f"Размер блока: {len(retrieved_data)} байт")
                else:
                    print("✗ Данные не совпадают!")
                    print(f"Отправлено: {len(block_data)} байт")
                    print(f"Получено: {len(retrieved_data)} байт")
            else:
                print(f"✗ Ошибка GET запроса: {get_response.status_code}")
        else:
            print("✗ Хеш не совпадает!")
    else:
        print(f"✗ Ошибка PUT запроса: {response.status_code}")

except Exception as e:
    print(f"✗ Исключение: {e}")

print("="*60)
