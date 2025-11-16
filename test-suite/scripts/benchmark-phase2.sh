#!/bin/bash
# Phase 2 Performance Benchmark Script
# Measures directory operations and sequential read performance

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR="$(dirname "$SCRIPT_DIR")"
MOUNT_DIR="$SUITE_DIR/mount/benchmark"
ARCHIVE_DIR="$SUITE_DIR/archives"
RESULTS_DIR="$SUITE_DIR/results"

# Use the built binary
RAR2FS="$SUITE_DIR/../src/rar2fs"

if [ ! -x "$RAR2FS" ]; then
    echo "ERROR: rar2fs binary not found at $RAR2FS"
    exit 1
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

# Timestamp for this run
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_FILE="$RESULTS_DIR/benchmark_${TIMESTAMP}.txt"

echo "=== rar2fs Phase 2 Performance Benchmark ===" | tee "$RESULT_FILE"
echo "Timestamp: $(date)" | tee -a "$RESULT_FILE"
echo "Binary: $RAR2FS" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

# Cleanup function
cleanup() {
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        fusermount -u "$MOUNT_DIR" 2>/dev/null || fusermount3 -u "$MOUNT_DIR" 2>/dev/null || true
        sleep 0.5
    fi
    rm -rf "$MOUNT_DIR"
}

trap cleanup EXIT

# Test archive selection
# Use 04-nested-dirs.rar for directory operations (has nested structure)
DIR_ARCHIVE="$ARCHIVE_DIR/04-nested-dirs.rar"
# Use 05-large-compressible.rar for read operations (1MB+ file)
READ_ARCHIVE="$ARCHIVE_DIR/05-large-compressible.rar"

if [ ! -f "$DIR_ARCHIVE" ]; then
    echo "ERROR: Directory test archive not found: $DIR_ARCHIVE"
    exit 1
fi

if [ ! -f "$READ_ARCHIVE" ]; then
    echo "ERROR: Read test archive not found: $READ_ARCHIVE"
    exit 1
fi

# Benchmark 1: Directory listing performance
echo "=== Benchmark 1: Directory Listing (ls -R) ===" | tee -a "$RESULT_FILE"
mkdir -p "$MOUNT_DIR"
"$RAR2FS" "$DIR_ARCHIVE" "$MOUNT_DIR"
sleep 0.5

# Warmup
ls -R "$MOUNT_DIR" > /dev/null 2>&1 || true

# Actual benchmark (3 runs for average)
TIMES=()
for i in {1..3}; do
    START=$(date +%s.%N)
    ls -R "$MOUNT_DIR" > /dev/null
    END=$(date +%s.%N)
    ELAPSED=$(awk "BEGIN {printf \"%.3f\", $END - $START}")
    TIMES+=("$ELAPSED")
    echo "  Run $i: ${ELAPSED}s" | tee -a "$RESULT_FILE"
done

# Calculate average
AVG=$(awk "BEGIN {printf \"%.3f\", (${TIMES[0]} + ${TIMES[1]} + ${TIMES[2]}) / 3}")
echo "  Average: ${AVG}s" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

fusermount -u "$MOUNT_DIR" 2>/dev/null || fusermount3 -u "$MOUNT_DIR" 2>/dev/null
sleep 0.5

# Benchmark 2: Directory listing with stats (ls -lR)
echo "=== Benchmark 2: Directory Listing with Stats (ls -lR) ===" | tee -a "$RESULT_FILE"
"$RAR2FS" "$DIR_ARCHIVE" "$MOUNT_DIR"
sleep 0.5

# Warmup
ls -lR "$MOUNT_DIR" > /dev/null 2>&1 || true

# Actual benchmark (3 runs)
TIMES=()
for i in {1..3}; do
    START=$(date +%s.%N)
    ls -lR "$MOUNT_DIR" > /dev/null
    END=$(date +%s.%N)
    ELAPSED=$(awk "BEGIN {printf \"%.3f\", $END - $START}")
    TIMES+=("$ELAPSED")
    echo "  Run $i: ${ELAPSED}s" | tee -a "$RESULT_FILE"
done

AVG=$(awk "BEGIN {printf \"%.3f\", (${TIMES[0]} + ${TIMES[1]} + ${TIMES[2]}) / 3}")
echo "  Average: ${AVG}s" | tee -a "$RESULT_FILE"
echo "" | tee -a "$RESULT_FILE"

fusermount -u "$MOUNT_DIR" 2>/dev/null || fusermount3 -u "$MOUNT_DIR" 2>/dev/null
sleep 0.5

# Benchmark 3: Sequential read performance
echo "=== Benchmark 3: Sequential Read (dd) ===" | tee -a "$RESULT_FILE"
"$RAR2FS" "$READ_ARCHIVE" "$MOUNT_DIR"
sleep 0.5

# Find the largest file in the archive
LARGE_FILE=$(find "$MOUNT_DIR" -type f -exec ls -l {} \; | sort -k5 -n -r | head -1 | awk '{print $NF}')

if [ -z "$LARGE_FILE" ]; then
    echo "  ERROR: No file found in archive" | tee -a "$RESULT_FILE"
else
    echo "  File: $LARGE_FILE" | tee -a "$RESULT_FILE"
    FILE_SIZE=$(stat -c%s "$LARGE_FILE")
    echo "  Size: $FILE_SIZE bytes" | tee -a "$RESULT_FILE"

    # Warmup
    dd if="$LARGE_FILE" of=/dev/null bs=1M 2>/dev/null || true

    # Actual benchmark (3 runs)
    TIMES=()
    for i in {1..3}; do
        START=$(date +%s.%N)
        dd if="$LARGE_FILE" of=/dev/null bs=1M 2>/dev/null
        END=$(date +%s.%N)
        ELAPSED=$(awk "BEGIN {printf \"%.3f\", $END - $START}")
        TIMES+=("$ELAPSED")
        THROUGHPUT=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE / 1048576 / $ELAPSED}")
        echo "  Run $i: ${ELAPSED}s (${THROUGHPUT} MB/s)" | tee -a "$RESULT_FILE"
    done

    AVG=$(awk "BEGIN {printf \"%.3f\", (${TIMES[0]} + ${TIMES[1]} + ${TIMES[2]}) / 3}")
    AVG_THROUGHPUT=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE / 1048576 / $AVG}")
    echo "  Average: ${AVG}s (${AVG_THROUGHPUT} MB/s)" | tee -a "$RESULT_FILE"
fi

echo "" | tee -a "$RESULT_FILE"

fusermount -u "$MOUNT_DIR" 2>/dev/null || fusermount3 -u "$MOUNT_DIR" 2>/dev/null
sleep 0.5

# Benchmark 4: Syscall count (strace)
echo "=== Benchmark 4: Syscall Analysis (strace) ===" | tee -a "$RESULT_FILE"
"$RAR2FS" "$DIR_ARCHIVE" "$MOUNT_DIR"
sleep 0.5

STRACE_OUT=$(mktemp)
strace -c ls -R "$MOUNT_DIR" 2>"$STRACE_OUT" > /dev/null || true

echo "  System call summary:" | tee -a "$RESULT_FILE"
grep -A 20 "% time" "$STRACE_OUT" | head -25 | tee -a "$RESULT_FILE" || true

rm -f "$STRACE_OUT"

fusermount -u "$MOUNT_DIR" 2>/dev/null || fusermount3 -u "$MOUNT_DIR" 2>/dev/null

echo "" | tee -a "$RESULT_FILE"
echo "=== Benchmark Complete ===" | tee -a "$RESULT_FILE"
echo "Results saved to: $RESULT_FILE" | tee -a "$RESULT_FILE"

# Print summary path
echo ""
echo "Results file: $RESULT_FILE"
