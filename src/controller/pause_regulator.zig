const std = @import("std");

/// Регулятор пауз на основе RPS
pub const PauseRegulator = struct {
    rpc_counter: usize,
    last_rpc_counter: usize, // Предыдущее значение для вычисления дельты
    last_check_time: i128,
    last_rps: usize,
    current_pause_ns: u64, // Текущая пауза в наносекундах
    update_counter: usize, // Счетчик для редких обновлений

    pub fn init() PauseRegulator {
        return .{
            .rpc_counter = 0,
            .last_rpc_counter = 0,
            .last_check_time = std.time.nanoTimestamp(),
            .last_rps = 0,
            .current_pause_ns = 1_000_000, // По умолчанию 1мс
            .update_counter = 0,
        };
    }

    /// Инкрементирует счетчик сообщений
    pub fn increment(self: *PauseRegulator) void {
        self.rpc_counter += 1;
    }

    /// Обновляет паузу раз в секунду на основе RPS
    /// Вызывать редко - раз в 1000 итераций (через остаток от деления)
    pub fn tryUpdate(self: *PauseRegulator) void {
        self.update_counter += 1;

        // Проверяем время только раз в 1000 итераций (остаток от деления)
        if (self.update_counter % 1000 == 0) {
            const now = std.time.nanoTimestamp();
            const elapsed = now - self.last_check_time;

            // Обновляем RPS и паузу каждую секунду
            if (elapsed >= 1_000_000_000) {
                // Вычисляем сколько сообщений было за последнюю секунду (дельта)
                const messages_this_second = self.rpc_counter - self.last_rpc_counter;
                self.last_rps = messages_this_second;
                self.last_rpc_counter = self.rpc_counter;
                self.last_check_time = now;

                // Вычисляем паузу на основе RPS
                // При RPS >= 1000: без паузы
                // При RPS > 0 и < 1000: пауза = 1мс
                // При RPS = 0: пауза = 100мс (холостой режим)
                self.current_pause_ns = if (self.last_rps >= 1_000)
                    0
                else if (self.last_rps > 0)
                    1_000_000
                else
                    100_000_000; // 100мс в холостом режиме
            }
        }
    }

    /// Возвращает текущую паузу в наносекундах
    pub fn getPause(self: *const PauseRegulator) u64 {
        return self.current_pause_ns;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "PauseRegulator - инициализация" {
    const regulator = PauseRegulator.init();
    try testing.expectEqual(@as(usize, 0), regulator.rpc_counter);
    try testing.expectEqual(@as(usize, 0), regulator.last_rps);
}

test "PauseRegulator - increment увеличивает счетчик" {
    var regulator = PauseRegulator.init();

    regulator.increment();
    try testing.expectEqual(@as(usize, 1), regulator.rpc_counter);

    regulator.increment();
    try testing.expectEqual(@as(usize, 2), regulator.rpc_counter);

    for (0..100) |_| {
        regulator.increment();
    }
    try testing.expectEqual(@as(usize, 102), regulator.rpc_counter);
}

test "PauseRegulator - пауза при низком RPS" {
    var regulator = PauseRegulator.init();

    // Низкий RPS - должна быть пауза 1мс
    for (0..100) |_| {
        regulator.increment();
    }

    try testing.expectEqual(@as(u64, 1_000_000), regulator.getPause());
}

test "PauseRegulator - без паузы при высоком RPS" {
    var regulator = PauseRegulator.init();

    // Симулируем высокий RPS
    for (0..15000) |_| {
        regulator.increment();
    }

    // Ждем 1 секунду
    std.Thread.sleep(1_000_000_000);

    // Вызываем tryUpdate несколько раз чтобы сработало обновление
    for (0..1000) |_| {
        regulator.tryUpdate();
    }

    try testing.expectEqual(@as(u64, 0), regulator.getPause()); // Нет паузы
}

test "PauseRegulator - счетчик не сбрасывается" {
    var regulator = PauseRegulator.init();

    for (0..500) |_| {
        regulator.increment();
    }

    const counter_before = regulator.rpc_counter;
    for (0..1000) |_| {
        regulator.tryUpdate();
    }
    const counter_after = regulator.rpc_counter;

    // Счетчик не должен сбрасываться
    try testing.expectEqual(counter_before, counter_after);
}

test "PauseRegulator - обновление RPS каждую секунду" {
    var regulator = PauseRegulator.init();

    // Добавляем сообщения
    for (0..5000) |_| {
        regulator.increment();
    }

    try testing.expectEqual(@as(usize, 0), regulator.last_rps);

    // Ждем больше секунды
    std.Thread.sleep(1_100_000_000);

    // Вызываем tryUpdate чтобы сработало обновление
    for (0..1000) |_| {
        regulator.tryUpdate();
    }

    // RPS должен обновиться
    try testing.expectEqual(@as(usize, 5000), regulator.last_rps);
}
