# План реализации многопоточной архитектуры buddy-blocks

## Текущее состояние проекта

### Архитектура
- ✅ Single-threaded сервер (`server_single.zig`) работает
- ✅ Многопоточный сервер (`server.zig`) с SO_REUSEPORT работает
- ✅ BuddyAllocator с LMDBX для метаданных
- ✅ io_uring для асинхронного I/O
- ✅ Размеры блоков: 4KB → 1MB (powers of 2)
- ⚠️ Буферы io_uring: 4KB (слишком мало)
- ⚠️ Последовательная обработка чанков файла
- ⚠️ Нет SPSC очередей между потоками

### Проблемы производительности
1. **Буферы 4KB** - даже большие блоки режутся на мелкие куски
2. **Синхронный паттерн** - каждый чанк: read→submit→wait→write→submit→wait
3. **Нет батчинга** - io_uring используется как синхронный I/O
4. **Пропускная способность** упирается в ~40 MB/s вместо 200-400 MB/s
5. **LMDBX контенция** - каждый worker блокирует БД при операциях

---

## Целевая архитектура (из TODO.md)

### Компоненты

#### Workers (несколько потоков)
- Полноценные HTTP серверы с собственным io_uring
- Привязаны к общему порту через SO_REUSEPORT
- Обрабатывают HTTP запросы
- **Накапливают** пустые блоки для записи каждого размера через стандартный цикл:
  - При старте воркер проверяет пулы блоков
  - Если количество свободных < target_free - отправляет запрос на allocate в controller
  - Во время работы та же логика: проверка пулов и запрос новых блоков при необходимости
  - Никаких специальных функций, просто часть основного цикла
- Работают только с предварительно выделенными блоками (владельцы сегментов файла)
- Отправляют запросы в Controller через SPSC очереди

#### Controller (один поток)
- Единственный поток с доступом к LMDBX
- Обрабатывает батчи запросов от всех workers
- Транзакционная модель: все операции в одной транзакции
- Динамическая пауза для экономии CPU
- Цикл:
  0. **Проверка паузы**: если с момента `beforeRun` прошло < 100µs → пауза на оставшееся время; иначе → немедленное выполнение
  1. Запомнить текущее время в `beforeRun`
  2. Собрать все сообщения из входящих очередей от workers
  3. Разложить по типам в массивы (разложение, не сортировка!)
  4. Открыть транзакцию LMDBX
  5. **Батч получения адресов по хешу** → сразу отправляем ответы (read-only, уменьшает latency GET)
  6. Батч освобождения блоков → массив результатов (возвращаем в buddy allocator)
  7. Батч выделения блоков → массив результатов (блоки уже в buddy allocator, нет мертвого буфера)
  8. Батч занятия блоков → массив результатов
  9. Коммит транзакции
  10. Разослать оставшиеся результаты по обратным адресам воркерам
  11. Вернуться к шагу 0

#### SPSC Очереди
- По две очереди на каждого worker: входящая и исходящая
- Lock-free кольцевые буферы
- Библиотека: https://github.com/freref/spsc-queue

### Типы сообщений

#### От Worker → Controller
```zig
const MessageToController = union(enum) {
    allocate_block: struct {
        worker_id: u8,   // обратный адрес (1 байт)
        request_id: u64, // для сопоставления запроса и ответа в worker
        size: u8,        // размер блока (enum index)
    },
    occupy_block: struct {
        worker_id: u8,
        request_id: u64,
        hash: [32]u8,
        data_size: u64,
    },
    release_block: struct {
        worker_id: u8,
        request_id: u64,
        hash: [32]u8,
    },
    get_address: struct {
        worker_id: u8,
        request_id: u64,
        hash: [32]u8,
    },
};
```

#### От Controller → Worker
```zig
const MessageFromController = union(enum) {
    // Успешные результаты
    allocate_result: struct {
        worker_id: u8,
        request_id: u64,
        offset: u64,
        size: u8,
        block_num: u64,
    },
    occupy_result: struct {
        worker_id: u8,
        request_id: u64,
    },
    release_result: struct {
        worker_id: u8,
        request_id: u64,
    },
    get_address_result: struct {
        worker_id: u8,
        request_id: u64,
        offset: u64,
        size: u64,
    },

    // Одно общее сообщение об ошибке
    error: struct {
        worker_id: u8,
        request_id: u64,
        message: []const u8,
    },
};
```

### Преимущества
- ✅ Нет конкуренции за LMDBX - только Controller работает с БД
- ✅ Workers владеют своими сегментами файла - могут писать параллельно
- ✅ Батчинг операций снижает накладные расходы LMDBX
- ✅ Предварительное выделение блоков убирает задержки

---

## Пошаговый план реализации сущностей

**Принцип:** Каждый шаг создает одну полную сущность (интерфейс + реализация + mock + тесты) и дает работающий, протестированный компонент.

### Шаг 1: Messages - Типы сообщений
**Что делаем:**
- [ ] Создать `src/messages.zig` с типами сообщений:
  - `MessageToController` (allocate_block, occupy_block, release_block, get_address)
  - `MessageFromController` (результаты + error)
  - `AllocateRequest`, `OccupyRequest`, `ReleaseRequest`, `GetAddressRequest`
  - `AllocateResult`, `GetAddressResult`
- [ ] Реализовать `serialize()` и `deserialize()` для каждого типа
- [ ] Написать тесты для сериализации/десериализации

**Результат:** Работающие типы данных с полным покрытием тестами.

**Файлы:** `src/messages.zig`, `tests/messages_test.zig`

---

### Шаг 2: SPSC Queue - Очереди коммуникации
**Что делаем:**
- [ ] Создать интерфейс `ISPSCQueue` в `src/interfaces.zig`
- [ ] Интегрировать https://github.com/freref/spsc-queue
- [ ] Реализовать `RealSPSCQueue` (обертка над библиотекой) в `src/spsc.zig`
- [ ] Реализовать `MockSPSCQueue` (синхронный ArrayList) в `src/spsc.zig`
- [ ] Написать тесты:
  - Unit тесты для `RealSPSCQueue` (push/pop, порядок, переполнение)
  - Unit тесты для `MockSPSCQueue`
  - Тест что оба работают через один интерфейс
  - Benchmark (latency, throughput)

**Результат:** Работающие очереди (real + mock) с тестами.

**Файлы:** `src/interfaces.zig`, `src/spsc.zig`, `tests/spsc_test.zig`, `build.zig`

---

### Шаг 3: Message Handler - Обработка сообщений
**Что делаем:**
- [ ] Создать интерфейс `IMessageHandler` в `src/interfaces.zig`
- [ ] Реализовать `BuddyMessageHandler` в `src/message_handler.zig`:
  - Обертка над `BuddyAllocator`
  - Методы: `handleAllocate`, `handleOccupy`, `handleRelease`, `handleGetAddress`
- [ ] Реализовать `MockMessageHandler` в `src/message_handler.zig`:
  - Настраиваемые ответы
  - Запись последних вызовов для проверки
- [ ] Написать тесты:
  - Unit тесты для `BuddyMessageHandler` с реальным BuddyAllocator
  - Unit тесты для `MockMessageHandler`
  - Тест что оба работают через один интерфейс

**Результат:** Работающий обработчик сообщений (real + mock) с тестами.

**Файлы:** `src/interfaces.zig`, `src/message_handler.zig`, `tests/message_handler_test.zig`

---

### Шаг 4: Block Pool - Пулы блоков
**Что делаем:**
- [ ] Создать интерфейс `IBlockPool` в `src/interfaces.zig`
- [ ] Реализовать `SimpleBlockPool` в `src/block_pool.zig`:
  - Методы: `acquire`, `release`, `needsRefill`, `getSize`
  - Логика проверки `target_free`
- [ ] Реализовать `MockBlockPool` в `src/block_pool.zig`:
  - Настраиваемое поведение `needsRefill`
  - Контролируемый список блоков для выдачи
- [ ] Написать тесты:
  - Unit тесты для `SimpleBlockPool` (acquire/release, needsRefill logic)
  - Unit тесты для `MockBlockPool`
  - Тест что оба работают через один интерфейс

**Результат:** Работающие пулы блоков (real + mock) с тестами.

**Файлы:** `src/interfaces.zig`, `src/block_pool.zig`, `tests/block_pool_test.zig`

---

### Шаг 5: Controller - Батч-обработчик
**Что делаем:**
- [ ] Создать интерфейс `IController` в `src/interfaces.zig`
- [ ] Реализовать `BatchController` в `src/controller.zig`:
  - Конструктор принимает: `IMessageHandler`, `[]WorkerQueues` (ISPSCQueue), `cycle_interval_ns`
  - Главный цикл с динамической паузой
  - Методы: `collectMessages`, `processBatches`, `sendResults`
  - Батч-операции в правильном порядке: release → allocate → occupy → get_address
- [ ] Реализовать `MockController` в `src/controller.zig`:
  - Запись вызовов `run()`, `shutdown()`
- [ ] Написать тесты:
  - **Unit тесты с моками**: `BatchController` + `MockMessageHandler` + `MockSPSCQueue`
    - Тест сбора сообщений из очередей
    - Тест разложения по типам
    - Тест батч-обработки (порядок: **get_address → release → allocate → occupy**)
    - Тест что get_address отправляется первым (уменьшает latency)
    - Тест отправки результатов
    - Тест динамической паузы
  - Unit тесты для `MockController`
  - **Интеграционный тест**: `BatchController` + `BuddyMessageHandler` + `RealSPSCQueue`

**Результат:** Работающий контроллер (real + mock) с полным покрытием тестами.

**Файлы:** `src/interfaces.zig`, `src/controller.zig`, `tests/controller_test.zig`

---

### Шаг 6: Worker - HTTP сервер с пулами
**Что делаем:**
- [ ] Создать интерфейс `IWorker` в `src/interfaces.zig`
- [ ] Реализовать `HttpWorker` в `src/worker.zig`:
  - Конструктор принимает: `id`, `port`, `file_fd`, `[8]IBlockPool`, `to_controller: ISPSCQueue`, `from_controller: ISPSCQueue`
  - Главный цикл: io_uring → check controller messages → refill pools → handle HTTP
  - Методы: `refillPools`, `checkControllerMessages`, `handlePutBlock`, `handleGetBlock`, `handleDeleteBlock`
- [ ] Реализовать `MockWorker` в `src/worker.zig`:
  - Запись вызовов `run()`, `shutdown()`
- [ ] Написать тесты:
  - **Unit тесты с моками**: `HttpWorker` + `MockBlockPool` + `MockSPSCQueue`
    - Тест refill logic (когда pool.needsRefill() == true)
    - Тест обработки ответов от controller
    - Тест PUT блока (взять из пула, записать, отправить occupy)
    - Тест GET блока (запросить адрес, прочитать, отправить)
    - Тест DELETE блока (отправить release)
  - Unit тесты для `MockWorker`
  - **Интеграционный тест**: `HttpWorker` + `SimpleBlockPool` + `RealSPSCQueue` (без реального HTTP)

**Результат:** Работающий worker (real + mock) с полным покрытием тестами.

**Файлы:** `src/interfaces.zig`, `src/worker.zig`, `tests/worker_test.zig`

---

### Шаг 7: Main - Сборка системы
**Что делаем:**
- [ ] Создать `src/main.zig` с функцией `main()`:
  - Инициализация LMDBX, FileController, BuddyAllocator
  - Создание реальных SPSC очередей для каждого worker
  - Создание `BuddyMessageHandler`
  - Создание `BatchController` с реальными зависимостями
  - Создание `SimpleBlockPool` для каждого размера блока
  - Создание `HttpWorker` с реальными зависимостями
  - Запуск потоков для controller и workers
- [ ] Написать интеграционные тесты:
  - **Полная интеграция**: `BatchController` + `HttpWorker` + реальные компоненты
    - Запустить controller + 1 worker в отдельных потоках
    - Отправить HTTP PUT запрос → проверить что блок записан
    - Отправить HTTP GET запрос → проверить что блок прочитан
    - Отправить HTTP DELETE запрос → проверить что блок удален
  - **Нагрузочный тест**: controller + 4 workers, конкурентные запросы

**Результат:** Работающая полная система с интеграционными тестами.

**Файлы:** `src/main.zig`, `tests/integration_test.zig`

---

### Шаг 8: Оптимизация io_uring
**Что делаем:**
- [ ] Увеличить `BUFFER_SIZE` до 64KB в `HttpWorker`
- [ ] Реализовать `BufferPool` для управления буферами
- [ ] Модифицировать чтение/запись файла для батчинга операций
- [ ] Поддерживать глубину очереди ≥8 активных операций
- [ ] Написать бенчмарки:
  - Throughput (req/s, MB/s) для разных размеров блоков
  - Latency (p50, p95, p99)
  - Сравнение с baseline (текущая версия)

**Результат:** Оптимизированная версия с бенчмарками.

**Файлы:** `src/worker.zig`, `benchmarks/io_uring_bench.zig`

---

### Шаг 9: Конфигурация и мониторинг
**Что делаем:**
- [ ] Создать `src/config.zig` с `BlockPoolConfig`
- [ ] Добавить загрузку конфигурации из файла или аргументов
- [ ] Создать `src/metrics.zig` с метриками для controller и worker
- [ ] Добавить endpoint `/stats` для просмотра метрик

**Результат:** Конфигурируемая система с мониторингом.

**Файлы:** `src/config.zig`, `src/metrics.zig`

---

## Чеклист выполнения

- [ ] **Шаг 1: Messages** - типы данных работают и протестированы
- [ ] **Шаг 2: SPSC Queue** - очереди работают и протестированы
- [ ] **Шаг 3: Message Handler** - обработчик работает и протестирован
- [ ] **Шаг 4: Block Pool** - пулы работают и протестированы
- [ ] **Шаг 5: Controller** - контроллер работает и протестирован (unit + integration)
- [ ] **Шаг 6: Worker** - worker работает и протестирован (unit + integration)
- [ ] **Шаг 7: Main** - полная система работает (integration + load tests)
- [ ] **Шаг 8: Optimization** - io_uring оптимизирован (benchmarks)
- [ ] **Шаг 9: Config** - конфигурация и мониторинг

---

## Детальный план реализации

### Этап 1: Архитектурные принципы и подготовка
**Цель:** Определить принципы разработки и оптимизировать типы

#### 1.1 Принцип тестируемости
- [ ] **ВСЕ компоненты должны работать через интерфейсы**
- [ ] Каждый интерфейс должен иметь mock реализацию для тестов
- [ ] Система должна легко расстыковываться на отдельные компоненты
- [ ] Каждый компонент должен тестироваться изолированно

**Обязательные интерфейсы:**
```zig
// Уже есть
pub const IFileController = struct { ... };  // из buddy_allocator

// Нужно добавить
pub const ISPSCQueue = struct { ... };       // для очередей
pub const IController = struct { ... };      // для контроллера
pub const IWorker = struct { ... };          // для воркера
pub const IMessageHandler = struct { ... };  // для обработки сообщений
```

#### 1.2 Оптимизация типов
- [x] Изменить MAX_BLOCK_SIZE с 1MB на 512KB в `types.zig`
- [x] Изменить тип для размера блока с `u64` на `u8` (enum index: 0-7)
- [x] Обновить BlockMetadata для хранения размера как `u8`
- [x] Обновить константы буферов io_uring:
  ```zig
  const BUFFER_SIZE = 64 * 1024; // 64 KB на операцию
  const NUM_BUFFERS = 8;         // ~512 KB общей памяти
  ```

**Файлы:** `src/types.zig`, `src/file_controller.zig`, `src/interfaces.zig`

---

### Этап 2: Интеграция SPSC очередей
**Цель:** Добавить lock-free очереди для коммуникации

- [ ] Скачать/интегрировать https://github.com/freref/spsc-queue в проект
- [ ] Обернуть в Zig-friendly API в `SPSC.zig` с интерфейсом:
  ```zig
  pub const ISPSCQueue = struct {
      ptr: *anyopaque,
      vtable: *const VTable,

      pub const VTable = struct {
          push: *const fn(ptr: *anyopaque, data: []const u8) bool,
          pop: *const fn(ptr: *anyopaque, buffer: []u8) ?usize,
      };
  };
  ```
- [ ] Написать тесты для SPSC очередей:
  - Single producer, single consumer
  - Корректность порядка сообщений
  - Производительность (latency, throughput)
- [ ] Создать mock реализацию для тестов (синхронный ArrayList)

**Файлы:** `SPSC.zig`, `build.zig`

---

### Этап 3: Определить типы сообщений
**Цель:** Создать протокол коммуникации worker ↔ controller

- [ ] Создать `src/messages.zig` с:
  - `MessageToController` (allocate, occupy, release, get_address)
  - `MessageFromController` (результаты для каждого типа)
  - Сериализация/десериализация (если нужно)
  - Вспомогательные функции для создания сообщений

- [ ] Определить размер очередей и буферов сообщений:
  ```zig
  const QUEUE_SIZE = 4096;  // на каждую очередь
  const MAX_MESSAGE_SIZE = 128;
  ```

**Файлы:** `src/messages.zig`

---

### Этап 4: Реализовать Controller
**Цель:** Единственный поток с доступом к LMDBX

- [ ] Создать интерфейс `IController` для тестируемости:
  ```zig
  pub const IController = struct {
      ptr: *anyopaque,
      vtable: *const VTable,

      pub const VTable = struct {
          run: *const fn(ptr: *anyopaque) anyerror!void,
          shutdown: *const fn(ptr: *anyopaque) void,
      };
  };
  ```

- [ ] Создать `src/controller.zig` с структурой `Controller`:
  ```zig
  pub const Controller = struct {
      allocator: Allocator,
      buddy_allocator: *BuddyAllocator,
      file_controller: *FileController,

      // SPSC очереди от/к workers
      worker_queues: []WorkerQueues,

      // Буферы для батчинга
      allocate_requests: ArrayList(AllocateRequest),
      occupy_requests: ArrayList(OccupyRequest),
      release_requests: ArrayList(ReleaseRequest),
      get_address_requests: ArrayList(GetAddressRequest),

      // Для динамической паузы
      before_run: i64,  // timestamp последнего запуска цикла (наносекунды)
      cycle_interval_ns: i64 = 100_000,  // 100µs

      running: atomic.Value(bool),

      pub fn interface(self: *Controller) IController { ... }
  };
  ```

- [ ] Реализовать `Controller.run()` - главный цикл:
  ```zig
  while (running.load(.monotonic)) {
      // Шаг 0: Динамическая пауза
      const now = std.time.nanoTimestamp();
      const elapsed = now - self.before_run;
      if (elapsed < self.cycle_interval_ns) {
          const sleep_ns = self.cycle_interval_ns - elapsed;
          std.time.sleep(@intCast(sleep_ns));
      }
      self.before_run = std.time.nanoTimestamp();

      // Шаг 1-2: Опрос очередей и разложение по типам
      self.collectMessages();

      // Шаг 3-7: Батч-обработка в одной транзакции
      self.processBatch();
  }
  ```

- [ ] Реализовать батч-операции в правильном порядке:
  - `processBatchGetAddress()` - получение адресов (ПЕРВЫМ - read-only, сразу отправляем для уменьшения latency)
  - `processBatchRelease()` - освобождение блоков (возвращаем в buddy allocator)
  - `processBatchAllocate()` - выделение блоков (из buddy allocator)
  - `processBatchOccupy()` - занятие блоков

**Файлы:** `src/controller.zig`

---

### Этап 5: Модифицировать Worker
**Цель:** Workers с предварительным накоплением блоков

- [ ] Создать интерфейс `IWorker` для тестируемости:
  ```zig
  pub const IWorker = struct {
      ptr: *anyopaque,
      vtable: *const VTable,

      pub const VTable = struct {
          run: *const fn(ptr: *anyopaque) anyerror!void,
          shutdown: *const fn(ptr: *anyopaque) void,
      };
  };
  ```

- [ ] Создать новый `src/worker.zig` на основе `server.zig`:
  ```zig
  pub const Worker = struct {
      id: u8,  // worker_id для обратного адреса
      allocator: Allocator,
      ring: linux.IoUring,
      server_socket: posix.fd_t,
      file_fd: posix.fd_t,

      // Пул предвыделенных блоков (кеш)
      block_pools: [8]BlockPool,  // по одному на размер (4k-512k)

      // SPSC очереди к controller
      to_controller: *SPSCQueue,
      from_controller: *SPSCQueue,

      // Клиенты и файловые передачи
      clients: AutoHashMap(u64, Client),
      file_transfers: AutoHashMap(u64, *FileTransfer),
  };
  ```

- [ ] Реализовать `BlockPool` для каждого размера:
  ```zig
  const BlockPool = struct {
      size: u8,
      target_free: usize,  // целевое количество свободных блоков в кеше
      free_blocks: ArrayList(BlockInfo),

      fn refillIfNeeded(worker: *Worker) void;
  };
  ```

- [ ] Модифицировать цикл обработки worker:
  1. Обработать CQE от io_uring (HTTP I/O)
  2. **Проверить очередь от controller** (результаты операций, сопоставить по request_id)
  3. **Проверить пулы блоков**: если free_blocks.len < target_free - отправить allocate запрос
  4. Обработать HTTP запросы с использованием предвыделенных блоков

  **Важно:** логика проверки и пополнения пулов (шаг 3) работает одинаково при старте и во время работы

- [ ] Обновить обработку PUT /block:
  - Взять блок из пула (без обращения к controller!)
  - Записать данные асинхронно через io_uring
  - Отправить `occupy_block` в controller
  - Дождаться подтверждения
  - Ответить клиенту

- [ ] Обновить обработку GET /block:
  - Отправить `get_address` в controller
  - Дождаться offset и size
  - Читать асинхронно через io_uring
  - Отправить клиенту

- [ ] Обновить обработку DELETE /block:
  - Отправить `release_block` в controller
  - Дождаться подтверждения
  - Ответить клиенту

**Файлы:** `src/worker.zig`

---

### Этап 6: Оптимизация io_uring в Worker
**Цель:** Увеличить буферы и использовать батчинг

- [ ] Увеличить BUFFER_SIZE до 64KB в worker
- [ ] Реализовать буферные пулы (8 буферов по 64KB):
  ```zig
  const BufferPool = struct {
      buffers: [NUM_BUFFERS][BUFFER_SIZE]u8,
      free_mask: u8,  // битовая маска свободных буферов

      fn acquire() ?[]u8;
      fn release(buffer: []u8) void;
  };
  ```

- [ ] Модифицировать чтение/запись файла:
  - Использовать большие буферы (64KB вместо 4KB)
  - Батчить несколько операций в один `submit()`
  - Поддерживать глубину очереди ≥8 активных операций

- [ ] Оптимизировать FileTransfer для больших блоков:
  - Подготовить несколько SQE для разных чанков
  - Один `submit()` на батч
  - Обрабатывать CQE по мере готовности

**Файлы:** `src/worker.zig`, `src/file_controller.zig`

---

### Этап 7: Создать новый main с новой архитектурой
**Цель:** Запустить controller + workers

- [ ] Создать `src/main_multithread.zig`:
  ```zig
  pub fn main() !void {
      // Инициализация
      var gpa = std.heap.GeneralPurposeAllocator(.{}){};
      const allocator = gpa.allocator();

      const num_workers = 4;
      const port = 10001;

      // LMDBX + FileController + BuddyAllocator
      var db = try lmdbx.Database.open("/tmp/buddy-blocks.db");
      var file_controller = try FileController.init(...);
      var buddy_allocator = try BuddyAllocator.init(...);

      // Создать SPSC очереди для каждого worker
      var worker_queues = try createWorkerQueues(allocator, num_workers);

      // Создать и запустить Controller в отдельном потоке
      var controller = try Controller.init(...);
      const controller_thread = try Thread.spawn(.{}, Controller.run, .{&controller});

      // Создать и запустить Workers
      var workers = try createWorkers(allocator, num_workers, port, worker_queues);
      var worker_threads = try spawnWorkerThreads(workers);

      // Ожидание
      controller_thread.join();
      for (worker_threads) |t| t.join();
  }
  ```

- [ ] Обновить `build.zig` для нового main

**Файлы:** `src/main_multithread.zig`, `build.zig`

---

### Этап 8: Конфигурация буферизации блоков
**Цель:** Настраиваемые пулы блоков для workers

- [ ] Создать `BlockPoolConfig`:
  ```zig
  pub const BlockPoolConfig = struct {
      size_4k: usize = 10,
      size_8k: usize = 10,
      size_16k: usize = 10,
      size_32k: usize = 5,
      size_64k: usize = 5,
      size_128k: usize = 3,
      size_256k: usize = 2,
      size_512k: usize = 2,
  };
  // Каждое значение - целевое количество свободных блоков в кеше worker'а
  ```

- [ ] Добавить загрузку конфигурации из файла или аргументов командной строки

**Файлы:** `src/config.zig`

---

### Этап 9: Тестирование и бенчмарки
**Цель:** Проверить корректность и производительность

- [ ] Unit тесты (каждый компонент изолированно с mock объектами):
  - **SPSC очереди**: корректность, порядок сообщений, производительность
  - **Controller**: батч-операции с mock BuddyAllocator и mock очередями
  - **Worker**: пулы блоков, refill logic с mock Controller
  - **Типы сообщений**: сериализация/десериализация
  - **MessageHandler**: обработка разных типов сообщений

- [ ] Интеграционные тесты (реальные компоненты):
  - Запуск controller + 1 worker с реальным LMDBX
  - PUT → GET → DELETE цикл
  - Конкурентные запросы от нескольких клиентов
  - Проверка отсутствия race conditions
  - Тест с mock HTTP клиентами и реальным controller/worker

- [ ] Бенчмарки производительности:
  ```bash
  # Baseline (текущая версия)
  wrk -t4 -c100 -d30s --latency http://localhost:10001

  # Новая архитектура
  wrk -t4 -c100 -d30s --latency http://localhost:10001
  ```

- [ ] Сравнить метрики:
  - Throughput (req/s, MB/s)
  - Latency (p50, p95, p99)
  - CPU usage
  - Memory usage

**Ожидаемый результат:**
- 4-16 KB блоки: 10-20k rps → 40-60 MB/s
- 64-256 KB блоки: 200-400 MB/s (NVMe), 80-120 MB/s (SATA)

**Файлы:** `tests/`, `benchmarks/`

---

### Этап 10: Мониторинг и отладка
**Цель:** Инструменты для диагностики

- [ ] Добавить метрики в Controller:
  - Количество сообщений в очередях
  - Размер батчей
  - Время выполнения транзакций LMDBX
  - Количество пауз и spin cycles

- [ ] Добавить метрики в Worker:
  - Количество свободных блоков в каждом пуле
  - Количество запросов на refill
  - Время ожидания ответов от controller
  - io_uring queue depth

- [ ] Создать endpoint `/stats` для просмотра метрик

- [ ] Добавить структурированное логирование (опционально)

**Файлы:** `src/metrics.zig`

---

## Чеклист готовности

### Минимальная версия (MVP)
- [ ] SPSC очереди работают
- [ ] Controller обрабатывает батчи
- [ ] Worker использует предвыделенные блоки
- [ ] PUT /block работает
- [ ] GET /block работает
- [ ] DELETE /block работает
- [ ] Базовые тесты проходят

### Оптимизированная версия
- [ ] Буферы io_uring увеличены до 64KB
- [ ] Батчинг io_uring операций
- [ ] Глубина очереди ≥8
- [ ] Производительность ≥200 MB/s на больших блоках
- [ ] Конфигурируемые пулы блоков

### Production-ready
- [ ] Все тесты проходят
- [ ] Метрики и мониторинг
- [ ] Graceful shutdown
- [ ] Обработка ошибок и восстановление
- [ ] Документация API
- [ ] Benchmarks показывают целевую производительность

---

## Потенциальные проблемы

### 1. LMDBX как bottleneck
**Симптом:** Controller не справляется с потоком запросов от workers
**Решение:**
- Уменьшить `cycle_interval_ns` (например, с 100µs до 50µs или 10µs) для более частой обработки батчей
- Tune LMDBX параметры (map size, page size, write map)
- Рассмотреть read-only транзакции для GET операций

### 2. SPSC очереди переполняются
**Симптом:** SPSC очереди заполнены, новые сообщения не отправляются
**Решение:**
- Увеличить QUEUE_SIZE
- Динамическое back-pressure (worker замедляет прием HTTP запросов)
- Мониторинг глубины очередей

### 3. Пулы блоков истощаются
**Симптом:** Worker не может выделить блок для PUT запроса
**Решение:**
- Увеличить `target_free` для горячих размеров блоков
- Приоритетная обработка allocate запросов в controller
- Адаптивная настройка размеров пулов на основе нагрузки

---

## Следующие шаги

1. **Начать с этапа 1-2**: Подготовка типов и SPSC очереди
2. **Прототип на этапе 3-4**: Реализовать controller с батчингом
3. **Интеграция на этапе 5-7**: Подключить workers и новый main
4. **Оптимизация на этапе 8-10**: Tunning производительности

## Приоритет задач

### High Priority (обязательно для MVP)
- Этап 2: SPSC очереди
- Этап 3: Типы сообщений
- Этап 4: Controller с батчингом
- Этап 5: Worker с пулами блоков
- Этап 7: Новый main

### Medium Priority (для production)
- Этап 1: Оптимизация типов (512KB, u8)
- Этап 6: Оптимизация io_uring
- Этап 9: Тесты и бенчмарки

### Low Priority (nice to have)
- Этап 8: Конфигурация пулов
- Этап 10: Мониторинг

---

**Версия:** 1.1 (исправлена)
**Дата:** 2025-10-16
**Автор:** alexstorm + Claude
