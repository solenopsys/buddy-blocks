#!/usr/bin/env python3
import requests
import hashlib

SERVER_URL = "http://localhost:10001"

# Простые тестовые данные 4KB
data = b"A" * (4 * 1024)

print(f"Отправка {len(data)} байт...")

# PUT - отправить данные (путь игнорируется, можно использовать /)
response = requests.put(f"{SERVER_URL}/", data=data, timeout=5)
print(f"PUT: {response.status_code}")
hash_value = response.text.strip()
print(f"Хеш: {hash_value}")

# Проверка хеша
expected_hash = hashlib.sha256(data).hexdigest()
print(f"Ожидаемый хеш: {expected_hash}")
print(f"Совпадает: {hash_value == expected_hash}")

# GET - получить данные обратно
response = requests.get(f"{SERVER_URL}/{hash_value}", timeout=5)
print(f"\nGET: {response.status_code}")
retrieved_data = response.content
print(f"Получено байт: {len(retrieved_data)}")
print(f"Данные совпадают: {retrieved_data == data}")

# DELETE - удалить
response = requests.delete(f"{SERVER_URL}/{hash_value}", timeout=5)
print(f"\nDELETE: {response.status_code}")

# Проверка что удалено
response = requests.get(f"{SERVER_URL}/{hash_value}", timeout=5)
print(f"GET после DELETE: {response.status_code} (должно быть 404)")