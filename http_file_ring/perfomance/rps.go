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
	"time"
)

var (
	SERVER_URL  = "http://localhost:8080"
	BLOCK_SIZE  = 4096 * 2 * 2 * 2 * 2 * 2 * 2 * 2
	ITERATIONS  = 1000
	REQ_TIMEOUT = 5 * time.Second
	NUM_BLOCKS  = 2
)

func main() {
	// Получаем размер блока из аргумента или используем 4KB по умолчанию
	// Допустимые размеры: 4, 8, 16, 32, 64, 128, 256, 512 (KB)
	if len(os.Args) > 1 {
		size, err := strconv.Atoi(os.Args[1])
		if err == nil {
			BLOCK_SIZE = size * 1024
		}
	}

	fmt.Println("============================================================")
	fmt.Println("Тестирование HTTP сервера - PUT/GET с проверкой данных (Go)")
	fmt.Println("============================================================")

	// Генерируем 2 блока
	fmt.Printf("\nГенерация %d блоков данных по %dKB...\n", NUM_BLOCKS, BLOCK_SIZE/1024)

	blocks := make([][]byte, NUM_BLOCKS)
	hashes := make([]string, NUM_BLOCKS)

	r := rand.New(rand.NewSource(time.Now().UnixNano()))

	for i := 0; i < NUM_BLOCKS; i++ {
		blocks[i] = make([]byte, BLOCK_SIZE)
		r.Read(blocks[i])

		hashSum := sha256.Sum256(blocks[i])
		hashes[i] = hex.EncodeToString(hashSum[:])
	}

	fmt.Println("Блоки сгенерированы")

	// HTTP клиент с ОДНИМ соединением
	client := &http.Client{
		Timeout: REQ_TIMEOUT,
		Transport: &http.Transport{
			MaxIdleConnsPerHost: 1,
			MaxIdleConns:        1,
			MaxConnsPerHost:     1,
			IdleConnTimeout:     30 * time.Second,
			DisableKeepAlives:   false,
		},
	}

	putSuccess := 0
	getSuccess := 0
	putErrors := 0
	getErrors := 0
	hashMismatch := 0
	dataMismatch := 0

	fmt.Printf("\nЗапуск циклов PUT/GET для %d блоков (%d итераций)...\n", NUM_BLOCKS, ITERATIONS)

	startTime := time.Now()

	for i := 0; i < ITERATIONS; i++ {
		blockIdx := i % NUM_BLOCKS
		block := blocks[blockIdx]
		expectedHash := hashes[blockIdx]

		// PUT запрос
		req, err := http.NewRequest("PUT", SERVER_URL, bytes.NewReader(block))
		if err != nil {
			fmt.Printf("  ✗ PUT ошибка создания запроса (итерация %d, блок %d): %v\n", i+1, blockIdx, err)
			putErrors++
			continue
		}
		req.ContentLength = int64(len(block))

		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("  ✗ PUT ошибка запроса (итерация %d, блок %d): %v\n", i+1, blockIdx, err)
			putErrors++
			continue
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()

		if err != nil {
			fmt.Printf("  ✗ PUT ошибка чтения ответа (итерация %d, блок %d): %v\n", i+1, blockIdx, err)
			putErrors++
			continue
		}

		if resp.StatusCode != 200 {
			fmt.Printf("  ✗ PUT HTTP ошибка (итерация %d, блок %d): %d\n", i+1, blockIdx, resp.StatusCode)
			putErrors++
			continue
		}

		returnedHash := string(bytes.TrimSpace(body))
		if returnedHash != expectedHash {
			fmt.Printf("  ✗ PUT хеш не совпадает (итерация %d, блок %d)! Ожидали: %s, получили: %s\n", i+1, blockIdx, expectedHash, returnedHash)
			hashMismatch++
			continue
		}

		putSuccess++

		// GET запрос - сразу после PUT читаем тот же блок по полученному хешу
		getURL := fmt.Sprintf("%s/%s", SERVER_URL, returnedHash)
		getReq, err := http.NewRequest("GET", getURL, nil)
		if err != nil {
			fmt.Printf("  ✗ GET ошибка создания запроса (итерация %d, блок %d): %v\n", i+1, blockIdx, err)
			getErrors++
			continue
		}

		getResp, err := client.Do(getReq)
		if err != nil {
			fmt.Printf("  ✗ GET ошибка запроса (итерация %d, блок %d): %v\n", i+1, blockIdx, err)
			getErrors++
			continue
		}

		retrievedData, err := io.ReadAll(getResp.Body)
		getResp.Body.Close()

		if err != nil {
			fmt.Printf("  ✗ GET ошибка чтения данных (итерация %д, блок %d): %v\n", i+1, blockIdx, err)
			getErrors++
			continue
		}

		if getResp.StatusCode != 200 {
			fmt.Printf("  ✗ GET HTTP ошибка (итерация %d, блок %d): %d\n", i+1, blockIdx, getResp.StatusCode)
			getErrors++
			continue
		}

		// Проверяем целостность данных
		if !bytes.Equal(retrievedData, block) {
			fmt.Printf("  ✗ GET данные не совпадают (итерация %d, блок %d)! Размер: ожидали %d, получили %d\n", i+1, blockIdx, len(block), len(retrievedData))
			dataMismatch++
			continue
		}

		getSuccess++
	}

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
	fmt.Printf("Пропускная способность: %.2f МБ/сек\n", float64(totalOps*BLOCK_SIZE)/(1024*1024*elapsed.Seconds()))
	fmt.Println("============================================================")
}
