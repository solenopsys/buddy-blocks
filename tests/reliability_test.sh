#!/bin/bash

# Reliability test script for buddy-blocks
# Tests data persistence across server restarts

set -e

# Configuration
TEST_COUNT=${1:-1000}  # Number of objects to test (default: 100000)
SERVER_DIR="/home/alexstorm/distrib/4ir/ZIG/buddy-blocks"
export LD_LIBRARY_PATH="../zig-lmdbx/zig-out/lib"
DB_PATH="$SERVER_DIR/model/data/fastblock.lmdb"
PUSHED_FILE="$SERVER_DIR/tests/pushed.txt"
SERVER_PID_FILE="/tmp/buddy-blocks.pid"
TEST_LOG="$SERVER_DIR/tests/reliability_test.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$TEST_LOG"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓ $1${NC}" | tee -a "$TEST_LOG"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗ $1${NC}" | tee -a "$TEST_LOG"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠ $1${NC}" | tee -a "$TEST_LOG"
}

# Function to stop the server
stop_server() {
    log "Stopping server..."

    # Find and kill the server process
    SERVER_PID=$(ps aux | grep "buddy-blocks-gnu" | grep -v grep | awk '{print $2}')

    if [ -n "$SERVER_PID" ]; then
        log "Found server PID: $SERVER_PID"
        kill $SERVER_PID 2>/dev/null || true

        # Wait for process to die (max 10 seconds)
        for i in {1..10}; do
            if ! ps -p $SERVER_PID > /dev/null 2>&1; then
                log_success "Server stopped"
                break
            fi
            sleep 1
        done

        # Force kill if still running
        if ps -p $SERVER_PID > /dev/null 2>&1; then
            log_warning "Force killing server..."
            kill -9 $SERVER_PID 2>/dev/null || true
            sleep 1
        fi
    else
        log_warning "Server process not found"
    fi

    # Also kill any zig build processes
    pkill -f "zig build run" 2>/dev/null || true
    sleep 1
}

# Function to start the server
start_server() {
    log "Starting server..."

    cd "$SERVER_DIR"

    # Start server binary directly
    nohup ./zig-out/bin/buddy-blocks-gnu > /dev/null 2>&1 &

    # Wait for server to be ready
    log "Waiting for server to start..."
    for i in {1..30}; do
        if curl -s http://localhost:10001/ > /dev/null 2>&1; then
            log_success "Server started successfully"
            sleep 1  # Extra second for stability
            return 0
        fi
        sleep 1
    done

    log_error "Server failed to start within 30 seconds"
    return 1
}

# Cleanup function
cleanup() {
    log "Cleaning up..."
    stop_server

    # Remove database
    if [ -d "$DB_PATH" ]; then
        rm -rf "$DB_PATH"
        log_success "Database removed"
    fi

    # Remove pushed.txt
    if [ -f "$PUSHED_FILE" ]; then
        rm -f "$PUSHED_FILE"
        log_success "pushed.txt removed"
    fi
}

# Main test function
run_test() {
    log "=========================================="
    log "RELIABILITY TEST STARTED"
    log "Test count: $TEST_COUNT objects"
    log "=========================================="

    # Step 1: Cleanup
    log "\n=== Step 1: Initial cleanup ==="
    cleanup

    # Step 2: Start server
    log "\n=== Step 2: Starting server ==="
    if ! start_server; then
        log_error "Failed to start server"
        exit 1
    fi

    # Step 3: Load data
    log "\n=== Step 3: Loading test data ==="
    cd "$SERVER_DIR/tests"

    log "Pushing $TEST_COUNT objects..."
    if go run rps.go -op=load -count=$TEST_COUNT -file="$PUSHED_FILE" -url="http://localhost:10001"; then
        log_success "Data load completed"
    else
        log_error "Data load failed"
        stop_server
        exit 1
    fi

    # Count successful pushes
    PUSHED_COUNT=$(wc -l < "$PUSHED_FILE" 2>/dev/null || echo "0")
    log "Successfully pushed: $PUSHED_COUNT objects"

    if [ "$PUSHED_COUNT" -eq "0" ]; then
        log_error "No objects were pushed"
        stop_server
        exit 1
    fi

    # Step 4: Stop server
    log "\n=== Step 4: Stopping server ==="
    stop_server

    # Wait a bit to ensure everything is written
    sleep 3

    # Step 5: Restart server
    log "\n=== Step 5: Restarting server ==="
    if ! start_server; then
        log_error "Failed to restart server"
        exit 1
    fi

    # Step 6: Verify data integrity
    log "\n=== Step 6: Verifying data integrity ==="
    log "Checking $PUSHED_COUNT objects..."

    cd "$SERVER_DIR/tests"
    if ! go run rps.go -op=check -file="$PUSHED_FILE" -url="http://localhost:10001"; then
        log_error "Data verification failed"
        stop_server
        log "\n=========================================="
        log_error "RELIABILITY TEST FAILED ✗"
        log_error "Data integrity check failed"
        log "=========================================="
        exit 1
    fi

    log_success "Data verification completed successfully"

    # Step 7: Cleanup
    log "\n=== Step 7: Final cleanup ==="
    stop_server

    # Final report
    log "\n=========================================="
    log_success "RELIABILITY TEST PASSED ✓"
    log_success "All $PUSHED_COUNT objects persisted correctly after server restart"
    log "=========================================="
    exit 0
}

# Trap for cleanup on script exit
trap 'stop_server' EXIT INT TERM

# Clear previous log
> "$TEST_LOG"

# Run the test
run_test
