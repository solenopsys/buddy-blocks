#!/bin/bash

# Загрузка модулей ядра для AF_ALG (kernel crypto API)

echo "Загрузка модулей ядра для AF_ALG..."

# Проверка прав sudo
if [ "$EUID" -ne 0 ]; then
    echo "Требуются права root. Запуск через sudo..."
    sudo modprobe af_alg
    sudo modprobe algif_hash
else
    modprobe af_alg
    modprobe algif_hash
fi

echo "Модули загружены успешно!"
echo ""
echo "Проверка доступности sha256 в /proc/crypto:"
grep -A 2 "^name.*sha256$" /proc/crypto | head -n 6
