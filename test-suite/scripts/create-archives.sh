#!/bin/bash
#
# create-archives.sh - Generate all test RAR archives for rar2fs test suite
#
# This script creates a comprehensive set of RAR test files covering:
# - Basic functionality (various compression levels, multi-file, nested dirs)
# - Error handling (corrupted, truncated, invalid files)
# - Advanced features (solid archives, different formats)
#
# Prerequisites:
# - rar and unrar commands must be in PATH
# - Source files in ../source-files/
#
# Output: All archives created in ../archives/
#

set -e  # Exit on error
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
SOURCE_DIR="$TEST_ROOT/source-files"
ARCHIVE_DIR="$TEST_ROOT/archives"
RESULTS_DIR="$TEST_ROOT/results"

# Create results directory if needed
mkdir -p "$RESULTS_DIR"

# Log file
LOG_FILE="$RESULTS_DIR/create-archives-$(date +%Y%m%d-%H%M%S).log"

# Function to print and log
log() {
    echo -e "$@" | tee -a "$LOG_FILE"
}

# Function to create and verify archive
create_archive() {
    local name="$1"
    local description="$2"
    shift 2
    local rar_args=("$@")

    log "${BLUE}Creating:${NC} $name - $description"

    # Create archive (rar a [options] archive_path files...)
    if rar a "$ARCHIVE_DIR/$name" "${rar_args[@]}" > "$RESULTS_DIR/rar-$name.log" 2>&1; then
        # Verify archive
        if unrar t "$ARCHIVE_DIR/$name" > "$RESULTS_DIR/unrar-$name.log" 2>&1; then
            local size=$(ls -lh "$ARCHIVE_DIR/$name" | awk '{print $5}')
            log "${GREEN}SUCCESS:${NC} $name ($size)"
            return 0
        else
            log "${RED}VERIFY FAILED:${NC} $name (unrar test failed)"
            return 1
        fi
    else
        log "${RED}CREATE FAILED:${NC} $name (rar command failed)"
        return 1
    fi
}

# Function to create corrupted archive
create_corrupted() {
    local name="$1"
    local description="$2"
    local method="$3"

    log "${BLUE}Creating:${NC} $name - $description"

    case "$method" in
        truncated)
            # Create valid archive first, then truncate it
            rar a -m0 "$ARCHIVE_DIR/temp-valid.rar" "$SOURCE_DIR/small-text.txt" > /dev/null 2>&1
            # Truncate at 50% of file size
            local size=$(stat -c%s "$ARCHIVE_DIR/temp-valid.rar")
            local half=$((size / 2))
            dd if="$ARCHIVE_DIR/temp-valid.rar" of="$ARCHIVE_DIR/$name" bs=1 count=$half 2>/dev/null
            rm -f "$ARCHIVE_DIR/temp-valid.rar"
            log "${GREEN}SUCCESS:${NC} $name (truncated at $half bytes)"
            ;;
        random)
            # Create file with random data
            dd if=/dev/urandom of="$ARCHIVE_DIR/$name" bs=1024 count=10 2>/dev/null
            log "${GREEN}SUCCESS:${NC} $name (10KB random data)"
            ;;
        empty)
            # Create empty file
            touch "$ARCHIVE_DIR/$name"
            log "${GREEN}SUCCESS:${NC} $name (0 bytes)"
            ;;
        nosignature)
            # Create file without RAR signature
            echo "This is not a RAR archive" > "$ARCHIVE_DIR/$name"
            log "${GREEN}SUCCESS:${NC} $name (invalid signature)"
            ;;
        *)
            log "${RED}UNKNOWN METHOD:${NC} $method"
            return 1
            ;;
    esac

    return 0
}

# Main execution
log "=================================================="
log "RAR2FS Test Archive Creation Script"
log "=================================================="
log "Started: $(date)"
log "Source directory: $SOURCE_DIR"
log "Archive directory: $ARCHIVE_DIR"
log ""

# Check prerequisites
log "${BLUE}Checking prerequisites...${NC}"
if ! command -v rar &> /dev/null; then
    log "${RED}ERROR:${NC} 'rar' command not found in PATH"
    exit 1
fi
if ! command -v unrar &> /dev/null; then
    log "${RED}ERROR:${NC} 'unrar' command not found in PATH"
    exit 1
fi
log "${GREEN}OK:${NC} rar and unrar commands found"
log ""

# Clean old archives
if [ -d "$ARCHIVE_DIR" ]; then
    log "${YELLOW}Cleaning old archives...${NC}"
    rm -f "$ARCHIVE_DIR"/*.rar
fi
mkdir -p "$ARCHIVE_DIR"
log ""

# Track success/failure
total=0
success=0
failed=0

# ============================================================
# BASIC FUNCTIONALITY ARCHIVES (5)
# ============================================================
log "${YELLOW}=== BASIC FUNCTIONALITY ARCHIVES ===${NC}"
log ""

# 1. Single file, uncompressed (store mode)
total=$((total + 1))
log "${BLUE}Creating:${NC} 01-single-uncompressed.rar - Single file, store mode (-m0)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/01-single-uncompressed.rar" -m0 -ep small-text.txt > "$RESULTS_DIR/rar-01-single-uncompressed.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/01-single-uncompressed.rar" > "$RESULTS_DIR/unrar-01-single-uncompressed.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/01-single-uncompressed.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 01-single-uncompressed.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 01-single-uncompressed.rar"
    failed=$((failed + 1))
fi

# 2. Single file, compressed
total=$((total + 1))
log "${BLUE}Creating:${NC} 02-single-compressed.rar - Single file, normal compression (-m3)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/02-single-compressed.rar" -m3 -ep medium-text.txt > "$RESULTS_DIR/rar-02-single-compressed.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/02-single-compressed.rar" > "$RESULTS_DIR/unrar-02-single-compressed.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/02-single-compressed.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 02-single-compressed.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 02-single-compressed.rar"
    failed=$((failed + 1))
fi

# 3. Multi-file archive
total=$((total + 1))
log "${BLUE}Creating:${NC} 03-multifile.rar - Multiple files (3 files)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/03-multifile.rar" -m3 -ep multifile-1.txt multifile-2.txt multifile-3.txt > "$RESULTS_DIR/rar-03-multifile.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/03-multifile.rar" > "$RESULTS_DIR/unrar-03-multifile.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/03-multifile.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 03-multifile.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 03-multifile.rar"
    failed=$((failed + 1))
fi

# 4. Nested directories
total=$((total + 1))
log "${BLUE}Creating:${NC} 04-nested-dirs.rar - Nested directories (3 levels deep)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/04-nested-dirs.rar" -m3 -r "nested/" > "$RESULTS_DIR/rar-04-nested-dirs.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/04-nested-dirs.rar" > "$RESULTS_DIR/unrar-04-nested-dirs.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/04-nested-dirs.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 04-nested-dirs.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 04-nested-dirs.rar"
    failed=$((failed + 1))
fi

# 5. Large compressible file
total=$((total + 1))
log "${BLUE}Creating:${NC} 05-large-compressible.rar - Large highly compressible file (1MB+ text)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/05-large-compressible.rar" -m5 -ep large-compressible.txt > "$RESULTS_DIR/rar-05-large-compressible.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/05-large-compressible.rar" > "$RESULTS_DIR/unrar-05-large-compressible.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/05-large-compressible.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 05-large-compressible.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 05-large-compressible.rar"
    failed=$((failed + 1))
fi

log ""

# ============================================================
# ERROR HANDLING ARCHIVES (5)
# ============================================================
log "${YELLOW}=== ERROR HANDLING ARCHIVES ===${NC}"
log ""

# 6. Truncated archive
total=$((total + 1))
if create_corrupted "06-truncated.rar" \
    "Truncated RAR file (cut mid-stream)" \
    "truncated"; then
    success=$((success + 1))
else
    failed=$((failed + 1))
fi

# 7. Random data (not a RAR)
total=$((total + 1))
if create_corrupted "07-random-data.rar" \
    "Random data (not a valid RAR)" \
    "random"; then
    success=$((success + 1))
else
    failed=$((failed + 1))
fi

# 8. Empty file
total=$((total + 1))
if create_corrupted "08-empty.rar" \
    "Empty file (0 bytes)" \
    "empty"; then
    success=$((success + 1))
else
    failed=$((failed + 1))
fi

# 9. Invalid signature
total=$((total + 1))
if create_corrupted "09-invalid-signature.rar" \
    "Invalid RAR signature" \
    "nosignature"; then
    success=$((success + 1))
else
    failed=$((failed + 1))
fi

# 10. Very small file (less than header size)
total=$((total + 1))
if create_corrupted "10-too-small.rar" \
    "File smaller than RAR header" \
    "empty"; then
    # Overwrite with just a few bytes
    echo "Rar!" > "$ARCHIVE_DIR/10-too-small.rar"
    log "${GREEN}SUCCESS:${NC} 10-too-small.rar (5 bytes)"
    success=$((success + 1))
else
    failed=$((failed + 1))
fi

log ""

# ============================================================
# ADVANCED FEATURES ARCHIVES (3)
# ============================================================
log "${YELLOW}=== ADVANCED FEATURES ARCHIVES ===${NC}"
log ""

# 11. Solid archive
total=$((total + 1))
log "${BLUE}Creating:${NC} 11-solid.rar - Solid archive (-s)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/11-solid.rar" -s -m3 -ep multifile-1.txt multifile-2.txt multifile-3.txt > "$RESULTS_DIR/rar-11-solid.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/11-solid.rar" > "$RESULTS_DIR/unrar-11-solid.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/11-solid.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 11-solid.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 11-solid.rar"
    failed=$((failed + 1))
fi

# 12. Maximum compression
total=$((total + 1))
log "${BLUE}Creating:${NC} 12-max-compression.rar - Maximum compression (-m5)"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/12-max-compression.rar" -m5 -ep medium-text.txt > "$RESULTS_DIR/rar-12-max-compression.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/12-max-compression.rar" > "$RESULTS_DIR/unrar-12-max-compression.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/12-max-compression.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 12-max-compression.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 12-max-compression.rar"
    failed=$((failed + 1))
fi

# 13. Binary data
total=$((total + 1))
log "${BLUE}Creating:${NC} 13-binary-data.rar - Binary file data"
(cd "$SOURCE_DIR" && rar a "$ARCHIVE_DIR/13-binary-data.rar" -m3 -ep binary-data.bin > "$RESULTS_DIR/rar-13-binary-data.rar.log" 2>&1)
if [ $? -eq 0 ] && unrar t "$ARCHIVE_DIR/13-binary-data.rar" > "$RESULTS_DIR/unrar-13-binary-data.rar.log" 2>&1; then
    size=$(ls -lh "$ARCHIVE_DIR/13-binary-data.rar" | awk '{print $5}')
    log "${GREEN}SUCCESS:${NC} 13-binary-data.rar ($size)"
    success=$((success + 1))
else
    log "${RED}CREATE FAILED:${NC} 13-binary-data.rar"
    failed=$((failed + 1))
fi

log ""

# ============================================================
# SUMMARY
# ============================================================
log "=================================================="
log "ARCHIVE CREATION SUMMARY"
log "=================================================="
log "Total archives: $total"
log "${GREEN}Successful: $success${NC}"
if [ $failed -gt 0 ]; then
    log "${RED}Failed: $failed${NC}"
else
    log "Failed: $failed"
fi
log ""
log "Completed: $(date)"
log "Log file: $LOG_FILE"
log "=================================================="

# List all created archives
log ""
log "${BLUE}Created archives:${NC}"
ls -lh "$ARCHIVE_DIR" | tee -a "$LOG_FILE"

# Exit with error if any failed
if [ $failed -gt 0 ]; then
    exit 1
fi

exit 0
