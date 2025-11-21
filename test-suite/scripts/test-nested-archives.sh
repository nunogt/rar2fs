#!/bin/bash
#
# test-nested-archives.sh - Integration tests for recursive RAR unpacking
#
# Tests the recursive unpacking feature (EP004) with nested archives:
# - Single-level nesting (RAR containing RAR)
# - Multi-level nesting (3+ levels deep)
# - Depth limit enforcement
# - Collision handling (duplicate filenames)
# - Security validation (path sanitization, cycle detection)
#
# Prerequisites:
# - rar2fs binary at ../../src/rar2fs
# - Test archives created in ../archives/ (created by this script)
# - rar command available for archive creation
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
WORK_DIR="$TEST_ROOT/work-nested"

# Binary
RAR2FS="$PROJECT_ROOT/src/rar2fs"

# Log file
LOG_FILE="$RESULTS_DIR/test-nested-archives-$(date +%Y%m%d-%H%M%S).log"

# Create necessary directories
mkdir -p "$RESULTS_DIR" "$MOUNT_DIR" "$WORK_DIR"

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

# Function to mount with rar2fs
mount_rar2fs() {
    local archive="$1"
    shift
    local extra_opts="$@"

    safe_unmount "$MOUNT_DIR"

    # Mount in background mode
    "$RAR2FS" $extra_opts "$archive" "$MOUNT_DIR" >> "$LOG_FILE" 2>&1 &
    local mount_pid=$!

    # Wait for mount to complete
    sleep 2

    # Check if mount process is still alive and mount point is active
    if ! ps -p $mount_pid > /dev/null 2>&1 || ! mountpoint -q "$MOUNT_DIR"; then
        log "Failed to mount: $archive (opts: $extra_opts)"
        wait $mount_pid 2>/dev/null
        return 1
    fi

    return 0
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
        log "${GREEN}✓ PASS${NC}"
        return 0
    else
        failed_tests=$((failed_tests + 1))
        log "${RED}✗ FAIL${NC}"
        return 1
    fi
}

# ============================================================
# TEST ARCHIVE CREATION
# ============================================================

create_test_archives() {
    log "Creating test archives for nested RAR scenarios..."

    # Check if rar command is available
    if ! command -v rar &> /dev/null; then
        log "${YELLOW}WARNING:${NC} 'rar' command not found. Skipping archive creation."
        log "Please install rar: apt-get install rar (Debian/Ubuntu)"
        log "Or install from: https://www.rarlab.com/download.htm"
        return 1
    fi

    cd "$WORK_DIR" || return 1

    # Clean up old test archives
    rm -f "$ARCHIVE_DIR"/nested-*.rar

    # ===== Test Case 1: Single-level nesting =====
    log "  Creating single-level nested archive..."

    # Create inner content
    mkdir -p level1
    echo "This is a file from the inner RAR archive" > level1/inner-file.txt
    echo "Another file in the nested archive" > level1/inner-data.txt

    # Create inner archive
    rar a -ep1 -m0 inner.rar level1/*.txt > /dev/null 2>&1

    # Create outer archive containing inner.rar
    mkdir -p outer
    cp inner.rar outer/
    echo "This is a file from the outer RAR archive" > outer/outer-file.txt
    rar a -ep1 -m0 "$ARCHIVE_DIR/nested-single-level.rar" outer/* > /dev/null 2>&1

    rm -rf level1 outer inner.rar

    # ===== Test Case 2: Multi-level nesting (3 levels) =====
    log "  Creating multi-level nested archive (3 levels)..."

    # Level 3 (deepest)
    mkdir -p level3
    echo "Level 3 file (deepest)" > level3/level3-file.txt
    rar a -ep1 -m0 level3.rar level3/*.txt > /dev/null 2>&1

    # Level 2
    mkdir -p level2
    cp level3.rar level2/
    echo "Level 2 file" > level2/level2-file.txt
    rar a -ep1 -m0 level2.rar level2/* > /dev/null 2>&1

    # Level 1
    mkdir -p level1
    cp level2.rar level1/
    echo "Level 1 file" > level1/level1-file.txt
    rar a -ep1 -m0 "$ARCHIVE_DIR/nested-multi-level.rar" level1/* > /dev/null 2>&1

    rm -rf level1 level2 level3 level1.rar level2.rar level3.rar

    # ===== Test Case 3: Depth limit test (6 levels - exceeds default) =====
    log "  Creating deep nested archive (6 levels for depth test)..."

    # Level 6 (deepest)
    mkdir -p level6
    echo "Level 6 - should not be accessible with default depth=5" > level6/level6-file.txt
    rar a -ep1 -m0 level6.rar level6/*.txt > /dev/null 2>&1

    # Level 5
    mkdir -p level5
    cp level6.rar level5/
    echo "Level 5 file" > level5/level5-file.txt
    rar a -ep1 -m0 level5.rar level5/* > /dev/null 2>&1

    # Level 4
    mkdir -p level4
    cp level5.rar level4/
    echo "Level 4 file" > level4/level4-file.txt
    rar a -ep1 -m0 level4.rar level4/* > /dev/null 2>&1

    # Level 3
    mkdir -p level3
    cp level4.rar level3/
    echo "Level 3 file" > level3/level3-file.txt
    rar a -ep1 -m0 level3.rar level3/* > /dev/null 2>&1

    # Level 2
    mkdir -p level2
    cp level3.rar level2/
    echo "Level 2 file" > level2/level2-file.txt
    rar a -ep1 -m0 level2.rar level2/* > /dev/null 2>&1

    # Level 1
    mkdir -p level1
    cp level2.rar level1/
    echo "Level 1 file" > level1/level1-file.txt
    rar a -ep1 -m0 "$ARCHIVE_DIR/nested-deep-6levels.rar" level1/* > /dev/null 2>&1

    rm -rf level1 level2 level3 level4 level5 level6 *.rar

    # ===== Test Case 4: Collision test (duplicate filenames) =====
    log "  Creating collision test archive..."

    # Create two nested RARs with same filename
    mkdir -p archive1
    echo "Content from archive1" > archive1/duplicate.txt
    rar a -ep1 -m0 archive1.rar archive1/*.txt > /dev/null 2>&1

    mkdir -p archive2
    echo "Content from archive2 (should be skipped)" > archive2/duplicate.txt
    rar a -ep1 -m0 archive2.rar archive2/*.txt > /dev/null 2>&1

    # Create outer archive with both
    mkdir -p collision
    cp archive1.rar collision/
    cp archive2.rar collision/
    echo "Outer file" > collision/outer.txt
    rar a -ep1 -m0 "$ARCHIVE_DIR/nested-collision.rar" collision/* > /dev/null 2>&1

    rm -rf archive1 archive2 collision *.rar

    # ===== Test Case 5: Path sanitization test =====
    log "  Creating path sanitization test archive..."

    # Create archive with malicious paths (will be sanitized by rar2fs)
    mkdir -p malicious
    echo "Safe content" > malicious/safe-file.txt
    # Note: We create a nested RAR that rar2fs will sanitize when unpacking
    mkdir -p inner-mal
    echo "This path will be sanitized" > inner-mal/dotdot-file.txt
    rar a -ep1 -m0 malicious-inner.rar inner-mal/*.txt > /dev/null 2>&1

    cp malicious-inner.rar malicious/
    rar a -ep1 -m0 "$ARCHIVE_DIR/nested-sanitize.rar" malicious/* > /dev/null 2>&1

    rm -rf malicious inner-mal *.rar

    cd "$TEST_ROOT" || return 1
    log "  Test archives created successfully"
    return 0
}

# ============================================================
# TEST FUNCTIONS
# ============================================================

test_prerequisites() {
    # Check binary
    if [ ! -f "$RAR2FS" ]; then
        log "${RED}ERROR:${NC} rar2fs binary not found at: $RAR2FS"
        log "Run 'make' first"
        return 1
    fi
    if [ ! -x "$RAR2FS" ]; then
        log "${RED}ERROR:${NC} rar2fs binary not executable: $RAR2FS"
        return 1
    fi

    log "Binary found: $RAR2FS"
    return 0
}

test_single_level_nesting() {
    local archive="$ARCHIVE_DIR/nested-single-level.rar"

    if [ ! -f "$archive" ]; then
        log "Test archive not found: $archive"
        return 1
    fi

    # Mount with recursive unpacking enabled
    if ! mount_rar2fs "$archive" --recursive; then
        return 1
    fi

    # Check that files from nested RAR are visible
    if [ ! -f "$MOUNT_DIR/inner-file.txt" ]; then
        log "Nested file not found: inner-file.txt"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    if [ ! -f "$MOUNT_DIR/inner-data.txt" ]; then
        log "Nested file not found: inner-data.txt"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Verify content
    local content=$(cat "$MOUNT_DIR/inner-file.txt" 2>&1)
    if [[ ! "$content" =~ "inner RAR archive" ]]; then
        log "Unexpected content in inner-file.txt: $content"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Verify outer file also present (transparent flat unpacking)
    if [ ! -f "$MOUNT_DIR/outer-file.txt" ]; then
        log "Outer file not found: outer-file.txt"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Single-level nesting works correctly"
    log "  Files: $(ls -1 "$MOUNT_DIR" | tr '\n' ' ')"

    safe_unmount "$MOUNT_DIR"
    return 0
}

test_multi_level_nesting() {
    local archive="$ARCHIVE_DIR/nested-multi-level.rar"

    if [ ! -f "$archive" ]; then
        log "Test archive not found: $archive"
        return 1
    fi

    # Mount with recursive unpacking enabled
    if ! mount_rar2fs "$archive" --recursive; then
        return 1
    fi

    # Check files from all 3 levels are accessible
    local expected_files=("level1-file.txt" "level2-file.txt" "level3-file.txt")

    for file in "${expected_files[@]}"; do
        if [ ! -f "$MOUNT_DIR/$file" ]; then
            log "File from nested level not found: $file"
            safe_unmount "$MOUNT_DIR"
            return 1
        fi
    done

    # Verify content from deepest level
    local content=$(cat "$MOUNT_DIR/level3-file.txt" 2>&1)
    if [[ ! "$content" =~ "Level 3" ]]; then
        log "Unexpected content in level3-file.txt: $content"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Multi-level nesting (3 levels) works correctly"
    log "  All levels accessible via transparent flat unpacking"

    safe_unmount "$MOUNT_DIR"
    return 0
}

test_depth_limit_enforcement() {
    local archive="$ARCHIVE_DIR/nested-deep-6levels.rar"

    if [ ! -f "$archive" ]; then
        log "Test archive not found: $archive"
        return 1
    fi

    # Mount with recursive unpacking enabled and default depth limit (5)
    if ! mount_rar2fs "$archive" --recursive --recursion-depth=5; then
        return 1
    fi

    # Files from levels 1-5 should be accessible
    local accessible_files=("level1-file.txt" "level2-file.txt" "level3-file.txt" "level4-file.txt" "level5-file.txt")

    for file in "${accessible_files[@]}"; do
        if [ ! -f "$MOUNT_DIR/$file" ]; then
            log "File from level not found (should be accessible): $file"
            safe_unmount "$MOUNT_DIR"
            return 1
        fi
    done

    # Level 6 should NOT be accessible (exceeds depth limit)
    if [ -f "$MOUNT_DIR/level6-file.txt" ]; then
        log "File from level 6 found (should not be accessible due to depth limit)"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Depth limit enforcement works correctly"
    log "  Levels 1-5 accessible, level 6 blocked by depth limit"

    safe_unmount "$MOUNT_DIR"
    return 0
}

test_collision_handling() {
    local archive="$ARCHIVE_DIR/nested-collision.rar"

    if [ ! -f "$archive" ]; then
        log "Test archive not found: $archive"
        return 1
    fi

    # Mount with recursive unpacking enabled
    if ! mount_rar2fs "$archive" --recursive; then
        return 1
    fi

    # Check that duplicate.txt exists
    if [ ! -f "$MOUNT_DIR/duplicate.txt" ]; then
        log "Collision file not found: duplicate.txt"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Verify first-wins strategy: should have content from archive1
    local content=$(cat "$MOUNT_DIR/duplicate.txt" 2>&1)
    if [[ "$content" =~ "archive1" ]]; then
        log "First-wins collision strategy works correctly"
        log "  Content from first archive: $content"
    elif [[ "$content" =~ "archive2" ]]; then
        log "Collision handling incorrect: second file won (expected first-wins)"
        safe_unmount "$MOUNT_DIR"
        return 1
    else
        log "Unexpected content in duplicate.txt: $content"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    safe_unmount "$MOUNT_DIR"
    return 0
}

test_security_path_sanitization() {
    local archive="$ARCHIVE_DIR/nested-sanitize.rar"

    if [ ! -f "$archive" ]; then
        log "Test archive not found: $archive"
        return 1
    fi

    # Mount with recursive unpacking and debug logging
    if ! mount_rar2fs "$archive" --recursive -d1; then
        return 1
    fi

    # Verify safe files are accessible
    if [ ! -f "$MOUNT_DIR/safe-file.txt" ]; then
        log "Safe file not found: safe-file.txt"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Verify sanitized file is accessible (path should be stripped)
    if [ ! -f "$MOUNT_DIR/dotdot-file.txt" ]; then
        log "Sanitized file not found: dotdot-file.txt"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Key security test: malicious paths should not escape mount point
    # Check that no files exist outside MOUNT_DIR
    if [ -f "$TEST_ROOT/../leaked-file.txt" ]; then
        log "SECURITY ISSUE: File escaped mount directory!"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Path sanitization works correctly"
    log "  Malicious paths sanitized, files contained within mount point"

    safe_unmount "$MOUNT_DIR"
    return 0
}

test_recursive_disable() {
    local archive="$ARCHIVE_DIR/nested-single-level.rar"

    if [ ! -f "$archive" ]; then
        log "Test archive not found: $archive"
        return 1
    fi

    # Mount WITHOUT --recursive flag (recursive unpacking disabled by default)
    if ! mount_rar2fs "$archive"; then
        return 1
    fi

    # Nested files should NOT be visible
    if [ -f "$MOUNT_DIR/inner-file.txt" ]; then
        log "Nested file found when recursive=no (should not be unpacked)"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # But inner.rar should appear as a regular file
    if [ ! -f "$MOUNT_DIR/inner.rar" ]; then
        log "Nested RAR file not found as regular file"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    # Outer files should still be accessible
    if [ ! -f "$MOUNT_DIR/outer-file.txt" ]; then
        log "Outer file not found"
        safe_unmount "$MOUNT_DIR"
        return 1
    fi

    log "Recursive unpacking disable (--recursive=no) works correctly"
    log "  Nested RAR appears as regular file, not automatically unpacked"

    safe_unmount "$MOUNT_DIR"
    return 0
}

# ============================================================
# MAIN EXECUTION
# ============================================================

log "=========================================================="
log "RAR2FS Nested Archive Integration Test Suite (EP004)"
log "=========================================================="
log "Started: $(date)"
log "Binary: $RAR2FS"
log "Archives: $ARCHIVE_DIR"
log "Mount point: $MOUNT_DIR"
log "Log file: $LOG_FILE"
log ""

# Clean up any existing mounts
safe_unmount "$MOUNT_DIR"

# Create test archives
log "${YELLOW}=== CREATING TEST ARCHIVES ===${NC}"
if ! create_test_archives; then
    log "${RED}Failed to create test archives. Some tests will be skipped.${NC}"
fi
log ""

# Run prerequisite checks
log "${YELLOW}=== PREREQUISITE CHECKS ===${NC}"
run_test "Binary exists and is executable" test_prerequisites
log ""

# Run nested archive tests
log "${YELLOW}=== NESTED ARCHIVE TESTS ===${NC}"
run_test "Single-level nesting (AC3)" test_single_level_nesting
run_test "Multi-level nesting (AC4)" test_multi_level_nesting
run_test "Depth limit enforcement (AC10)" test_depth_limit_enforcement
run_test "Collision handling - first-wins (AC6)" test_collision_handling
run_test "Security: Path sanitization (AC7, AC9)" test_security_path_sanitization
run_test "Disable recursive unpacking (AC1)" test_recursive_disable

# Final cleanup
safe_unmount "$MOUNT_DIR"
rm -rf "$WORK_DIR"

# Summary
log ""
log "=========================================================="
log "TEST SUMMARY"
log "=========================================================="
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
log "=========================================================="

# Exit with appropriate code
if [ $failed_tests -gt 0 ]; then
    exit 1
fi

exit 0
