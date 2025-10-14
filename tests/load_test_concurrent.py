#!/usr/bin/env python3
import requests
import time
import hashlib

SERVER_URL = "http://localhost:10001"
BLOCK_SIZE = 4 * 1024*4*4*4*4
NUM_BLOCKS = 1000

def run_load_test():
    print(f"Запуск нагрузочного теста с {NUM_BLOCKS} блоками по {BLOCK_SIZE} байт...")

    write_times = []
    read_times = []
    hashes = []

    for i in range(NUM_BLOCKS):
        # Создаем уникальный блок данных
        data = bytearray(b"A" * BLOCK_SIZE)
        data[:4] = i.to_bytes(4, 'big')  # Меняем первые 4 байта

        # --- Запись (PUT) ---
        start_time = time.monotonic()
        try:
            response = requests.put(f"{SERVER_URL}/block/", data=bytes(data))
            response.raise_for_status()  # Проверка на ошибки HTTP
            write_time = time.monotonic() - start_time
            write_times.append(write_time)
            hash_value = response.text.strip()
            hashes.append(hash_value)

            # Проверка хеша для уверенности
            expected_hash = hashlib.sha256(data).hexdigest()
            if hash_value != expected_hash:
                print(f"Ошибка: Хеш не совпадает для блока {i}!")
                continue

        except requests.exceptions.RequestException as e:
            print(f"Ошибка при записи блока {i}: {e}")
            continue

        # --- Чтение (GET) ---
        start_time = time.monotonic()
        try:
            response = requests.get(f"{SERVER_URL}/block/{hash_value}")
            response.raise_for_status()
            read_time = time.monotonic() - start_time
            read_times.append(read_time)

            if response.content != data:
                print(f"Ошибка: Данные не совпадают для блока {i}!")

        except requests.exceptions.RequestException as e:
            print(f"Ошибка при чтении блока {i}: {e}")
            continue
        
        print(f"Блок {i+1}/{NUM_BLOCKS} обработан.", end='\r')

    print("\n\nТест завершен.")

    # --- Удаление созданных блоков ---
    print("Удаление тестовых данных...")
    for i, hash_val in enumerate(hashes):
        try:
            requests.delete(f"{SERVER_URL}/block/{hash_val}")
        except requests.exceptions.RequestException as e:
            print(f"Ошибка при удалении блока {i} с хешем {hash_val}: {e}")
    print("Удаление завершено.")


    # --- Результаты ---
    if not write_times or not read_times:
        print("Не удалось получить достаточно данных для анализа.")
        return

    total_write_time = sum(write_times)
    total_read_time = sum(read_times)
    
    avg_write_time = total_write_time / len(write_times)
    avg_read_time = total_read_time / len(read_times)

    writes_per_second = 1 / avg_write_time if avg_write_time > 0 else float('inf')
    reads_per_second = 1 / avg_read_time if avg_read_time > 0 else float('inf')

    print("\n--- Результаты нагрузочного теста ---")
    print(f"Всего блоков обработано: {len(hashes)}")
    print(f"Среднее время записи: {avg_write_time:.6f} сек")
    print(f"Среднее время чтения: {avg_read_time:.6f} сек")
    print(f"Записей в секунду (RPS): {writes_per_second:.2f}")
    print(f"Чтений в секунду (RPS): {reads_per_second:.2f}")
    print("------------------------------------")


if __name__ == "__main__":
    run_load_test()
