#!/bin/bash
#
# run-all-tests.sh - Run complete test suite
#
# This script runs all tests in sequence:
# 1. Create archives (if needed)
# 2. Run basic functional tests
# 3. Run AddressSanitizer tests
#

set -u

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}=================================================="
echo "RAR2FS Complete Test Suite"
echo -e "==================================================${NC}"
echo ""

# Step 1: Create archives if needed
if [ ! -d "$SCRIPT_DIR/../archives" ] || [ -z "$(ls -A "$SCRIPT_DIR/../archives"/*.rar 2>/dev/null)" ]; then
    echo -e "${YELLOW}Step 1: Creating test archives...${NC}"
    "$SCRIPT_DIR/create-archives.sh" || exit 1
else
    echo -e "${GREEN}Step 1: Test archives exist (skipping creation)${NC}"
fi

echo ""

# Step 2: Run basic tests
echo -e "${YELLOW}Step 2: Running basic functional tests...${NC}"
"$SCRIPT_DIR/run-basic-tests.sh" || exit 1

echo ""

# Step 3: Run ASan tests
echo -e "${YELLOW}Step 3: Running AddressSanitizer tests...${NC}"
"$SCRIPT_DIR/run-asan-tests.sh" || exit 1

echo ""
echo -e "${GREEN}=================================================="
echo "ALL TESTS COMPLETED SUCCESSFULLY!"
echo -e "==================================================${NC}"

exit 0
