package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

var (
	SERVER_URL  = "http://localhost:8080"
	BLOCK_SIZE  = 4096*2*2*2*2*2*2*2 - 256
	ITERATIONS  = 100
	REQ_TIMEOUT = 10 * time.Second
	NUM_WORKERS = 16  // Количество параллельных горутин
	NUM_BLOCKS  = 100 // Количество уникальных блоков
)

func main() {
	if v := os.Getenv("NUM_WORKERS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			NUM_WORKERS = n
		}
	}
	if v := os.Getenv("ITERATIONS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			ITERATIONS = n
		}
	}
	if v := os.Getenv("NUM_BLOCKS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			NUM_BLOCKS = n
		}
	}

	// Получаем размер блока из аргумента или используем 4KB по умолчанию
	// Допустимые размеры: 4, 8, 16, 32, 64, 128, 256, 512 (KB)
	if len(os.Args) > 1 {
		size, err := strconv.Atoi(os.Args[1])
		if err == nil {
			BLOCK_SIZE = size * 1024
		}
	}

	fmt.Println("============================================================")
	fmt.Printf("Тестирование HTTP сервера - ПАРАЛЛЕЛЬНЫЙ PUT/GET (%d потоков)\n", NUM_WORKERS)
	fmt.Println("============================================================")

	// Генерируем уникальные блоки
	fmt.Printf("\nГенерация %d блоков данных по %dKB...\n", NUM_BLOCKS, BLOCK_SIZE/1024)

	blocks := make([][]byte, NUM_BLOCKS)
	hashes := make([]string, NUM_BLOCKS)

	r := rand.New(rand.NewSource(time.Now().UnixNano()))

	for i := 0; i < NUM_BLOCKS; i++ {
		blocks[i] = make([]byte, BLOCK_SIZE)
		// Делаем первые 8 байт уникальными (номер блока)
		blocks[i][0] = byte(i >> 24)
		blocks[i][1] = byte(i >> 16)
		blocks[i][2] = byte(i >> 8)
		blocks[i][3] = byte(i)
		r.Read(blocks[i][8:]) // Остальное - случайные данные

		hashSum := sha256.Sum256(blocks[i])
		hashes[i] = hex.EncodeToString(hashSum[:])
	}

	fmt.Println("Блоки сгенерированы")

	// Атомарные счетчики для статистики
	var putSuccess, getSuccess, putErrors, getErrors, hashMismatch, dataMismatch int64

	fmt.Printf("\nФаза 1: Параллельная запись блоков (%d потоков, %d итераций на поток)...\n", NUM_WORKERS, ITERATIONS/NUM_WORKERS)

	startTime := time.Now()

	var wg sync.WaitGroup
	iterationsPerWorker := ITERATIONS / NUM_WORKERS

	// Фаза 1: Все PUT запросы
	for w := 0; w < NUM_WORKERS; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()

			client := &http.Client{
				Timeout: REQ_TIMEOUT,
				Transport: &http.Transport{
					MaxIdleConnsPerHost: 10,
					MaxConnsPerHost:     10,
					IdleConnTimeout:     30 * time.Second,
					DisableKeepAlives:   false,
				},
			}

			for i := 0; i < iterationsPerWorker; i++ {
				blockIdx := (workerID*iterationsPerWorker + i) % NUM_BLOCKS
				block := blocks[blockIdx]
				expectedHash := hashes[blockIdx]

				// PUT запрос
				req, err := http.NewRequest("PUT", SERVER_URL, bytes.NewReader(block))
				if err != nil {
					fmt.Printf("  ✗ Worker %d: PUT ошибка создания запроса (блок %d): %v\n", workerID, blockIdx, err)
					atomic.AddInt64(&putErrors, 1)
					continue
				}
				req.ContentLength = int64(len(block))

				resp, err := client.Do(req)
				if err != nil {
					fmt.Printf("  ✗ Worker %d: PUT ошибка запроса (блок %d): %v\n", workerID, blockIdx, err)
					atomic.AddInt64(&putErrors, 1)
					continue
				}

				body, err := io.ReadAll(resp.Body)
				resp.Body.Close()

				if err != nil {
					fmt.Printf("  ✗ Worker %d: PUT ошибка чтения ответа (блок %d): %v\n", workerID, blockIdx, err)
					atomic.AddInt64(&putErrors, 1)
					continue
				}

				if resp.StatusCode != 200 {
					fmt.Printf("  ✗ Worker %d: PUT HTTP ошибка (блок %d): %d\n", workerID, blockIdx, resp.StatusCode)
					atomic.AddInt64(&putErrors, 1)
					continue
				}

				returnedHash := string(bytes.TrimSpace(body))
				if returnedHash != expectedHash {
					fmt.Printf("  ✗ Worker %d: PUT хеш не совпадает (блок %d)!\n    Ожидали: %s\n    Получили: %s\n", workerID, blockIdx, expectedHash, returnedHash)
					atomic.AddInt64(&hashMismatch, 1)
					continue
				}

				atomic.AddInt64(&putSuccess, 1)
			}
		}(w)
	}

	wg.Wait()
	fmt.Printf("Фаза 1 завершена. PUT успешно: %d, ошибок: %d\n", putSuccess, putErrors+hashMismatch)

	// Фаза 2: Все GET запросы
	fmt.Printf("\nФаза 2: Параллельное чтение блоков (%d потоков, %d итераций на поток)...\n", NUM_WORKERS, ITERATIONS/NUM_WORKERS)

	for w := 0; w < NUM_WORKERS; w++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()

			client := &http.Client{
				Timeout: REQ_TIMEOUT,
				Transport: &http.Transport{
					MaxIdleConnsPerHost: 10,
					MaxConnsPerHost:     10,
					IdleConnTimeout:     30 * time.Second,
					DisableKeepAlives:   false,
				},
			}

			for i := 0; i < iterationsPerWorker; i++ {
				blockIdx := (workerID*iterationsPerWorker + i) % NUM_BLOCKS
				block := blocks[blockIdx]
				expectedHash := hashes[blockIdx]

				// GET запрос
				getURL := fmt.Sprintf("%s/%s", SERVER_URL, expectedHash)
				getReq, err := http.NewRequest("GET", getURL, nil)
				if err != nil {
					fmt.Printf("  ✗ Worker %d: GET ошибка создания запроса (блок %d): %v\n", workerID, blockIdx, err)
					atomic.AddInt64(&getErrors, 1)
					continue
				}

				getResp, err := client.Do(getReq)
				if err != nil {
					fmt.Printf("  ✗ Worker %d: GET ошибка запроса (блок %d): %v\n", workerID, blockIdx, err)
					atomic.AddInt64(&getErrors, 1)
					continue
				}

				retrievedData, err := io.ReadAll(getResp.Body)
				getResp.Body.Close()

				if err != nil {
					fmt.Printf("  ✗ Worker %d: GET ошибка чтения данных (блок %d): %v\n", workerID, blockIdx, err)
					atomic.AddInt64(&getErrors, 1)
					continue
				}

				if getResp.StatusCode != 200 {
					fmt.Printf("  ✗ Worker %d: GET HTTP ошибка (блок %d): %d, hash: %s\n", workerID, blockIdx, getResp.StatusCode, expectedHash)
					atomic.AddInt64(&getErrors, 1)
					continue
				}

				// Проверяем целостность данных
				if !bytes.Equal(retrievedData, block) {
					fmt.Printf("  ✗ Worker %d: GET данные не совпадают (блок %d)! Размер: ожидали %d, получили %d\n", workerID, blockIdx, len(block), len(retrievedData))
					atomic.AddInt64(&dataMismatch, 1)
					continue
				}

				atomic.AddInt64(&getSuccess, 1)
			}
		}(w)
	}

	wg.Wait()
	elapsed := time.Since(startTime)
	totalOps := putSuccess + getSuccess
	totalErrors := putErrors + getErrors + hashMismatch + dataMismatch

	fmt.Println("\n============================================================")
	fmt.Printf("Тестирование завершено\n")
	fmt.Printf("PUT успешно: %d\n", putSuccess)
	fmt.Printf("GET успешно: %d\n", getSuccess)
	fmt.Printf("Всего успешных операций: %d\n", totalOps)
	fmt.Printf("PUT ошибок: %d\n", putErrors)
	fmt.Printf("GET ошибок: %d\n", getErrors)
	fmt.Printf("Несовпадений хеша: %d\n", hashMismatch)
	fmt.Printf("Несовпадений данных: %d\n", dataMismatch)
	fmt.Printf("Всего ошибок: %d\n", totalErrors)
	fmt.Printf("Всего итераций: %d (ожидалось операций: %d)\n", ITERATIONS, ITERATIONS*2)
	fmt.Printf("Время выполнения: %.2f секунд\n", elapsed.Seconds())
	fmt.Printf("Скорость: %.2f операций/сек\n", float64(totalOps)/elapsed.Seconds())
	fmt.Printf("Пропускная способность: %.2f МБ/сек\n", (float64(totalOps)*float64(BLOCK_SIZE))/(1024*1024*elapsed.Seconds()))
	fmt.Println("============================================================")
}
