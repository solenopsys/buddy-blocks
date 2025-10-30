Минимальный демонстратор который будет писать входящие данные http в определенную область файла и вычислять хеши.
при этои спользовать функции ядра io_uring, splice, AF_ALG, tee, user_data

## Требования

Для работы с AF_ALG необходимо загрузить модули ядра:
```bash
sudo modprobe af_alg
sudo modprobe algif_hash
```

Или использовать скрипт:
```bash
./modules.sh
```

## Запуск

```bash
# Сборка и запуск сервера (порт 8080)
zig build run

# В другом терминале - тестирование
python3 perfomance/basic.py
```

## Технологии
io_uring - кольцевые буферы
splice - копирование данных внутри ядра
tee - сплит внутри ядра для того чтобы сделать хеш внутри
AF_ALG - подсчет хеша внутри ядра (один socket, создать при старте и переиспользовать)

 
Алгоритм
читаем заголовок в пространсве пользователя дальше делаем splice

splice(socket→pipe1)
    tee(pipe1→pipe2)
      - splice(pipe1→file)
      - splice(pipe2→op)
        - read(op) - вытаскиваем хеш

Детали реализации:
- Размеры блоков переменные, ядро само управляет через splice(len)
- Записывать ровно столько данных, сколько указано в Content-Length HTTP заголовка
- Хеш просто передается в onHashForBlock() после вычисления 



## интерфейс WorkerServiceInterface 
будет содержать несколько методов
  - onBlockInputRequest(size_index: u8)-> {block_num: u64 } - возращает блок файла заданного размера 
  - onHashForBlock(hash: [32]u8, block_num: u64, size_index: u8) - передается хеш, номер блока и размер
  - onFreeBlockRequetst(hash: [32]u8 )->{ block_num: u64, size_index: u8} - передается хеш, возвращается номер блока и размер
  - onBlockAddressRequest(hash: [32]u8)-> {block_num: u64, size_index: u8} - передается хеш, возвращается номер блока и размер


zig build --Dmusl=true -Doptimize=ReleaseFast
 podman build -t http_file_ring -f Containerfile .

 podman run -d --name http_file_ring --privileged -p 8080:8080 -v ./data:/data:Z http_file_ring