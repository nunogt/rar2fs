#!/bin/bash
#
# run-asan-tests.sh - Run tests with AddressSanitizer
#
# This script:
# 1. Checks if rar2fs is built with ASan
# 2. Runs basic tests under ASan to detect memory errors
# 3. Reports any ASan violations
#
# AddressSanitizer detects:
# - Buffer overflows
# - Use-after-free
# - Memory leaks
# - Double-free
# - Use of uninitialized memory
#
# Prerequisites:
# - rar2fs built with ASan (./build-with-asan.sh)
# - Test archives in ../archives/
#

set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$TEST_ROOT")"
ARCHIVE_DIR="$TEST_ROOT/archives"
RESULTS_DIR="$TEST_ROOT/results"
MOUNT_DIR="$TEST_ROOT/mount"

# Binary
RAR2FS="$PROJECT_ROOT/src/rar2fs"

# Log file
LOG_FILE="$RESULTS_DIR/run-asan-tests-$(date +%Y%m%d-%H%M%S).log"
ASAN_LOG="$RESULTS_DIR/asan-output-$(date +%Y%m%d-%H%M%S).log"

# Create necessary directories
mkdir -p "$RESULTS_DIR" "$MOUNT_DIR"

# Function to print and log
log() {
    echo -e "$@" | tee -a "$LOG_FILE"
}

# Function to unmount safely
safe_unmount() {
    local mount_point="$1"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount -u "$mount_point" 2>/dev/null || true
        sleep 0.5
    fi
}

# Check if ASan is enabled
check_asan() {
    log "${BLUE}Checking if rar2fs is built with AddressSanitizer...${NC}"

    # Check if binary exists
    if [ ! -f "$RAR2FS" ]; then
        log "${RED}ERROR:${NC} rar2fs binary not found at: $RAR2FS"
        log "Run './build-with-asan.sh' to build with ASan"
        return 1
    fi

    # Check if ASan is linked (look for asan in ldd or strings)
    if ldd "$RAR2FS" 2>/dev/null | grep -q asan; then
        log "${GREEN}OK:${NC} AddressSanitizer detected in binary"
        return 0
    elif strings "$RAR2FS" 2>/dev/null | grep -q "AddressSanitizer"; then
        log "${GREEN}OK:${NC} AddressSanitizer detected in binary"
        return 0
    else
        log "${YELLOW}WARNING:${NC} AddressSanitizer may not be enabled"
        log "For best results, rebuild with: ./build-with-asan.sh"
        log "Continuing anyway..."
        return 0
    fi
}

# Run a single archive test under ASan
test_with_asan() {
    local archive_name="$1"
    local archive="$ARCHIVE_DIR/$archive_name"

    log ""
    log "${BLUE}Testing:${NC} $archive_name"

    if [ ! -f "$archive" ]; then
        log "${YELLOW}SKIP:${NC} Archive not found: $archive"
        return 0
    fi

    # Clean mount point
    safe_unmount "$MOUNT_DIR"

    # Set ASan options for detailed output
    export ASAN_OPTIONS="log_path=$RESULTS_DIR/asan-$archive_name:halt_on_error=0:detect_leaks=1"

    # Try to mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    local mount_result=$?

    # If mounted successfully
    if mountpoint -q "$MOUNT_DIR"; then
        # List files
        ls -la "$MOUNT_DIR" >> "$LOG_FILE" 2>&1

        # Try to read first file
        local first_file=$(ls -1 "$MOUNT_DIR" 2>/dev/null | head -1)
        if [ -n "$first_file" ]; then
            cat "$MOUNT_DIR/$first_file" > /dev/null 2>> "$LOG_FILE"
            md5sum "$MOUNT_DIR/$first_file" >> "$LOG_FILE" 2>&1
        fi

        # Unmount
        safe_unmount "$MOUNT_DIR"
    fi

    # Check for ASan output
    if ls "$RESULTS_DIR"/asan-$archive_name.* 1> /dev/null 2>&1; then
        log "${RED}ASan ERRORS DETECTED${NC} - see $RESULTS_DIR/asan-$archive_name.*"
        cat "$RESULTS_DIR"/asan-$archive_name.* >> "$ASAN_LOG"
        return 1
    else
        log "${GREEN}OK:${NC} No ASan errors"
        return 0
    fi
}

# Main execution
log "=================================================="
log "RAR2FS AddressSanitizer Test Suite"
log "=================================================="
log "Started: $(date)"
log "Binary: $RAR2FS"
log "Archives: $ARCHIVE_DIR"
log "ASan log: $ASAN_LOG"
log "Log file: $LOG_FILE"
log ""

# Check ASan
if ! check_asan; then
    exit 1
fi

log ""
log "${YELLOW}=== RUNNING TESTS UNDER ASAN ===${NC}"

# Track results
total=0
passed=0
failed=0

# Test all archives
archives=(
    "01-single-uncompressed.rar"
    "02-single-compressed.rar"
    "03-multifile.rar"
    "04-nested-dirs.rar"
    "05-large-compressible.rar"
    "06-truncated.rar"
    "07-random-data.rar"
    "08-empty.rar"
    "09-invalid-signature.rar"
    "10-too-small.rar"
    "11-solid.rar"
    "12-max-compression.rar"
    "13-binary-data.rar"
)

for archive in "${archives[@]}"; do
    total=$((total + 1))
    if test_with_asan "$archive"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
    fi
done

# Final cleanup
safe_unmount "$MOUNT_DIR"
unset ASAN_OPTIONS

# Summary
log ""
log "=================================================="
log "ASAN TEST SUMMARY"
log "=================================================="
log "Total tests: $total"
log "${GREEN}Passed (no ASan errors): $passed${NC}"
if [ $failed -gt 0 ]; then
    log "${RED}Failed (ASan errors detected): $failed${NC}"
    log ""
    log "${RED}ASan errors were detected!${NC}"
    log "Review detailed output in: $ASAN_LOG"
else
    log "Failed: $failed"
    log ""
    log "${GREEN}SUCCESS: No memory errors detected!${NC}"
fi
log ""
log "Completed: $(date)"
log "=================================================="

# Exit with appropriate code
if [ $failed -gt 0 ]; then
    exit 1
fi

exit 0
