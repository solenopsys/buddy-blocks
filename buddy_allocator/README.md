# Buddy Allocator - Zig Implementation

Полная реализация buddy-аллокатора на Zig с интеграцией LMDBX для управления метаданными блоков.

## Структура проекта

```
buddy_allocator/
├── src/
│   ├── types.zig              # Базовые типы (BlockSize, BlockMetadata, вспомогательные функции)
│   └── buddy_allocator.zig     # Основной алгоритм buddy allocation
├── tests/
│   └── integration_test.zig    # Интеграционные тесты с LMDBX
├── build.zig                   # Конфигурация сборки
└── build.zig.zon               # Зависимости проекта
```

## Реализованные компоненты

### 1. **types.zig** - Базовые типы
- `BlockSize` - enum размеров блоков (4KB - 1MB)
- `BlockMetadata` - метаданные блока (размер, номер, buddy номер)
- Вспомогательные функции:
  - `makeFreeListKey()` - создание ключа для свободного блока
  - `parseFreeListKey()` - парсинг ключа свободного блока
  - `nextPowerOfTwo()` - поиск ближайшей степени двойки
- **Тесты**: 6 unit тестов (все проходят ✅)

### 2. **buddy_allocator.zig** - Алгоритм
- `BuddyAllocator` - основной класс аллокатора
- `IFileController` - интерфейс для управления файлом
- `SimpleFileController` - mock реализация для тестирования

**Ключевые методы:**
- `allocate(hash, data_length)` - выделить блок
- `getBlock(hash)` - получить метаданные блока
- `free(hash)` - освободить блок
- `has(hash)` - проверить наличие блока

**Внутренние методы:**
- `allocateBlockInternal()` - поиск свободного блока
- `findAndSplitLargerBlock()` - поиск и split большего блока
- `splitBlock()` - buddy split (деление блока пополам)
- `freeBlockInternal()` - освобождение с buddy merge
- `createNewMacroBlock()` - расширение файла на 1MB

### 3. **Расширение LMDBX интерфейса**
Добавлено в `../zig-lmdbx/src/lmdbx.zig`:
- `CursorEntry` - структура для результата cursor
- `Cursor.seekPrefix()` - поиск первого ключа с префиксом
- `Cursor.next()` - переход к следующей записи

### 4. **Интеграционные тесты**
10 комплексных тестов в `tests/integration_test.zig`:
- Базовое выделение и освобождение блоков
- Выделение блоков разных размеров
- Buddy split (дробление большего блока на меньшие)
- Buddy merge (объединение свободных блоков)
- Множественные аллокации/деаллокации
- Получение метаданных
- Обработка ошибок (дубликаты, несуществующие блоки)
- Расширение файла при множественных макроблоках

## Запуск тестов

### Unit тесты для types.zig:
```bash
zig test buddy_allocator/src/types.zig
```

**Результат:**
```
1/6 types.test.BlockSize: toBytes and fromBytes...OK
2/6 types.test.BlockSize: split and merge...OK
3/6 types.test.BlockSize: toString...OK
4/6 types.test.BlockMetadata: encode and decode...OK
5/6 types.test.makeFreeListKey and parseFreeListKey...OK
6/6 types.test.nextPowerOfTwo...OK
All 6 tests passed. ✅
```

### Интеграционные тесты:
```bash
# Требуется настроенный LMDBX
cd buddy_allocator
zig build test
```

## Алгоритм работы

### Allocate (выделение блока)
1. Проверка существования блока с данным хэшем
2. Определение требуемого размера (nextPowerOfTwo)
3. Поиск свободного блока через cursor range scan с префиксом
4. Если не найден - поиск большего блока для split
5. Если нет подходящих блоков - расширение файла на 1MB макроблок
6. Сохранение метаданных: `hash → BlockMetadata`

### Split (дробление блока)
1. Берём большой блок (например, 512KB)
2. Делим пополам → 2 блока по 256KB
3. Левый buddy используем для дальнейшего split
4. Правый buddy добавляем в free list
5. Рекурсивно продолжаем пока не достигнем нужного размера

### Merge (объединение блоков)
1. При освобождении проверяем свободен ли buddy (по `buddy_num`)
2. Если buddy свободен - объединяем оба блока в родительский
3. Рекурсивно пытаемся объединить родительский блок с его buddy
4. Останавливаемся когда buddy занят или достигнут max размер (1MB)

## Структура хранения в LMDBX

### Hash → Metadata
```
Key: [32]u8 (SHA256 hash)
Value: [24]u8 (BlockMetadata encoded)
  - block_size: u64 (8 bytes)
  - block_num: u64 (8 bytes)
  - buddy_num: u64 (8 bytes)
```

### Free List
```
Key: string (например, "4k_15", "256k_42")
Value: u64 (buddy_num, 8 bytes)
```

## Производительность

### Сложность операций:
- **Поиск свободного блока**: O(1) через cursor range scan с префиксом
- **Split**: O(log N) где N = MAX_SIZE / MIN_SIZE = 256
- **Merge**: O(log N) рекурсивное объединение
- **Расширение файла**: Amortized O(1)

### Преимущества реализации:
- Минимальная фрагментация памяти
- Быстрый поиск свободных блоков через префиксный индекс
- Автоматическое объединение свободных блоков
- Thread-safe через мьютекс
- Метаданные персистентны в LMDBX

## Следующие шаги

1. **Интеграция с FileController** - заменить `SimpleFileController` на реальный с io_uring
2. **Интеграция в основной проект** - использовать в fastblock HTTP сервере
3. **Бенчмарки** - измерить производительность с реальным LMDBX
4. **Оптимизации** - batch операции, транзакции LMDBX

## Конструкции языка Zig

В реализации используются:
- **Enums with values**: `BlockSize = enum(u64)`
- **Optional types**: `?BlockMetadata`
- **Error unions**: `!BlockMetadata`
- **Interfaces через vtable**: `IFileController`
- **Generics**: `std.mem.Allocator`
- **Comptime**: константы, проверки типов
- **Defer**: автоматическая очистка ресурсов
- **Thread safety**: `std.Thread.Mutex`
- **Testing framework**: `std.testing`

## Соответствие TypeScript модели

Реализация полностью соответствует TypeScript прототипу из `model/`:
- ✅ Те же структуры данных
- ✅ Тот же алгоритм buddy allocation
- ✅ Те же ключи для free list
- ✅ Та же логика split/merge
- ✅ Покрытие теми же тестами
