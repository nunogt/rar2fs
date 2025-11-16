# rar2fs Test Suite

Comprehensive, persistent test suite for rar2fs filesystem validation.

## Overview

This test suite provides automated testing for rar2fs, covering:
- **Basic functionality**: Mounting, reading, directory traversal
- **Error handling**: Corrupted archives, invalid files, edge cases
- **Memory safety**: AddressSanitizer validation
- **Regression testing**: Validates recent fixes (OPT_INT macro, buffer overflows)

All test data is persistent in the project directory (not /tmp), making it easy to reproduce issues and share test cases.

## Directory Structure

```
test-suite/
├── archives/           # Test RAR files (13 archives)
├── source-files/       # Source files for creating archives
├── results/           # Test results and logs (timestamped)
├── scripts/           # Test execution scripts
│   ├── create-archives.sh   # Generate all test archives
│   ├── run-basic-tests.sh   # Basic functional tests
│   └── run-asan-tests.sh    # AddressSanitizer tests
└── README.md          # This file
```

## Quick Start

### 1. Create Test Archives

First, generate all test RAR files:

```bash
cd test-suite/scripts
./create-archives.sh
```

This creates 13 test archives:
- 5 basic functionality archives (uncompressed, compressed, multi-file, etc.)
- 5 error handling archives (truncated, random data, empty, etc.)
- 3 advanced archives (solid, max compression, binary data)

### 2. Run Basic Tests

Test core functionality:

```bash
./run-basic-tests.sh
```

This runs 12 tests covering:
- Archive mounting
- File reading and MD5 verification
- Multi-file and nested directory support
- Error handling (corrupt files should not crash)

### 3. Run AddressSanitizer Tests (Optional)

For memory safety validation:

```bash
# First, build with ASan (if not already done)
cd ../..
./build-with-asan.sh

# Then run ASan tests
cd test-suite/scripts
./run-asan-tests.sh
```

This runs all archives under AddressSanitizer to detect:
- Buffer overflows
- Use-after-free
- Memory leaks
- Use of uninitialized memory

## Test Archives

### Basic Functionality (01-05)

| Archive | Description | Purpose |
|---------|-------------|---------|
| 01-single-uncompressed.rar | Single file, store mode (-m0) | Test uncompressed RAR handling |
| 02-single-compressed.rar | Single file, normal compression (-m3) | Test decompression |
| 03-multifile.rar | 3 files in one archive | Test multi-file support |
| 04-nested-dirs.rar | 3-level directory structure | Test directory traversal |
| 05-large-compressible.rar | 1MB+ highly compressible file | Test large file handling |

### Error Handling (06-10)

| Archive | Description | Purpose |
|---------|-------------|---------|
| 06-truncated.rar | Truncated at 50% of valid RAR | Test truncation handling (no crash) |
| 07-random-data.rar | 10KB random data | Test invalid RAR detection |
| 08-empty.rar | 0-byte file | Test empty file handling |
| 09-invalid-signature.rar | Text file with .rar extension | Test signature validation |
| 10-too-small.rar | File smaller than RAR header | Test minimal file size handling |

### Advanced Features (11-13)

| Archive | Description | Purpose |
|---------|-------------|---------|
| 11-solid.rar | Solid archive (-s) | Test solid archive support |
| 12-max-compression.rar | Maximum compression (-m5) | Test high compression ratios |
| 13-binary-data.rar | Binary file data | Test non-text file handling |

## Test Scripts

### create-archives.sh

**Purpose**: Generate all test RAR archives from source files.

**Usage**:
```bash
cd test-suite/scripts
./create-archives.sh
```

**Output**:
- Creates 13 RAR archives in `../archives/`
- Verifies each with `unrar t`
- Logs to `../results/create-archives-YYYYMMDD-HHMMSS.log`

**Exit codes**:
- 0: All archives created successfully
- 1: One or more archives failed

### run-basic-tests.sh

**Purpose**: Run basic functional tests on rar2fs.

**Usage**:
```bash
cd test-suite/scripts
./run-basic-tests.sh
```

**Tests performed** (12 total):
1. Binary exists and is executable
2. Test archives exist
3. Mount single uncompressed archive
4. Read file content from compressed archive
5. Multi-file archive access
6. Nested directory structure
7. MD5 checksum verification
8. Large file access
9. Corrupted archive (truncated) - no crash
10. Corrupted archive (random data) - no crash
11. Corrupted archive (empty) - no crash

**Output**:
- Colorized PASS/FAIL for each test
- Summary: X/12 tests passed
- Logs to `../results/run-basic-tests-YYYYMMDD-HHMMSS.log`

**Exit codes**:
- 0: All tests passed
- 1: One or more tests failed

### run-asan-tests.sh

**Purpose**: Run tests under AddressSanitizer to detect memory errors.

**Prerequisites**:
- rar2fs must be built with ASan: `./build-with-asan.sh`

**Usage**:
```bash
cd test-suite/scripts
./run-asan-tests.sh
```

**Tests performed**:
- Mounts each archive
- Lists files
- Reads first file
- Checks for ASan violations

**Output**:
- Reports any memory errors detected
- Detailed ASan output in `../results/asan-output-YYYYMMDD-HHMMSS.log`
- Per-archive ASan logs in `../results/asan-{archive-name}.*`

**Exit codes**:
- 0: No memory errors detected
- 1: ASan errors found (review logs)

## Expected Results

### All Tests Passing

When rar2fs is working correctly, you should see:

```
==================================================
TEST SUMMARY
==================================================
Total tests: 12
Passed: 12
Failed: 0
```

### Common Issues

#### "rar2fs binary not found"
**Solution**: Build rar2fs first:
```bash
cd /path/to/rar2fs
make
# Or for ASan build:
./build-with-asan.sh
```

#### "No test archives found"
**Solution**: Create archives first:
```bash
cd test-suite/scripts
./create-archives.sh
```

#### "Mount failed"
**Solution**: Check if FUSE is available and you have permissions:
```bash
# Check FUSE
fusermount --version

# Check if you're in fuse group
groups | grep fuse

# If not, add yourself (requires logout/login)
sudo usermod -a -G fuse $USER
```

#### "Device or resource busy"
**Solution**: Unmount any existing mounts:
```bash
fusermount -u test-suite/mount
```

## Integration with CI/CD

These tests can be integrated into continuous integration:

```bash
#!/bin/bash
# Example CI script

set -e

# Build
./build-with-asan.sh

# Create test archives (once)
cd test-suite/scripts
./create-archives.sh

# Run tests
./run-basic-tests.sh
./run-asan-tests.sh

echo "All tests passed!"
```

## What Each Test Validates

### Regression Testing

These tests specifically validate recent fixes:

1. **OPT_INT macro fix**: Archives should mount and extract correctly (previously would fail due to macro misuse)

2. **Buffer overflow fix**: ASan tests should pass without heap-buffer-overflow in `opt_entry_[]` array

3. **Error handling**: Corrupt archives should fail gracefully without segfaults

### Memory Safety

AddressSanitizer tests validate:
- No buffer overflows when parsing RAR headers
- No use-after-free when extracting files
- No memory leaks during normal operation
- Proper cleanup on errors

### Functional Correctness

Basic tests validate:
- Files can be read from archives
- MD5 checksums are consistent
- Directory structures are preserved
- Multi-file archives work correctly

## Troubleshooting

### Test hangs on mount/unmount

If a test hangs, manually unmount:
```bash
fusermount -u test-suite/mount
killall rar2fs  # If needed
```

### ASan reports false positives

Some FUSE-related ASan warnings may be false positives. Focus on:
- Errors in rar2fs code (not libfuse)
- Heap-buffer-overflow
- Use-after-free
- Direct leaks (ignore indirect FUSE leaks)

### Archive creation fails

Check rar/unrar installation:
```bash
which rar unrar
rar --version
unrar --version
```

Install if needed:
```bash
# Debian/Ubuntu
sudo apt-get install rar unrar

# Or download from rarlab.com
```

## Extending the Test Suite

### Adding New Test Archives

1. Create source files in `source-files/`
2. Add archive creation to `create-archives.sh`
3. Add test function to `run-basic-tests.sh`
4. Update this README

### Adding New Test Cases

Add test functions to `run-basic-tests.sh`:

```bash
test_my_new_feature() {
    local archive="$ARCHIVE_DIR/my-test.rar"
    # ... test logic ...
    return 0  # or 1 on failure
}

# Then add to main execution:
run_test "My new feature" test_my_new_feature
```

## Development Workflow

1. Make changes to rar2fs source
2. Rebuild: `make` or `./build-with-asan.sh`
3. Run basic tests: `./test-suite/scripts/run-basic-tests.sh`
4. If tests fail, debug
5. Run ASan tests: `./test-suite/scripts/run-asan-tests.sh`
6. Commit changes with passing tests

## One-Line Test Command

To run all tests in sequence:

```bash
cd test-suite/scripts && ./create-archives.sh && ./run-basic-tests.sh && ./run-asan-tests.sh
```

Or create an alias:
```bash
alias test-rar2fs='cd /path/to/rar2fs/test-suite/scripts && ./run-basic-tests.sh'
```

## Test Results

All test results are saved with timestamps in `test-suite/results/`:
- `create-archives-YYYYMMDD-HHMMSS.log` - Archive creation log
- `run-basic-tests-YYYYMMDD-HHMMSS.log` - Basic test log
- `run-asan-tests-YYYYMMDD-HHMMSS.log` - ASan test log
- `asan-output-YYYYMMDD-HHMMSS.log` - Detailed ASan errors (if any)

These logs are useful for:
- Debugging test failures
- Comparing test runs over time
- Sharing results with other developers

## License

This test suite is part of rar2fs and follows the same license (GPLv3+).

## Contributing

When adding features or fixing bugs in rar2fs:
1. Add test cases that would have caught the bug
2. Ensure all existing tests still pass
3. Document new tests in this README
4. Include test results in pull requests

## Support

For issues with the test suite:
1. Check troubleshooting section above
2. Review test logs in `results/` directory
3. Open an issue on the rar2fs repository
