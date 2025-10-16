// spsc.zig
const std = @import("std");

pub fn SpscQueue(comptime T: type, comptime N: usize) type {
    comptime {
        if (N == 0 or (N & (N - 1)) != 0) {
            @compileError("N must be power of two (e.g. 1024, 4096).");
        }
    }

    return struct {
        const Self = @This();
        const mask = N - 1;

        // Буфер
        buffer: [N]T = undefined;

        // Индексы: head — пишет producer, tail — читает consumer
        // Разнесены по cache line (64 байта), чтобы убрать false sharing.
        head: usize = 0,
        _pad1: [64 - @sizeOf(usize)]u8 = undefined,
        tail: usize = 0,
        _pad2: [64 - @sizeOf(usize)]u8 = undefined,

        pub fn init() Self {
            return .{};
        }

        /// Пытаемся положить один элемент. Возврат false если заполнено.
        pub fn tryEnqueue(self: *Self, item: T) bool {
            const head = @atomicLoad(usize, &self.head, .Monotonic); // локально ок
            const next = (head + 1) & mask;

            // Читаем tail с Acquire, чтобы видеть коммиты consumer'а
            const tail = @atomicLoad(usize, &self.tail, .Acquire);
            if (next == tail) return false; // full

            self.buffer[head] = item;
            // Публикуем запись
            @atomicStore(usize, &self.head, next, .Release);
            return true;
        }

        /// Забираем один элемент. Возврат false если пусто.
        pub fn tryDequeue(self: *Self, out: *T) bool {
            // Видим все коммиты producer'а
            const head = @atomicLoad(usize, &self.head, .Acquire);
            var tail = @atomicLoad(usize, &self.tail, .Monotonic);

            if (tail == head) return false; // empty

            out.* = self.buffer[tail];
            tail = (tail + 1) & mask;
            // Публикуем продвижение очереди
            @atomicStore(usize, &self.tail, tail, .Release);
            return true;
        }

        /// Батч-запись (уменьшает накладные)
        pub fn enqueueBatch(self: *Self, items: []const T) usize {
            var pushed: usize = 0;
            while (pushed < items.len and self.tryEnqueue(items[pushed])) : (pushed += 1) {}
            return pushed;
        }

        /// Батч-чтение
        pub fn dequeueBatch(self: *Self, out: []T) usize {
            var got: usize = 0;
            while (got < out.len and self.tryDequeue(&out[got])) : (got += 1) {}
            return got;
        }

        /// Удобный «спин с ограничением» — быстрый путь для low-latency
        pub fn spinDequeue(self: *Self, out: *T, max_spins: usize) bool {
            var spins: usize = 0;
            while (!self.tryDequeue(out)) : (spins += 1) {
                if (spins >= max_spins) return false;
                std.atomic.spinLoopHint();
            }
            return true;
        }
    };
}
