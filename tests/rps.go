package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type config struct {
	serverURL      string
	operation      string
	concurrency    int
	requestTimeout time.Duration
	pushedFile     string
	maxCount       int // Maximum number of objects to push (0 = unlimited)
}

// Block sizes: 4KB, 8KB, 16KB, 32KB, 64KB, 128KB, 256KB, 512KB
var blockSizes = []int{
	4 * 1024,
	8 * 1024,
	16 * 1024,
	32 * 1024,
	64 * 1024,
	128 * 1024,
	256 * 1024,
	512 * 1024,
}

type blockRecord struct {
	hash     string
	data     []byte
	sizeIdx  int
}

func parseFlags() config {
	cfg := config{}
	flag.StringVar(&cfg.serverURL, "url", "http://localhost:10001", "Base server URL")
	flag.StringVar(&cfg.operation, "op", "load", "Operation: load or check")
	flag.IntVar(&cfg.concurrency, "concurrency", runtime.NumCPU(), "Number of concurrent workers")
	flag.DurationVar(&cfg.requestTimeout, "timeout", 10*time.Second, "Per-request timeout")
	flag.StringVar(&cfg.pushedFile, "file", "pushed.txt", "File to store/read hashes")
	flag.IntVar(&cfg.maxCount, "count", 0, "Maximum number of objects to push (0 = unlimited)")
	flag.Parse()

	if !strings.HasPrefix(cfg.serverURL, "http://") && !strings.HasPrefix(cfg.serverURL, "https://") {
		cfg.serverURL = "http://" + cfg.serverURL
	}
	cfg.serverURL = strings.TrimSuffix(cfg.serverURL, "/")

	if cfg.concurrency <= 0 {
		cfg.concurrency = runtime.NumCPU()
	}

	return cfg
}

func newHTTPClient(cfg config) *http.Client {
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          cfg.concurrency * 4,
		MaxIdleConnsPerHost:   cfg.concurrency * 2,
		MaxConnsPerHost:       cfg.concurrency * 2,
		IdleConnTimeout:       60 * time.Second,
		ResponseHeaderTimeout: cfg.requestTimeout,
		DisableCompression:    true,
		DialContext: (&net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 60 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2: false,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   cfg.requestTimeout,
	}
}

func generateRandomBlock(sizeIdx int, seed int64) blockRecord {
	size := blockSizes[sizeIdx]
	data := make([]byte, size)

	r := rand.New(rand.NewSource(seed))
	r.Read(data)

	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])

	return blockRecord{
		hash:    hash,
		data:    data,
		sizeIdx: sizeIdx,
	}
}

func doPut(client *http.Client, cfg config, payload []byte) (string, error) {
	req, err := http.NewRequest("PUT", cfg.serverURL+"/", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.ContentLength = int64(len(payload))

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	if resp.StatusCode != http.StatusOK {
		snippet := strings.TrimSpace(string(body))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return "", fmt.Errorf("PUT status %d: %s", resp.StatusCode, snippet)
	}

	return strings.TrimSpace(string(body)), nil
}

func doGet(client *http.Client, cfg config, hash string) ([]byte, error) {
	req, err := http.NewRequest("GET", cfg.serverURL+"/"+hash, nil)
	if err != nil {
		return nil, err
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(resp.Body)
		snippet := strings.TrimSpace(string(message))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return nil, fmt.Errorf("GET status %d: %s", resp.StatusCode, snippet)
	}

	return io.ReadAll(resp.Body)
}

func runLoad(client *http.Client, cfg config) {
	fmt.Printf("=== LOAD Mode ===\n")
	fmt.Printf("Server: %s\n", cfg.serverURL)
	fmt.Printf("Concurrency: %d\n", cfg.concurrency)
	fmt.Printf("Output file: %s\n", cfg.pushedFile)
	fmt.Printf("Block sizes: 4KB-512KB (8 sizes)\n")
	if cfg.maxCount > 0 {
		fmt.Printf("Max objects: %d\n", cfg.maxCount)
	} else {
		fmt.Printf("Press Ctrl+C to stop\n")
	}
	fmt.Println()

	// Open file for appending hashes
	file, err := os.OpenFile(cfg.pushedFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		fmt.Printf("Error opening file: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	var fileMu sync.Mutex

	// Setup signal handling
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sigChan
		fmt.Println("\n\nReceived interrupt signal, stopping...")
		cancel()
	}()

	var totalOps uint64
	var successOps uint64
	var failedOps uint64
	var totalBytes uint64

	start := time.Now()

	// Stats printer
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				elapsed := time.Since(start).Seconds()
				total := atomic.LoadUint64(&totalOps)
				success := atomic.LoadUint64(&successOps)
				failed := atomic.LoadUint64(&failedOps)
				bytes := atomic.LoadUint64(&totalBytes)

				rps := float64(total) / elapsed
				mbps := (float64(bytes) / (1024 * 1024)) / elapsed

				fmt.Printf("[%.0fs] Total: %d | Success: %d | Failed: %d | %.2f ops/s | %.2f MB/s\n",
					elapsed, total, success, failed, rps, mbps)
			}
		}
	}()

	// Workers
	var wg sync.WaitGroup
	wg.Add(cfg.concurrency)

	for i := 0; i < cfg.concurrency; i++ {
		workerID := i
		go func() {
			defer wg.Done()
			r := rand.New(rand.NewSource(time.Now().UnixNano() + int64(workerID)))

			for {
				select {
				case <-ctx.Done():
					return
				default:
				}

				// Check if we've reached maxCount
				if cfg.maxCount > 0 && atomic.LoadUint64(&successOps) >= uint64(cfg.maxCount) {
					return
				}

				// Random size index (0-7)
				sizeIdx := r.Intn(len(blockSizes))
				seed := time.Now().UnixNano() + int64(workerID)*1000000 + int64(atomic.LoadUint64(&totalOps))

				block := generateRandomBlock(sizeIdx, seed)

				returnedHash, err := doPut(client, cfg, block.data)
				atomic.AddUint64(&totalOps, 1)

				if err != nil {
					atomic.AddUint64(&failedOps, 1)
					fmt.Printf("PUT failed: %v\n", err)
					fmt.Printf("\n✗ LOAD FAILED - stopping on first error\n")
					os.Exit(1)
				}

				// Verify hash matches
				if returnedHash != block.hash {
					atomic.AddUint64(&failedOps, 1)
					fmt.Printf("Hash mismatch! Expected: %s, Got: %s\n", block.hash, returnedHash)
					fmt.Printf("\n✗ LOAD FAILED - stopping on first error\n")
					os.Exit(1)
				}

				atomic.AddUint64(&successOps, 1)
				atomic.AddUint64(&totalBytes, uint64(len(block.data)))

				// Write to file
				fileMu.Lock()
				fmt.Fprintf(file, "%s %d\n", block.hash, sizeIdx)
				fileMu.Unlock()

				// Stop after reaching maxCount
				if cfg.maxCount > 0 && atomic.LoadUint64(&successOps) >= uint64(cfg.maxCount) {
					cancel() // Signal other workers to stop
					return
				}
			}
		}()
	}

	wg.Wait()

	elapsed := time.Since(start)
	total := atomic.LoadUint64(&totalOps)
	success := atomic.LoadUint64(&successOps)
	failed := atomic.LoadUint64(&failedOps)
	bytes := atomic.LoadUint64(&totalBytes)

	fmt.Printf("\n=== LOAD Complete ===\n")
	fmt.Printf("Duration: %.2fs\n", elapsed.Seconds())
	fmt.Printf("Total ops: %d\n", total)
	fmt.Printf("Success: %d\n", success)
	fmt.Printf("Failed: %d\n", failed)
	fmt.Printf("Total data: %.2f MB\n", float64(bytes)/(1024*1024))
	fmt.Printf("Average: %.2f ops/s | %.2f MB/s\n",
		float64(total)/elapsed.Seconds(),
		(float64(bytes)/(1024*1024))/elapsed.Seconds())
}

func runCheck(client *http.Client, cfg config) {
	fmt.Printf("=== CHECK Mode ===\n")
	fmt.Printf("Server: %s\n", cfg.serverURL)
	fmt.Printf("Concurrency: %d\n", cfg.concurrency)
	fmt.Printf("Input file: %s\n\n", cfg.pushedFile)

	// Read all hashes from file
	file, err := os.Open(cfg.pushedFile)
	if err != nil {
		fmt.Printf("Error opening file: %v\n", err)
		os.Exit(1)
	}
	defer file.Close()

	type hashEntry struct {
		hash    string
		sizeIdx int
	}

	var entries []hashEntry
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		var hash string
		var sizeIdx int
		_, err := fmt.Sscanf(line, "%s %d", &hash, &sizeIdx)
		if err != nil {
			continue
		}

		if sizeIdx < 0 || sizeIdx >= len(blockSizes) {
			continue
		}

		entries = append(entries, hashEntry{hash: hash, sizeIdx: sizeIdx})
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Error reading file: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Loaded %d hashes from file\n\n", len(entries))

	if len(entries) == 0 {
		fmt.Println("No hashes to check")
		return
	}

	var totalChecked uint64
	var successChecked uint64
	var failedChecked uint64
	var hashMismatches uint64
	var totalBytes uint64

	start := time.Now()

	// Work queue
	jobs := make(chan hashEntry, len(entries))
	for _, e := range entries {
		jobs <- e
	}
	close(jobs)

	// Workers
	var wg sync.WaitGroup
	wg.Add(cfg.concurrency)

	for i := 0; i < cfg.concurrency; i++ {
		go func() {
			defer wg.Done()

			for entry := range jobs {
				data, err := doGet(client, cfg, entry.hash)
				atomic.AddUint64(&totalChecked, 1)

				if err != nil {
					atomic.AddUint64(&failedChecked, 1)
					fmt.Printf("GET failed for %s: %v\n", entry.hash, err)
					fmt.Printf("\n✗ CHECK FAILED - stopping on first error\n")
					os.Exit(1)
				}

				// Verify hash
				sum := sha256.Sum256(data)
				computedHash := hex.EncodeToString(sum[:])

				if computedHash != entry.hash {
					atomic.AddUint64(&hashMismatches, 1)
					fmt.Printf("HASH MISMATCH! Expected: %s, Got: %s\n", entry.hash, computedHash)
					fmt.Printf("\n✗ CHECK FAILED - stopping on first error\n")
					os.Exit(1)
				}

				// Verify size
				expectedSize := blockSizes[entry.sizeIdx]
				if len(data) != expectedSize {
					atomic.AddUint64(&failedChecked, 1)
					fmt.Printf("SIZE MISMATCH for %s! Expected: %d, Got: %d\n",
						entry.hash, expectedSize, len(data))
					fmt.Printf("\n✗ CHECK FAILED - stopping on first error\n")
					os.Exit(1)
				}

				atomic.AddUint64(&successChecked, 1)
				atomic.AddUint64(&totalBytes, uint64(len(data)))

				// Progress indicator
				if atomic.LoadUint64(&totalChecked)%1000 == 0 {
					fmt.Printf("Checked: %d/%d\n", atomic.LoadUint64(&totalChecked), len(entries))
				}
			}
		}()
	}

	wg.Wait()

	elapsed := time.Since(start)
	total := atomic.LoadUint64(&totalChecked)
	success := atomic.LoadUint64(&successChecked)
	failed := atomic.LoadUint64(&failedChecked)
	mismatches := atomic.LoadUint64(&hashMismatches)
	bytes := atomic.LoadUint64(&totalBytes)

	fmt.Printf("\n=== CHECK Complete ===\n")
	fmt.Printf("Duration: %.2fs\n", elapsed.Seconds())
	fmt.Printf("Total checked: %d\n", total)
	fmt.Printf("Success: %d\n", success)
	fmt.Printf("Failed: %d\n", failed)
	fmt.Printf("Hash mismatches: %d\n", mismatches)
	fmt.Printf("Total data verified: %.2f MB\n", float64(bytes)/(1024*1024))
	fmt.Printf("Average: %.2f ops/s | %.2f MB/s\n",
		float64(total)/elapsed.Seconds(),
		(float64(bytes)/(1024*1024))/elapsed.Seconds())

	if success == total && mismatches == 0 && failed == 0 {
		fmt.Printf("\n✓ ALL CHECKS PASSED!\n")
	} else {
		fmt.Printf("\n✗ SOME CHECKS FAILED!\n")
		os.Exit(1)
	}
}

func main() {
	cfg := parseFlags()
	client := newHTTPClient(cfg)

	switch cfg.operation {
	case "load":
		runLoad(client, cfg)
	case "check":
		runCheck(client, cfg)
	default:
		fmt.Printf("Unknown operation: %s\n", cfg.operation)
		fmt.Println("Use -op=load or -op=check")
		os.Exit(1)
	}
}
