package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type config struct {
	serverURL         string
	blockSize         int
	numBlocks         int
	mode              string
	concurrency       int
	warmupConcurrency int
	duration          time.Duration
	requestTimeout    time.Duration
	verify            bool
	skipPut           bool
	skipDelete        bool
}

type stageResult struct {
	success  uint64
	failed   uint64
	bytes    uint64
	duration time.Duration
	examples []string
}

func parseFlags() config {
	cfg := config{}
	flag.StringVar(&cfg.serverURL, "url", "http://localhost:10001", "Base server URL")
	flag.IntVar(&cfg.blockSize, "block-size", 4096, "Block size in bytes")
	flag.IntVar(&cfg.numBlocks, "blocks", 50000, "Number of unique blocks to pre-generate")
	flag.StringVar(&cfg.mode, "mode", "load", "Mode: load (default) or sequential")
	flag.IntVar(&cfg.concurrency, "concurrency", 1024, "Number of concurrent workers for the load phase")
	flag.IntVar(&cfg.warmupConcurrency, "warmup-concurrency", 64, "Workers used for PUT/DELETE warmup phases")
	flag.DurationVar(&cfg.duration, "duration", 10*time.Second, "Duration of the sustained load phase")
	flag.DurationVar(&cfg.requestTimeout, "timeout", 5*time.Second, "Per-request timeout")
	flag.BoolVar(&cfg.verify, "verify", false, "Verify response payloads (slower but safer)")
	flag.BoolVar(&cfg.skipPut, "skip-put", false, "Skip the PUT warmup phase")
	flag.BoolVar(&cfg.skipDelete, "skip-delete", true, "Skip the DELETE cleanup phase")
	flag.Parse()

	if cfg.blockSize < 32 {
		fmt.Println("block-size must be >= 32 bytes")
		os.Exit(1)
	}
	if !strings.HasPrefix(cfg.serverURL, "http://") && !strings.HasPrefix(cfg.serverURL, "https://") {
		cfg.serverURL = "http://" + cfg.serverURL
	}
	if !strings.HasSuffix(cfg.serverURL, "/") {
		cfg.serverURL += "/"
	}
	cfg.serverURL = strings.TrimSuffix(cfg.serverURL, "/") // ensure single trailing slash removed

	if cfg.concurrency <= 0 {
		cfg.concurrency = runtime.NumCPU() * 4
	}
	if cfg.warmupConcurrency <= 0 {
		cfg.warmupConcurrency = runtime.NumCPU()
	}

	return cfg
}

func prepareBlocks(cfg config) ([][]byte, []string) {
	blocks := make([][]byte, cfg.numBlocks)
	hashes := make([]string, cfg.numBlocks)

	for i := 0; i < cfg.numBlocks; i++ {
		buf := make([]byte, cfg.blockSize)
		binary.LittleEndian.PutUint64(buf, uint64(i))
		fillByte := byte('A' + (i % 26))
		for j := 8; j < len(buf); j++ {
			buf[j] = fillByte
		}
		sum := sha256.Sum256(buf)
		blocks[i] = buf
		hashes[i] = hex.EncodeToString(sum[:])
	}

	return blocks, hashes
}

func newHTTPClient(cfg config) *http.Client {
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          cfg.concurrency * 4,
		MaxIdleConnsPerHost:   cfg.concurrency * 2,
		MaxConnsPerHost:       cfg.concurrency * 2,
		IdleConnTimeout:       30 * time.Second,
		ResponseHeaderTimeout: cfg.requestTimeout,
		DisableCompression:    true,
		DialContext: (&net.Dialer{
			Timeout:   2 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2: false,
	}
	return &http.Client{
		Transport: transport,
		Timeout:   cfg.requestTimeout,
	}
}

func runSequential(client *http.Client, cfg config, blocks [][]byte, hashes []string) {
	fmt.Printf("=== Go Sequential Benchmark: %d blocks x %d bytes ===\n", cfg.numBlocks, cfg.blockSize)

	putRes := runIndexedPhase("PUT", cfg, client, cfg.numBlocks, 1, func(idx int) error {
		return doPut(client, cfg, blocks[idx], hashes[idx], true)
	})
	printPhase("PUT", putRes, cfg.blockSize)

	getRes := runIndexedPhase("GET", cfg, client, cfg.numBlocks, 1, func(idx int) error {
		return doGet(client, cfg, hashes[idx], blocks[idx], true)
	})
	printPhase("GET", getRes, cfg.blockSize)

	delRes := runIndexedPhase("DELETE", cfg, client, cfg.numBlocks, 1, func(idx int) error {
		return doDelete(client, cfg, hashes[idx])
	})
	printPhase("DELETE", delRes, cfg.blockSize)

	total := putRes.duration + getRes.duration + delRes.duration
	fmt.Printf("Total time: %.2fs\n", total.Seconds())
}

func runLoad(client *http.Client, cfg config, blocks [][]byte, hashes []string) {
	fmt.Printf("=== Go Load Benchmark: %d workers, %d blocks, duration %s ===\n", cfg.concurrency, cfg.numBlocks, cfg.duration)

	if !cfg.skipPut {
		fmt.Println("Warmup PUT phase...")
		putRes := runIndexedPhase("PUT", cfg, client, cfg.numBlocks, cfg.warmupConcurrency, func(idx int) error {
			return doPut(client, cfg, blocks[idx], hashes[idx], cfg.verify)
		})
		printPhase("PUT", putRes, cfg.blockSize)
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.duration)
	defer cancel()

	var total uint64
	var success uint64
	var failed uint64
	var totalLatency int64
	start := time.Now()

	var wg sync.WaitGroup
	wg.Add(cfg.concurrency)

	for i := 0; i < cfg.concurrency; i++ {
		workerID := i
		go func() {
			defer wg.Done()
			seed := time.Now().UnixNano() + int64(workerID)
			r := rand.New(rand.NewSource(seed))
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}

				idx := r.Intn(len(hashes))
				reqStart := time.Now()
				err := doGet(client, cfg, hashes[idx], blocks[idx], cfg.verify)
				elapsed := time.Since(reqStart)

				atomic.AddUint64(&total, 1)
				atomic.AddInt64(&totalLatency, elapsed.Nanoseconds())
				if err != nil {
					atomic.AddUint64(&failed, 1)
				} else {
					atomic.AddUint64(&success, 1)
				}
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start)

	if elapsed <= 0 {
		elapsed = cfg.duration
	}

	successRPS := float64(success) / elapsed.Seconds()
	totalRPS := float64(total) / elapsed.Seconds()
	fmt.Printf("LOAD GET: total=%d success=%d failed=%d | total rps=%.2f success rps=%.2f | duration %.2fs\n",
		total, success, failed, totalRPS, successRPS, elapsed.Seconds())

	if success > 0 {
		avg := time.Duration(atomic.LoadInt64(&totalLatency) / int64(success))
		fmt.Printf("Average success latency: %s\n", avg)
	}

	if !cfg.skipDelete {
		fmt.Println("Cleanup DELETE phase...")
		delRes := runIndexedPhase("DELETE", cfg, client, cfg.numBlocks, cfg.warmupConcurrency, func(idx int) error {
			return doDelete(client, cfg, hashes[idx])
		})
		printPhase("DELETE", delRes, cfg.blockSize)
	}
}

func runIndexedPhase(name string, cfg config, client *http.Client, totalItems int, concurrency int, op func(int) error) stageResult {
	start := time.Now()
	var success uint64
	var failed uint64
	var examplesMu sync.Mutex
	examples := make([]string, 0, 5)

	jobs := make(chan int, totalItems)
	for i := 0; i < totalItems; i++ {
		jobs <- i
	}
	close(jobs)

	var wg sync.WaitGroup
	workers := concurrency
	if workers <= 0 {
		workers = 1
	}

	wg.Add(workers)
	for w := 0; w < workers; w++ {
		go func() {
			defer wg.Done()
			for idx := range jobs {
				if err := op(idx); err != nil {
					atomic.AddUint64(&failed, 1)
					examplesMu.Lock()
					if len(examples) < 5 {
						examples = append(examples, err.Error())
					}
					examplesMu.Unlock()
				} else {
					atomic.AddUint64(&success, 1)
				}
			}
		}()
	}
	wg.Wait()

	return stageResult{
		success:  success,
		failed:   failed,
		bytes:    uint64(success) * uint64(cfg.blockSize),
		duration: time.Since(start),
		examples: examples,
	}
}

func printPhase(name string, res stageResult, blockSize int) {
	total := res.success + res.failed
	if res.duration <= 0 {
		res.duration = time.Nanosecond
	}
	rps := float64(res.success) / res.duration.Seconds()
	throughputMB := (float64(res.success*uint64(blockSize)) / (1024.0 * 1024.0)) / res.duration.Seconds()
	fmt.Printf("%s: success=%d failed=%d total=%d | %.2f ops/sec (%.2f MB/s) | %.2fs\n",
		name, res.success, res.failed, total, rps, throughputMB, res.duration.Seconds())
	if res.failed > 0 && len(res.examples) > 0 {
		fmt.Println("  sample errors:")
		for _, e := range res.examples {
			fmt.Printf("    - %s\n", e)
		}
	}
}

func doPut(client *http.Client, cfg config, payload []byte, expectedHash string, verify bool) error {
	req, err := http.NewRequest("PUT", cfg.serverURL+"/block", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.ContentLength = int64(len(payload))

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}

	if resp.StatusCode != http.StatusOK {
		snippet := strings.TrimSpace(string(body))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return fmt.Errorf("status %d body %q", resp.StatusCode, snippet)
	}

	if verify {
		returned := strings.TrimSpace(string(body))
		if returned != expectedHash {
			return fmt.Errorf("hash mismatch: got %s expected %s", returned, expectedHash)
		}
	}
	return nil
}

func doGet(client *http.Client, cfg config, hash string, expected []byte, verify bool) error {
	req, err := http.NewRequest("GET", cfg.serverURL+"/block/"+hash, nil)
	if err != nil {
		return err
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(resp.Body)
		snippet := strings.TrimSpace(string(message))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return fmt.Errorf("status %d body %q", resp.StatusCode, snippet)
	}

	if !verify {
		_, err = io.Copy(io.Discard, resp.Body)
		return err
	}

	buf := make([]byte, cfg.blockSize)
	n, err := io.ReadFull(resp.Body, buf)
	if err != nil {
		return err
	}
	if n != len(expected) {
		return fmt.Errorf("length mismatch: got %d want %d", n, len(expected))
	}
	if !bytes.Equal(buf[:n], expected) {
		return fmt.Errorf("payload mismatch")
	}
	return nil
}

func doDelete(client *http.Client, cfg config, hash string) error {
	req, err := http.NewRequest("DELETE", cfg.serverURL+"/block/"+hash, nil)
	if err != nil {
		return err
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		buf, _ := io.ReadAll(resp.Body)
		snippet := strings.TrimSpace(string(buf))
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		return fmt.Errorf("status %d body %q", resp.StatusCode, snippet)
	}
	return nil
}

func main() {
	cfg := parseFlags()

	blocks, hashes := prepareBlocks(cfg)
	client := newHTTPClient(cfg)

	switch cfg.mode {
	case "sequential":
		runSequential(client, cfg, blocks, hashes)
	case "load":
		runLoad(client, cfg, blocks, hashes)
	default:
		fmt.Printf("unknown mode %q\n", cfg.mode)
		os.Exit(1)
	}
}
