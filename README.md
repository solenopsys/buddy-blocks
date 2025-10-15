# Buddy Blocks Storage Server

Высокопроизводительный HTTP-сервер для хранения блоков данных с использованием io_uring и buddy allocator.

## Особенности

- **Потоковая передача через io_uring**: Все операции чтения/записи файлов выполняются через буферы 4KB с использованием io_uring ядра Linux
- **Zero-copy архитектура**: Данные передаются напрямую socket → file и file → socket без полной загрузки в RAM
- **Buddy Allocator**: Эффективное управление блоками данных размером от 4KB до 1MB
- **LMDBX**: Быстрая база данных для хранения метаданных блоков
- **Multi-threaded**: Несколько worker-потоков с SO_REUSEPORT для максимальной производительности

## Требования

- Zig 0.15.1 или новее
- Linux с поддержкой io_uring (kernel 5.1+)
- liblmdbx

## Сборка

```bash
# Клонируйте зависимости
git clone https://github.com/your-repo/zig-lmdbx ../zig-lmdbx
git clone https://github.com/your-repo/zig-pico ../zig-pico

# Соберите liblmdbx
cd ../zig-lmdbx
zig build
cd ../buddy-blocks

# Соберите сервер
zig build
```

## Запуск

### Запуск HTTP сервера

```bash
# Запуск сервера на порту 10001 с 4 worker-потоками
zig build run
```

Или после сборки:

```bash
./zig-out/bin/buddy-blocks
```

Сервер будет слушать на `0.0.0.0:10001`

### Запуск benchmark для buddy_allocator

```bash
cd buddy_allocator
zig build benchmark
```

Это запустит тесты производительности buddy allocator с различными размерами блоков.

## API

### PUT /block - Загрузка блока

Загружает блок данных и возвращает SHA256 хеш.

```bash
# Загрузка файла
curl -X PUT --data-binary @file.bin http://localhost:10001/block

# Загрузка текстовых данных
echo "Hello, World!" | curl -X PUT --data-binary @- http://localhost:10001/block
```

**Ответ:**
```
HTTP/1.1 200 OK
Content-Type: text/plain

a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

**Ограничения:**
- Максимальный размер блока: 512KB
- Данные передаются потоково через буферы 4KB

### GET /block/\<hash\> - Скачивание блока

Скачивает блок данных по SHA256 хешу.

```bash
curl http://localhost:10001/block/a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e -o output.bin
```

**Ответ:**
```
HTTP/1.1 200 OK
Content-Type: application/octet-stream

<binary data>
```

Данные передаются потоково через буферы 4KB.

### DELETE /block/\<hash\> - Удаление блока

Удаляет блок данных.

```bash
curl -X DELETE http://localhost:10001/block/a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e
```

**Ответ:**
```
HTTP/1.1 200 OK
Content-Type: text/plain

Block deleted
```

## Архитектура

### Потоковая передача данных

```
┌──────────┐     4KB chunks      ┌────────────┐     4KB chunks     ┌──────┐
│  Client  │ ──────io_uring────► │   Server   │ ──────io_uring───► │ File │
│  Socket  │                     │  (kernel)  │                    │      │
└──────────┘                     └────────────┘                    └──────┘
```

**PUT запрос:**
1. Server читает HTTP заголовки через picozig
2. Для PUT /block server НЕ читает body в память
3. Вызывается `handlePutStreaming()` с socket fd и Content-Length
4. `streamSocketToFile()` читает из socket 4KB чанками через io_uring
5. Одновременно вычисляется SHA256 хеш на лету
6. Каждый 4KB чанк сразу записывается в файл через io_uring
7. Возвращается хеш клиенту

**GET запрос:**
1. Server читает HTTP заголовки и извлекает hash из URL
2. Вызывается `handleGetStreaming()` с socket fd и hash
3. Отправляется HTTP заголовок ответа
4. `streamFileToSocket()` читает файл 4KB чанками через io_uring
5. Каждый 4KB чанк сразу отправляется в socket через io_uring

### Компоненты

- **server.zig**: Multi-threaded HTTP сервер на io_uring с SO_REUSEPORT
- **file_controller.zig**: Низкоуровневая работа с файлами через io_uring и O_DIRECT
- **block_controller_adapter.zig**: Адаптер между BuddyAllocator и FileController
- **block_handlers.zig**: HTTP handlers для работы с блоками
- **buddy_allocator**: Buddy allocator для эффективного управления блоками
- **lmdbx**: LMDBX обёртка для хранения метаданных

## Конфигурация

Параметры можно изменить в `src/main.zig`:

```zig
const port: u16 = 10001;           // Порт сервера
const num_workers: usize = 4;      // Количество worker-потоков
```

Параметры в `src/file_controller.zig`:

```zig
const PAGE_SIZE = 4096;            // Размер страницы памяти
const BUFFER_SIZE = 4096;          // Размер буфера для streaming
const QUEUE_DEPTH = 64;            // Глубина io_uring очереди
```

## Производительность

- **Zero memory overhead**: Данные не загружаются полностью в RAM
- **Direct I/O**: Использование O_DIRECT флага для bypass page cache
- **Parallel processing**: 4 буфера работают параллельно для максимальной пропускной способности
- **io_uring batching**: Несколько операций отправляются одновременно

## Тестирование

```bash
# Запуск тестов
zig build test

# Тест потоковой записи
dd if=/dev/urandom of=test.bin bs=1M count=10
curl -X PUT --data-binary @test.bin http://localhost:10001/block

# Тест потокового чтения
HASH=$(curl -X PUT --data-binary @test.bin http://localhost:10001/block)
curl http://localhost:10001/block/$HASH -o download.bin
diff test.bin download.bin
```

## Лицензия

MIT
