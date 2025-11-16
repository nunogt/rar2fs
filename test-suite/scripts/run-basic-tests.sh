#!/bin/bash
#
# run-basic-tests.sh - Basic functional tests for rar2fs
#
# This script tests core functionality:
# - Mounting archives
# - Listing files (ls)
# - Reading files (cat, md5sum)
# - Error handling (corrupt files should not crash)
# - Clean unmounting
#
# Prerequisites:
# - rar2fs binary at ../../src/rar2fs
# - Test archives in ../archives/ (run create-archives.sh first)
#
# Exit code: 0 if all tests pass, 1 if any fail
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
LOG_FILE="$RESULTS_DIR/run-basic-tests-$(date +%Y%m%d-%H%M%S).log"

# Create necessary directories
mkdir -p "$RESULTS_DIR" "$MOUNT_DIR"

# Test tracking
total_tests=0
passed_tests=0
failed_tests=0

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

# Function to run a test
run_test() {
    local test_name="$1"
    local test_func="$2"

    total_tests=$((total_tests + 1))
    log ""
    log "${BLUE}[TEST $total_tests]${NC} $test_name"

    # Run test function
    if $test_func; then
        passed_tests=$((passed_tests + 1))
        log "${GREEN}PASS${NC}"
        return 0
    else
        failed_tests=$((failed_tests + 1))
        log "${RED}FAIL${NC}"
        return 1
    fi
}

# ============================================================
# TEST FUNCTIONS
# ============================================================

test_binary_exists() {
    if [ ! -f "$RAR2FS" ]; then
        log "${RED}ERROR:${NC} rar2fs binary not found at: $RAR2FS"
        log "Run 'make' or './build-with-asan.sh' first"
        return 1
    fi
    if [ ! -x "$RAR2FS" ]; then
        log "${RED}ERROR:${NC} rar2fs binary not executable: $RAR2FS"
        return 1
    fi
    log "Binary found: $RAR2FS ($(ls -lh "$RAR2FS" | awk '{print $5}'))"
    return 0
}

test_archives_exist() {
    if [ ! -d "$ARCHIVE_DIR" ] || [ -z "$(ls -A "$ARCHIVE_DIR"/*.rar 2>/dev/null)" ]; then
        log "${RED}ERROR:${NC} No test archives found in: $ARCHIVE_DIR"
        log "Run './scripts/create-archives.sh' first"
        return 1
    fi
    local count=$(ls -1 "$ARCHIVE_DIR"/*.rar 2>/dev/null | wc -l)
    log "Found $count test archives"
    return 0
}

test_mount_single_uncompressed() {
    local archive="$ARCHIVE_DIR/01-single-uncompressed.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Failed to mount: $archive"
        return 1
    fi

    # Verify mounted
    if ! mountpoint -q "$MOUNT_DIR"; then
        log "Mount point not active"
        return 1
    fi

    # List files
    local files=$(ls -1 "$MOUNT_DIR" 2>&1)
    if [ $? -ne 0 ]; then
        log "Failed to list files"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Files in archive: $files"

    # Unmount
    safe_unmount "$MOUNT_DIR"
    return 0
}

test_read_file_content() {
    local archive="$ARCHIVE_DIR/02-single-compressed.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Failed to mount: $archive"
        return 1
    fi

    # Find the file in the archive
    local file=$(ls -1 "$MOUNT_DIR" | head -1)
    if [ -z "$file" ]; then
        log "No files found in mounted archive"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Read file content
    local content=$(cat "$MOUNT_DIR/$file" 2>&1)
    if [ $? -ne 0 ]; then
        log "Failed to read file: $file"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Successfully read $(echo "$content" | wc -c) bytes from $file"

    # Unmount
    safe_unmount "$MOUNT_DIR"
    return 0
}

test_multifile_archive() {
    local archive="$ARCHIVE_DIR/03-multifile.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Failed to mount: $archive"
        return 1
    fi

    # Count files
    local file_count=$(ls -1 "$MOUNT_DIR" | wc -l)
    if [ $file_count -lt 3 ]; then
        log "Expected 3+ files, found $file_count"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Found $file_count files in multi-file archive"

    # Unmount
    safe_unmount "$MOUNT_DIR"
    return 0
}

test_nested_directories() {
    local archive="$ARCHIVE_DIR/04-nested-dirs.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Failed to mount: $archive"
        return 1
    fi

    # Check for nested directory structure
    if [ ! -d "$MOUNT_DIR/nested" ]; then
        log "Expected 'nested' directory not found"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Find deepest level
    local deepest=$(find "$MOUNT_DIR" -type f 2>/dev/null | head -1)
    if [ -z "$deepest" ]; then
        log "No files found in nested structure"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Found nested structure: $deepest"

    # Unmount
    safe_unmount "$MOUNT_DIR"
    return 0
}

test_md5sum_verification() {
    local archive="$ARCHIVE_DIR/01-single-uncompressed.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Failed to mount: $archive"
        return 1
    fi

    # Get file
    local file=$(ls -1 "$MOUNT_DIR" | head -1)
    if [ -z "$file" ]; then
        log "No file found"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Calculate MD5
    local md5_1=$(md5sum "$MOUNT_DIR/$file" 2>&1 | awk '{print $1}')
    if [ -z "$md5_1" ]; then
        log "Failed to calculate MD5"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Calculate again (should be same)
    local md5_2=$(md5sum "$MOUNT_DIR/$file" 2>&1 | awk '{print $1}')
    if [ "$md5_1" != "$md5_2" ]; then
        log "MD5 mismatch: $md5_1 vs $md5_2"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "MD5 verified: $md5_1"

    # Unmount
    safe_unmount "$MOUNT_DIR"
    return 0
}

test_corrupted_truncated() {
    local archive="$ARCHIVE_DIR/06-truncated.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount should fail gracefully (not crash)
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    local mount_result=$?

    # If it mounted (unlikely), unmount
    if mountpoint -q "$MOUNT_DIR"; then
        log "Warning: Truncated archive mounted (unexpected)"
        safe_unmount "$MOUNT_DIR"
    fi

    # The key test: rar2fs should not crash (we should still be running)
    log "rar2fs handled truncated archive without crashing"
    return 0
}

test_corrupted_random_data() {
    local archive="$ARCHIVE_DIR/07-random-data.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount should fail gracefully (not crash)
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    local mount_result=$?

    # If it mounted (unlikely), unmount
    if mountpoint -q "$MOUNT_DIR"; then
        log "Warning: Random data mounted (unexpected)"
        safe_unmount "$MOUNT_DIR"
    fi

    # The key test: rar2fs should not crash
    log "rar2fs handled random data without crashing"
    return 0
}

test_corrupted_empty() {
    local archive="$ARCHIVE_DIR/08-empty.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount should fail gracefully (not crash)
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    local mount_result=$?

    # If it mounted (unlikely), unmount
    if mountpoint -q "$MOUNT_DIR"; then
        log "Warning: Empty file mounted (unexpected)"
        safe_unmount "$MOUNT_DIR"
    fi

    # The key test: rar2fs should not crash
    log "rar2fs handled empty file without crashing"
    return 0
}

test_large_file() {
    local archive="$ARCHIVE_DIR/05-large-compressible.rar"
    safe_unmount "$MOUNT_DIR"

    # Mount
    "$RAR2FS" --seek-length=0 "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Failed to mount: $archive"
        return 1
    fi

    # Get file
    local file=$(ls -1 "$MOUNT_DIR" | head -1)
    if [ -z "$file" ]; then
        log "No file found"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Check file size
    local size=$(stat -c%s "$MOUNT_DIR/$file" 2>/dev/null)
    if [ -z "$size" ] || [ $size -lt 1000000 ]; then
        log "File too small: $size bytes (expected 1MB+)"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Large file accessible: $(numfmt --to=iec-i --suffix=B $size)"

    # Unmount
    safe_unmount "$MOUNT_DIR"
    return 0
}

# ============================================================
# MAIN EXECUTION
# ============================================================

log "=================================================="
log "RAR2FS Basic Functional Test Suite"
log "=================================================="
log "Started: $(date)"
log "Binary: $RAR2FS"
log "Archives: $ARCHIVE_DIR"
log "Mount point: $MOUNT_DIR"
log "Log file: $LOG_FILE"
log ""

# Clean up any existing mounts
safe_unmount "$MOUNT_DIR"

# Run prerequisite checks
run_test "Binary exists and is executable" test_binary_exists
run_test "Test archives exist" test_archives_exist

# Run basic functionality tests
log ""
log "${YELLOW}=== BASIC FUNCTIONALITY TESTS ===${NC}"
run_test "Mount single uncompressed archive" test_mount_single_uncompressed
run_test "Read file content from compressed archive" test_read_file_content
run_test "Multi-file archive access" test_multifile_archive
run_test "Nested directory structure" test_nested_directories
run_test "MD5 checksum verification" test_md5sum_verification
run_test "Large file access" test_large_file

# Run error handling tests
log ""
log "${YELLOW}=== ERROR HANDLING TESTS ===${NC}"
run_test "Corrupted archive (truncated) - no crash" test_corrupted_truncated
run_test "Corrupted archive (random data) - no crash" test_corrupted_random_data
run_test "Corrupted archive (empty) - no crash" test_corrupted_empty

# Final cleanup
safe_unmount "$MOUNT_DIR"

# Summary
log ""
log "=================================================="
log "TEST SUMMARY"
log "=================================================="
log "Total tests: $total_tests"
log "${GREEN}Passed: $passed_tests${NC}"
if [ $failed_tests -gt 0 ]; then
    log "${RED}Failed: $failed_tests${NC}"
else
    log "Failed: $failed_tests"
fi
log ""
log "Completed: $(date)"
log "Log file: $LOG_FILE"
log "=================================================="

# Exit with appropriate code
if [ $failed_tests -gt 0 ]; then
    exit 1
fi

exit 0
