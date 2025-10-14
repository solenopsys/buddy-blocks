# FastBlock Model (TypeScript)

TypeScript модель buddy-аллокатора для тестирования алгоритма перед портированием на Zig.

## Структура

```
model/
├── src/
│   ├── types.ts              # Базовые типы (BlockSize, BlockMetadata, BlockInfo)
│   ├── interfaces.ts         # Интерфейсы (IStorage, IFileController)
│   ├── block-controller.ts   # Основной алгоритм buddy allocation
│   ├── storage/
│   │   ├── mock-storage.ts          # Mock KVS с индексом по префиксам
│   │   ├── lmdb-storage.ts          # Реальный LMDB storage
│   │   └── mock-file-controller.ts  # Mock file controller
│   └── tests/
│       └── block-controller.test.ts # 20 тестов
│
├── benchmarks/
│   ├── benchmark.ts              # Основной benchmark (mock storage)
│   ├── benchmark-lmdb.ts         # LMDB benchmark
│   ├── benchmark-lmdb-txn.ts     # LMDB с транзакциями
│   ├── profile.ts                # Простой профайлер
│   ├── profile-detailed.ts       # Детальный профайлер
│   ├── profile-trace.ts          # Трейс медленных операций
│   ├── profile-bigint.ts         # Профайлинг BigInt
│   ├── test-lmdb.ts              # Тест LMDB операций
│   ├── test-lmdb-simple.ts       # Простой тест LMDB
│   └── debug.ts                  # Отладочный скрипт
│
└── package.json

```

## API

### BlockController

```typescript
// Выделить блок
const { offset, blockSize } = controller.allocate({
  hash: 'sha256_hash',
  dataLength: 1234
});

// Получить метаданные блока
const { offset, blockSize } = controller.getBlock('sha256_hash');

// Освободить блок
controller.free('sha256_hash');

// Проверить наличие
const exists = controller.has('sha256_hash');

// Статистика
const stats = controller.getStats();
```

## Запуск

```bash
# Установить зависимости
bun install

# Тесты
bun test

# Benchmark (mock storage)
bun benchmarks/benchmark.ts

# Benchmark (LMDB с транзакциями)
bun benchmarks/benchmark-lmdb-txn.ts

# Профайлинг
bun benchmarks/profile.ts
```

## Результаты

### Mock Storage
- **Allocations**: 11.6K ops/sec (sequential 4KB)
- **Gets**: 1.7M ops/sec
- **Frees**: 184K ops/sec

### LMDB
- **Without transactions**: 52 ops/sec (каждый write = fsync)
- **With transactions**: 21K ops/sec

## Алгоритм

- Buddy allocator с размерами 4KB - 1MB
- Метаданные в LMDB (hash → BlockMetadata, size_num → buddy)
- Файл данных растет макроблоками по 1MB
- Split: O(log N) рекурсивное деление блока
- Merge: O(log N) рекурсивное объединение с buddy
- Поиск свободного блока: O(1) через cursor range scan

## Следующий шаг

Перенести на Zig с реальным:
- LMDB для метаданных
- io_uring для I/O
- Файл `/tmp/fastblock.data`
