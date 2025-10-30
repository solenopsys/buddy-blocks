#!/usr/bin/env python3
import requests
import hashlib
import random
import time

def test_block(block_size_kb):
    """Тестирование блока определенного размера"""
    block_size = block_size_kb * 1024

    print("\n" + "="*60)
    print(f"Тест {block_size_kb}KB блока: напрямую vs через pasta")
    print("="*60)

    # Генерируем блок данных
    print(f"\nГенерация блока данных {block_size_kb}KB...")
    block_data = bytes(random.getrandbits(8) for _ in range(block_size))
    expected_hash = hashlib.sha256(block_data).hexdigest()
    print(f"Ожидаемый SHA256: {expected_hash}")

    # Тест 1: Напрямую (порт 8080)
    print("\n" + "-"*60)
    print("ТЕСТ 1: Напрямую на порт 8080")
    print("-"*60)
    try:
        start = time.time()
        response = requests.put("http://localhost:8080", data=block_data, timeout=10)
        elapsed = time.time() - start

        if response.status_code == 200:
            returned_hash = response.text.strip()
            print(f"✓ PUT успешен за {elapsed:.3f}s")
            print(f"  Полученный хеш: {returned_hash}")

            if returned_hash == expected_hash:
                print("✓ Хеш совпадает!")

                # GET запрос
                start = time.time()
                get_response = requests.get(f"http://localhost:8080/{returned_hash}", timeout=10)
                elapsed = time.time() - start

                if get_response.status_code == 200 and get_response.content == block_data:
                    print(f"✓ GET успешен за {elapsed:.3f}s")
                    print("✓ Данные совпадают!")
                else:
                    print("✗ GET провален")
            else:
                print("✗ Хеш не совпадает!")
        else:
            print(f"✗ PUT провален: {response.status_code}")
    except Exception as e:
        print(f"✗ Исключение: {e}")

    # Тест 2: Через pasta (порт 8081)
    print("\n" + "-"*60)
    print("ТЕСТ 2: Через pasta на порт 8081")
    print("-"*60)
    try:
        start = time.time()
        response = requests.put("http://localhost:8081", data=block_data, timeout=10)
        elapsed = time.time() - start

        if response.status_code == 200:
            returned_hash = response.text.strip()
            print(f"✓ PUT успешен за {elapsed:.3f}s")
            print(f"  Полученный хеш: {returned_hash}")

            if returned_hash == expected_hash:
                print("✓ Хеш совпадает!")

                # GET запрос
                start = time.time()
                get_response = requests.get(f"http://localhost:8081/{returned_hash}", timeout=10)
                elapsed = time.time() - start

                if get_response.status_code == 200 and get_response.content == block_data:
                    print(f"✓ GET успешен за {elapsed:.3f}s")
                    print("✓ Данные совпадают!")
                else:
                    print("✗ GET провален")
            else:
                print("✗ Хеш не совпадает!")
        else:
            print(f"✗ PUT провален: {response.status_code}")
    except Exception as e:
        print(f"✗ Исключение: {e}")

# Запускаем тесты: сначала 8KB, потом 512KB
print("="*60)
print("ТЕСТИРОВАНИЕ БЛОКОВ РАЗНЫХ РАЗМЕРОВ")
print("="*60)

test_block(8)      # 8 KB
test_block(512)    # 512 KB

print("\n" + "="*60)
print("ТЕСТЫ ЗАВЕРШЕНЫ")
print("="*60)
