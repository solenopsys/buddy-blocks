
  Весь код управления pipeline успешно вынесен в PipelineController. Вот что было сделано:

  Изменения в PipelineController (src/pipeline_controller.zig):

  1. Добавлена обработка всех операций pipeline:
    - handleSpliceSocketToPipe - чтение данных из HTTP socket в pipe
    - handleTee - дублирование данных в pipe2
    - handleSpliceToFile - запись в файл
    - handleSpliceToHash - отправка в AF_ALG для хеширования
  2. Добавлена обработка POLL для медленных прокси:
    - handlePollSocket - повторяет splice когда данные доступны на socket
  3. Расширен PipelineResult:
    - Добавлен статус need_poll для медленных прокси
    - Добавлено поле hash с готовым хешем
    - Добавлено поле send_response для уведомления HTTP сервера
  4. Добавлен метод startSocketSplice:
    - Запускает начальный splice из HTTP socket в pipe

  Изменения в interfaces.zig:

  1. Расширен PipelineState:
    - Добавлены conn_fd и block_info для HTTP контекста
    - Добавлен флаг hash_splice_started для предотвращения дублирования

  Изменения в http.zig:

  1. Упрощен handlePipeline: ~200 строк → ~70 строк
    - Вся логика делегирована контроллеру
    - Только обработка результата и отправка ответа
  2. Упрощен handlePollSocket: ~20 строк → ~20 строк (но без логики)
    - Делегирование контроллеру
  3. Обновлен handlePut:
    - Использует startSocketSplice для получения данных из socket
    - Использует startPipeline когда все данные в pipe

  Результаты тестирования:

  ✓ Все pipeline тесты прошли (basic + chunked)
  ✓ Все компонентные тесты прошли
  ✓ Проект собирается без ошибок

  Теперь PipelineController полностью управляет всем потоком данных через pipe/tee/splice операции, а HTTP сервер
  просто делегирует работу контроллеру и обрабатывает результаты!
