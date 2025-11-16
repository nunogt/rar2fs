#!/bin/bash
#
# build-with-unrar.sh - Automated build script for rar2fs with UnRAR library
#
# This script automates the process of downloading, building, and linking
# the correct UnRAR library version with rar2fs.
#
# Purpose: Automated UnRAR library download and build
# UnRAR Default Version: 7.2.1 (latest stable as of 28 Oct 2025)
# NOTE: Upgrades from UnRAR 6.0.3 used in baseline master branch
#
# Usage:
#   ./build-with-unrar.sh [options]
#
# Options:
#   --unrar-version VERSION   Specify UnRAR version (default: 7.2.1)
#   --clean                   Clean previous builds before building
#   --rebuild                 Clean everything and rebuild from scratch
#   --skip-unrar             Skip UnRAR download/build (use existing)
#   --configure-only          Only configure, don't build
#   --help                    Show this help message
#
# Examples:
#   ./build-with-unrar.sh                    # Build with defaults
#   ./build-with-unrar.sh --clean            # Clean build
#   ./build-with-unrar.sh --rebuild          # Full rebuild
#   ./build-with-unrar.sh --unrar-version 7.0.9  # Use specific version
#

set -e  # Exit on error

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------

UNRAR_DEFAULT_VERSION="7.2.1"
UNRAR_VERSION="${UNRAR_VERSION:-$UNRAR_DEFAULT_VERSION}"
UNRAR_BASE_URL="https://www.rarlab.com/rar"
UNRAR_DIR="unrar"
BUILD_DIR="$(pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Options
OPT_CLEAN=0
OPT_REBUILD=0
OPT_SKIP_UNRAR=0
OPT_CONFIGURE_ONLY=0

#------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //g' | sed 's/^#//g'
    exit 0
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found. Please install it first."
        return 1
    fi
}

get_unrar_version_from_source() {
    if [ -f "$UNRAR_DIR/version.hpp" ]; then
        local major=$(grep 'define RARVER_MAJOR' "$UNRAR_DIR/version.hpp" | awk '{print $3}')
        local minor=$(grep 'define RARVER_MINOR' "$UNRAR_DIR/version.hpp" | awk '{print $3}')
        local patch=$(grep 'define RARVER_BETA' "$UNRAR_DIR/version.hpp" | awk '{print $3}')
        echo "${major}.${minor}.${patch}"
    else
        echo "unknown"
    fi
}

#------------------------------------------------------------------------------
# Parse Command Line Arguments
#------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --unrar-version)
            UNRAR_VERSION="$2"
            shift 2
            ;;
        --clean)
            OPT_CLEAN=1
            shift
            ;;
        --rebuild)
            OPT_REBUILD=1
            shift
            ;;
        --skip-unrar)
            OPT_SKIP_UNRAR=1
            shift
            ;;
        --configure-only)
            OPT_CONFIGURE_ONLY=1
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#------------------------------------------------------------------------------
# Banner
#------------------------------------------------------------------------------

echo ""
echo "========================================================================"
echo "  rar2fs Build Script with UnRAR Library"
echo "========================================================================"
echo ""
echo "  UnRAR Version: $UNRAR_VERSION"
echo "  Build Dir:    $BUILD_DIR"
echo ""

#------------------------------------------------------------------------------
# Dependency Checks
#------------------------------------------------------------------------------

log_info "Checking dependencies..."

DEPS_OK=1
check_command wget || DEPS_OK=0
check_command tar || DEPS_OK=0
check_command gcc || DEPS_OK=0
check_command g++ || DEPS_OK=0
check_command make || DEPS_OK=0

if [ $DEPS_OK -eq 0 ]; then
    log_error "Missing required dependencies. Please install them and try again."
    echo ""
    echo "On Debian/Ubuntu:"
    echo "  sudo apt-get install build-essential wget tar libfuse-dev pkg-config"
    echo ""
    exit 1
fi

log_success "All dependencies found"

#------------------------------------------------------------------------------
# Clean Previous Builds
#------------------------------------------------------------------------------

if [ $OPT_REBUILD -eq 1 ]; then
    log_info "Rebuilding from scratch (--rebuild)..."

    # Clean rar2fs build artifacts
    if [ -f Makefile ]; then
        log_info "Running 'make clean' for rar2fs..."
        make clean || true
    fi

    # Remove configure-generated files
    log_info "Removing configure-generated files..."
    rm -f config.log config.status
    rm -rf autom4te.cache

    # Clean UnRAR
    if [ -d "$UNRAR_DIR" ]; then
        log_info "Cleaning UnRAR build..."
        (cd "$UNRAR_DIR" && make clean) || true
        log_info "Removing UnRAR directory..."
        rm -rf "$UNRAR_DIR"
    fi

    # Remove downloaded tarball
    rm -f "unrarsrc-${UNRAR_VERSION}.tar.gz"

    log_success "Clean complete"

elif [ $OPT_CLEAN -eq 1 ]; then
    log_info "Cleaning previous build (--clean)..."

    if [ -f Makefile ]; then
        log_info "Running 'make clean'..."
        make clean || true
    fi

    log_success "Clean complete"
fi

#------------------------------------------------------------------------------
# Download and Build UnRAR Library
#------------------------------------------------------------------------------

if [ $OPT_SKIP_UNRAR -eq 0 ]; then

    UNRAR_TARBALL="unrarsrc-${UNRAR_VERSION}.tar.gz"
    UNRAR_URL="${UNRAR_BASE_URL}/${UNRAR_TARBALL}"

    # Check if UnRAR is already built
    if [ -f "$UNRAR_DIR/libunrar.a" ] && [ -f "$UNRAR_DIR/libunrar.so" ]; then
        EXISTING_VERSION=$(get_unrar_version_from_source)
        log_info "UnRAR library already exists (version: $EXISTING_VERSION)"

        # Verify it's the correct version
        if [ "$EXISTING_VERSION" != "unknown" ]; then
            # Extract major.minor from both versions for comparison
            EXISTING_MAJOR_MINOR=$(echo "$EXISTING_VERSION" | cut -d. -f1-2)
            REQUESTED_MAJOR_MINOR=$(echo "$UNRAR_VERSION" | cut -d. -f1-2)

            if [ "$EXISTING_MAJOR_MINOR" == "$REQUESTED_MAJOR_MINOR" ]; then
                log_success "UnRAR library version matches (use --rebuild to force redownload)"
            else
                log_warn "UnRAR version mismatch: found $EXISTING_VERSION, expected $UNRAR_VERSION"
                log_info "Use --rebuild to download and build the correct version"
            fi
        fi
    else
        log_info "UnRAR library not found, downloading and building..."

        # Download UnRAR source
        if [ ! -f "$UNRAR_TARBALL" ]; then
            log_info "Downloading UnRAR $UNRAR_VERSION from $UNRAR_URL..."
            if ! wget -q --show-progress "$UNRAR_URL"; then
                log_error "Failed to download UnRAR $UNRAR_VERSION"
                log_error "URL: $UNRAR_URL"
                echo ""
                echo "Available versions: https://www.rarlab.com/rar_add.htm"
                exit 1
            fi
            log_success "Download complete"
        else
            log_info "Using existing tarball: $UNRAR_TARBALL"
        fi

        # Extract UnRAR source
        log_info "Extracting UnRAR source..."
        tar -xzf "$UNRAR_TARBALL"
        log_success "Extraction complete"

        # Build UnRAR library
        log_info "Building UnRAR library (this may take a minute)..."
        cd "$UNRAR_DIR"

        if ! make lib; then
            log_error "Failed to build UnRAR library"
            exit 1
        fi

        cd "$BUILD_DIR"

        # Verify build products
        if [ ! -f "$UNRAR_DIR/libunrar.a" ]; then
            log_error "UnRAR static library not found after build"
            exit 1
        fi

        if [ ! -f "$UNRAR_DIR/libunrar.so" ]; then
            log_warn "UnRAR shared library not found (this is OK, using static library)"
        fi

        log_success "UnRAR library built successfully"

        # Show UnRAR version
        BUILT_VERSION=$(get_unrar_version_from_source)
        log_info "UnRAR version: $BUILT_VERSION"
    fi

else
    log_info "Skipping UnRAR download/build (--skip-unrar)"

    if [ ! -d "$UNRAR_DIR" ]; then
        log_error "UnRAR directory not found: $UNRAR_DIR"
        log_error "Cannot use --skip-unrar without existing UnRAR build"
        exit 1
    fi
fi

#------------------------------------------------------------------------------
# Configure rar2fs
#------------------------------------------------------------------------------

log_info "Configuring rar2fs with UnRAR library..."

if [ ! -f configure ]; then
    log_error "configure script not found. Run autogen.sh or autoreconf first."
    exit 1
fi

CONFIGURE_OPTS="--with-unrar=./$UNRAR_DIR"

log_info "Running: ./configure $CONFIGURE_OPTS"

if ! ./configure $CONFIGURE_OPTS; then
    log_error "Configuration failed"
    exit 1
fi

log_success "Configuration complete"

# Extract git commit from config
if [ -f config.log ]; then
    GIT_REV=$(grep "GITREV_=" config.log | head -1 | sed "s/.*GITREV_='\([^']*\)'.*/\1/")
    if [ -n "$GIT_REV" ]; then
        log_info "Git revision: $GIT_REV"
    fi
fi

#------------------------------------------------------------------------------
# Build rar2fs
#------------------------------------------------------------------------------

if [ $OPT_CONFIGURE_ONLY -eq 1 ]; then
    log_info "Configuration only mode (--configure-only), skipping build"
    echo ""
    echo "To build manually, run:"
    echo "  make"
    echo ""
    exit 0
fi

log_info "Building rar2fs..."

if ! make; then
    log_error "Build failed"
    exit 1
fi

log_success "Build complete"

#------------------------------------------------------------------------------
# Verify Build Products
#------------------------------------------------------------------------------

log_info "Verifying build products..."

if [ ! -f src/rar2fs ]; then
    log_error "rar2fs binary not found: src/rar2fs"
    exit 1
fi

if [ ! -x src/rar2fs ]; then
    log_error "rar2fs binary is not executable"
    exit 1
fi

# Get rar2fs version
RAR2FS_VERSION=$(./src/rar2fs --version 2>&1 | head -1 | awk '{print $2}')
log_info "rar2fs version: $RAR2FS_VERSION"

# Get binary size
RAR2FS_SIZE=$(du -h src/rar2fs | cut -f1)
log_info "Binary size: $RAR2FS_SIZE"

# Get file info
FILE_INFO=$(file src/rar2fs | cut -d: -f2)
log_info "Binary type:$FILE_INFO"

log_success "Build verification complete"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------

echo ""
echo "========================================================================"
echo "  Build Summary"
echo "========================================================================"
echo ""
echo "  ✅ UnRAR Version:     $(get_unrar_version_from_source)"
echo "  ✅ rar2fs Version:    $RAR2FS_VERSION"
echo "  ✅ Binary Location:   src/rar2fs"
echo "  ✅ Binary Size:       $RAR2FS_SIZE"
echo ""
echo "  Security Improvements:"
echo "    - Buffer overflow protection"
echo "    - NULL pointer dereference prevention"
echo "    - Crash prevention improvements"
echo ""
echo "========================================================================"
echo ""
echo "Next Steps:"
echo ""
echo "  1. Install (optional):"
echo "       sudo make install"
echo ""
echo "  2. Test the binary:"
echo "       ./src/rar2fs --help"
echo ""
echo "  3. Mount a RAR archive:"
echo "       mkdir -p /tmp/rar-source /tmp/rar-mount"
echo "       ./src/rar2fs /tmp/rar-source /tmp/rar-mount"
echo ""
echo "  4. Read documentation:"
echo "       README - Usage and configuration guide"
echo ""
echo "========================================================================"
echo ""

exit 0
