#!/usr/bin/env python3
import requests
import hashlib

SERVER_URL = "http://localhost:8080"

print("="*60)
print("Тестирование HTTP сервера с io_uring + splice + AF_ALG")
print("="*60)

# Запрос 1: Простые тестовые данные 4KB
print("\n[Запрос 1] Отправка данных 'A' * 4KB")
data1 = b"A" * (4 * 1024)
hash1 = hashlib.sha256(data1).hexdigest()
print(f"  Размер: {len(data1)} байт")
print(f"  SHA256 (локально): {hash1}")

try:
    response1 = requests.put(f"{SERVER_URL}", data=data1, timeout=5)
    print(f"  Статус: {response1.status_code}")
    print(f"  Ответ: {response1.text[:100] if response1.text else 'пусто'}")
except Exception as e:
    print(f"  Ошибка: {e}")

# Запрос 2: Другие тестовые данные 8KB
print("\n[Запрос 2] Отправка данных 'B' * 8KB")
data2 = b"B" * (8 * 1024)
hash2 = hashlib.sha256(data2).hexdigest()
print(f"  Размер: {len(data2)} байт")
print(f"  SHA256 (локально): {hash2}")

try:
    response2 = requests.put(f"{SERVER_URL}", data=data2, timeout=5)
    print(f"  Статус: {response2.status_code}")
    print(f"  Ответ: {response2.text[:100] if response2.text else 'пусто'}")
except Exception as e:
    print(f"  Ошибка: {e}")

print("\n" + "="*60)
print("Тестирование завершено")
print("="*60)
