#!/bin/bash

# Reliability test script for buddy-blocks
# Tests data persistence across server restarts

set -e

# Configuration
TEST_COUNT=${1:-1000}  # Number of objects to test (default: 100000)
SERVER_DIR="/home/alexstorm/distrib/4ir/ZIG/buddy-blocks"
export LD_LIBRARY_PATH="/home/alexstorm/distrib/4ir/ZIG/zig-lmdbx/zig-out/lib"
DB_PATH="/tmp/buddy-blocks.db"
DATA_FILE="/tmp/fastblock.data"
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

    # Kill all buddy-blocks-gnu processes immediately with SIGKILL
    pkill -9 -f "buddy-blocks-gnu" 2>/dev/null || true

    # Also kill any zig build processes
    pkill -9 -f "zig build run" 2>/dev/null || true

    # Wait a moment for cleanup
    sleep 1

    # Verify all processes are killed
    REMAINING=$(pgrep -f "buddy-blocks-gnu" 2>/dev/null || true)
    if [ -n "$REMAINING" ]; then
        log_warning "Some processes still running, force killing: $REMAINING"
        kill -9 $REMAINING 2>/dev/null || true
        sleep 1
    fi

    log_success "Server stopped (SIGKILL)"
}

# Function to start the server
start_server() {
    log "Starting server..."

    cd "$SERVER_DIR"

    # Start server binary directly with proper library path
    nohup env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ./zig-out/bin/buddy-blocks-gnu > /tmp/buddy-blocks-server.log 2>&1 &

    SERVER_START_PID=$!
    log "Server started with PID: $SERVER_START_PID"

    # Wait for server to be ready
    log "Waiting for server to start..."
    for i in {1..30}; do
        if curl -s http://localhost:8081/ > /dev/null 2>&1; then
            log_success "Server started successfully"
            sleep 1  # Extra second for stability
            return 0
        fi

        # Check if process is still alive
        if ! kill -0 $SERVER_START_PID 2>/dev/null; then
            log_error "Server process died during startup"
            log_error "Last 20 lines of server log:"
            tail -20 /tmp/buddy-blocks-server.log | tee -a "$TEST_LOG"
            return 1
        fi

        sleep 1
    done

    log_error "Server failed to start within 30 seconds"
    log_error "Last 20 lines of server log:"
    tail -20 /tmp/buddy-blocks-server.log | tee -a "$TEST_LOG"
    return 1
}

# Cleanup function for initial test setup
cleanup_initial() {
    log "Cleaning up for fresh test..."
    stop_server

    # Remove database for clean test
    if [ -d "$DB_PATH" ]; then
        rm -rf "$DB_PATH"
        log_success "Database removed"
    fi

    # Remove data file for clean test
    if [ -f "$DATA_FILE" ]; then
        rm -f "$DATA_FILE"
        log_success "Data file removed"
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
    cleanup_initial

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
    if go run rps.go -op=load -count=$TEST_COUNT -file="$PUSHED_FILE" -url="http://localhost:8081"; then
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
    if ! go run rps.go -op=check -file="$PUSHED_FILE" -url="http://localhost:8081"; then
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
