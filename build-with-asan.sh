#!/bin/bash
#
# Build rar2fs with AddressSanitizer for memory error detection
# Usage: ./build-with-asan.sh [--clean]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}AddressSanitizer Build Script${NC}"
echo -e "${GREEN}================================${NC}"
echo ""

# Clean if requested
if [ "$1" == "--clean" ]; then
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    make clean 2>/dev/null || true
    rm -rf config.cache config.log config.status autom4te.cache
fi

# Check for UnRAR library
if [ ! -f "unrar/libunrar.a" ]; then
    echo -e "${YELLOW}UnRAR library not found. Building...${NC}"
    if [ ! -d "unrar" ]; then
        echo -e "${RED}Error: unrar/ directory not found.${NC}"
        echo "Run ./build-with-unrar.sh first to download and build UnRAR."
        exit 1
    fi
    cd unrar
    make clean lib
    cd ..
fi

echo -e "${GREEN}Configuring with AddressSanitizer...${NC}"
./configure --with-unrar=./unrar \
    CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1" \
    CXXFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O1" \
    LDFLAGS="-fsanitize=address"

echo ""
echo -e "${GREEN}Building rar2fs with ASan...${NC}"
make -j$(nproc)

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Build Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Run with AddressSanitizer:${NC}"
echo ""
echo "  ASAN_OPTIONS=detect_leaks=1:halt_on_error=0 \\"
echo "    ./src/rar2fs /source /mount"
echo ""
echo -e "${YELLOW}Recommended ASAN_OPTIONS for testing:${NC}"
echo "  - detect_leaks=1       # Detect memory leaks"
echo "  - halt_on_error=0      # Continue after first error"
echo "  - log_path=asan.log    # Write errors to file"
echo "  - verbosity=1          # Detailed error messages"
echo ""
echo -e "${YELLOW}Example full command:${NC}"
echo "  ASAN_OPTIONS='detect_leaks=1:halt_on_error=0:log_path=./asan.log' \\"
echo "    ./src/rar2fs -f /tmp/test-source /tmp/test-mount"
echo ""
echo -e "${GREEN}Version info:${NC}"
./src/rar2fs --version
echo ""
