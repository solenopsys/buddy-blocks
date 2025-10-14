# Алгоритм работы BlockController

## Структуры данных

### LMDBX хранит два типа записей:

1. **Ссылки на блоки (hash → metadata)**
   - Ключ: SHA256 хеш данных (32 байта)
   - Значение: BlockMetadata (24 байта)
     - block_size: u64 (размер блока в байтах)
     - block_num: u64 (номер блока)
     - buddy_num: u64 (номер buddy для buddy-алгоритма)

2. **Список свободных блоков (размер_номер → buddy)**
   - Ключ: строка вида "4k_123", "8k_45", "256k_7" и т.д.
   - Значение: u64 buddy_num (8 байт)

### Файл данных
- Один файл `/tmp/fastblock.data`
- Растет макроблоками по 1MB
- Каждый блок имеет номер = offset / block_size

---

## Операция: writeBlock(hash, data)

### 1. Определяем нужный размер блока
Находим ближайшую степень двойки >= data.len:
- block_size = nextPowerOfTwo(data.len)
- Минимум 4KB, максимум 1MB
- Пример: data.len = 3000 байт → block_size = 4096 (4KB)
- Пример: data.len = 5000 байт → block_size = 8192 (8KB)

### 2. Выделяем блок: allocateBlock(block_size)

#### Поиск свободного блока:
1. Делаем **cursor range scan** с префиксом (например "4k_")
2. **Одна итерация cursor**: lmdbx_cursor_get(cursor, "4k_", ...)
   - Если вернул результат → есть свободный блок
   - Извлекаем номер блока из ключа (например из "4k_15" → block_num=15)
   - Удаляем этот ключ из free list
   - Возвращаем BlockMetadata{block_size, block_num=15, buddy_num}
3. Если cursor ничего не вернул → свободных блоков нет, идем в createNewBlock()

#### Создание нового блока (если свободных нет):
1. **Расширяем файл на 1MB** (макроблок)
2. Вычисляем номер макроблока: macro_block_num = current_size / 1MB
3. **Создаем 2 свободных блока по 512KB**:
   - Добавляем в free list: "512k_0" → {buddy: 0}
   - Добавляем в free list: "512k_1" → {buddy: 1}
4. **Рекурсивно вызываем allocateBlock(block_size)**
   - Теперь есть свободные 512KB блоки
   - Buddy алгоритм будет дробить их на нужный размер

### 3. Buddy split (если нужен блок меньше чем есть свободный)

Пример: нужен блок 4KB, но есть только свободный 512KB

1. Берем свободный блок 512KB (номер 0)
2. Делим его на 2 блока по 256KB:
   - Блок 256k_0 (левый buddy)
   - Блок 256k_1 (правый buddy) → добавляем в free list
3. Берем 256k_0, делим на 2 блока по 128KB:
   - Блок 128k_0 (левый buddy)
   - Блок 128k_1 (правый buddy) → добавляем в free list
4. Продолжаем дробить пока не получим 4KB:
   - 128k_0 → 64k_0 + 64k_1 (64k_1 в free list)
   - 64k_0 → 32k_0 + 32k_1 (32k_1 в free list)
   - 32k_0 → 16k_0 + 16k_1 (16k_1 в free list)
   - 16k_0 → 8k_0 + 8k_1 (8k_1 в free list)
   - 8k_0 → 4k_0 + 4k_1 (4k_1 в free list)
5. Возвращаем 4k_0

**Результат**: получили нужный блок 4KB, все "обрезки" сохранены в free list для переиспользования

### 4. Записываем данные
- offset = block_num × block_size
- file_controller.streamWrite(offset, data)

### 5. Сохраняем метаданные
- LMDBX: hash → BlockMetadata{block_size, block_num, buddy_num}

---

## Операция: readBlock(hash)

1. Получаем метаданные: lmdbx_get(hash) → BlockMetadata
2. Вычисляем offset = block_num × block_size
3. Читаем через io_uring: file_controller.ring.read(fd, buffer, offset)
4. Возвращаем данные

---

## Операция: deleteBlock(hash)

### 1. Удаляем метаданные
- lmdbx_get(hash) → BlockMetadata
- lmdbx_del(hash)

### 2. Освобождаем блок (freeBlock)

#### Buddy merge (пытаемся объединить с соседом):
1. **У нас уже есть buddy_num** в BlockMetadata - это и есть номер соседа!
   - Не нужно вычислять четность
   - buddy_num указывает на парный блок

2. Проверяем свободен ли buddy:
   - Формируем ключ: "4k_{buddy_num}"
   - lmdbx_get("4k_{buddy_num}") → если нашли, buddy свободен

3. **Если buddy свободен**:
   - Удаляем **оба блока** из free list:
     - lmdbx_del("4k_{block_num}") - удаляем текущий блок
     - lmdbx_del("4k_{buddy_num}") - удаляем соседний блок
   - Вычисляем родительский блок (объединение):
     - parent_size = block_size × 2 (4KB → 8KB, 8KB → 16KB, ...)
     - parent_num = block_num / 2
   - **Рекурсивно вызываем freeBlock()** для родительского блока
   - Продолжаем объединять пока есть свободный buddy или пока не достигнем максимального размера (1MB)

4. **Если buddy занят** (или это максимальный размер 1MB):
   - Просто добавляем блок в free list: "4k_{block_num}" → {buddy_num}

---

## Пример работы

### Начальное состояние: пустой файл

### Запись 1: writeBlock(hash1, data[4KB])
1. Файл пустой, свободных блоков нет
2. Расширяем файл: 0 → 1MB
3. Создаем 2 свободных блока:
   - "512k_0" → free list
   - "512k_1" → free list
4. Рекурсивно вызываем allocateBlock(4KB)
5. Берем "512k_0", дробим через buddy split:
   - 512k_0 → 256k_0 + 256k_1 (256k_1 в free list)
   - 256k_0 → 128k_0 + 128k_1 (128k_1 в free list)
   - 128k_0 → 64k_0 + 64k_1 (64k_1 в free list)
   - 64k_0 → 32k_0 + 32k_1 (32k_1 в free list)
   - 32k_0 → 16k_0 + 16k_1 (16k_1 в free list)
   - 16k_0 → 8k_0 + 8k_1 (8k_1 в free list)
   - 8k_0 → 4k_0 + 4k_1 (4k_1 в free list)
6. Используем 4k_0
7. Записываем данные в offset 0
8. Сохраняем: hash1 → {4k, block_num=0, buddy=0}

**Free list после записи:**
- "4k_1", "8k_1", "16k_1", "32k_1", "64k_1", "128k_1", "256k_1", "512k_1"

### Запись 2: writeBlock(hash2, data[4KB])
1. Ищем свободный 4KB: cursor range scan "4k_"
2. Находим "4k_1" за **одну итерацию cursor**
3. Удаляем "4k_1" из free list
4. Используем block_num=1
5. Записываем данные в offset 4KB
6. Сохраняем: hash2 → {4k, block_num=1, buddy=1}

### Запись 3: writeBlock(hash3, data[32KB])
1. Ищем свободный 32KB: cursor range scan "32k_"
2. Находим "32k_1" за **одну итерацию cursor**
3. Удаляем "32k_1" из free list
4. Используем block_num=1
5. Записываем данные
6. Сохраняем: hash3 → {32k, block_num=1, buddy=1}

### Удаление: deleteBlock(hash2)
1. Получаем: {4k, block_num=1, buddy=1}
2. Удаляем hash2 из LMDBX
3. Вычисляем buddy: buddy_num = 0 (так как 1 нечетный)
4. Проверяем "4k_0" - **занят** (там hash1)
5. Не можем объединить → просто добавляем в free list: "4k_1"

### Удаление: deleteBlock(hash1)
1. Получаем: {4k, block_num=0, buddy=0}
2. Удаляем hash1 из LMDBX
3. Вычисляем buddy: buddy_num = 1 (так как 0 четный)
4. Проверяем "4k_1" - **свободен!** (только что освободили)
5. **Buddy merge**:
   - Удаляем "4k_1" из free list
   - Объединяем 4k_0 + 4k_1 → 8k_0
   - Рекурсивно вызываем freeBlock(8k_0)
6. Проверяем buddy для 8k_0: buddy = 8k_1 - **свободен!**
7. **Buddy merge**:
   - Удаляем "8k_1" из free list
   - Объединяем 8k_0 + 8k_1 → 16k_0
   - Рекурсивно вызываем freeBlock(16k_0)
8. Продолжаем объединять: 16k_0 + 16k_1 → 32k_0
9. Проверяем buddy для 32k_0: buddy = 32k_1 - **занят** (там hash3)
10. Останавливаемся, добавляем "32k_0" в free list

**Результат**: освободили 2 блока по 4KB, они объединились обратно в 32KB блок

---

## Производительность

### Поиск свободного блока: O(1)
- **Одна** операция cursor range scan с префиксом
- Не требует перебора

### Расширение файла: Amortized O(1)
- Происходит редко (когда нет свободных блоков)
- Создает 2 свободных блока по 512KB
- Buddy split дробит их на нужный размер

### Buddy split: O(log(max_size / min_size))
- Максимум log(1MB / 4KB) = log(256) ≈ 8 итераций
- На практике: очень быстро

### Buddy merge: O(log(max_size / min_size))
- Рекурсивное объединение пока есть свободный buddy
- Максимум 8 уровней

### Запись/чтение данных:
- Запись: O(log N) LMDBX + O(1) io_uring
- Чтение: O(log N) LMDBX + O(1) io_uring
- Удаление: O(log N) LMDBX + O(log size) buddy merge
