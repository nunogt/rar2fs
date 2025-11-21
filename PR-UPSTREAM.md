# Migrate to FUSE3 and add recursive RAR unpacking

## Summary

This PR modernizes rar2fs with two major enhancements:

1. **FUSE3 Migration**: Complete migration from FUSE 2.6 (2006) to FUSE3, enabling modern kernel optimizations and production tuning
2. **Recursive RAR Unpacking**: Transparent extraction of nested RAR-within-RAR archives with security controls

## FUSE3 Migration

**Breaking Change**: Requires libfuse3-dev >= 3.2.0 (FUSE 2.x no longer supported)

**API Changes**:
- Updated 9 callback signatures for FUSE3 compatibility
- Implemented `lseek()` with SEEK_DATA/SEEK_HOLE support
- Removed all FUSE2 fallback code

**New Features**:
- 10 production tuning options (`--fuse-*` flags):
  - Cache timeouts: entry, attr, negative (default: 600s for immutable archives)
  - Buffer sizes: max_write (1MB), max_readahead (512KB)
  - Throughput: max_background, congestion_threshold
  - Capability toggles: async-read, splice-read, parallel-dirops
- FUSE3 optimizations: readdir caching, zero-copy I/O, parallel directory operations

**Migration Path**:
```bash
# Debian/Ubuntu
sudo apt-get install libfuse3-dev pkg-config

# Fedora/RHEL
sudo dnf install fuse3-devel pkgconfig

# Rebuild
./configure && make && sudo make install
```

## Recursive RAR Unpacking

**Default**: Disabled for security (opt-in with `--recursive`)

**Configuration**:
- `--recursive`: Enable nested RAR extraction
- `--recursion-depth N`: Maximum nesting levels (default: 5, range: 1-10)
- `--recursion-max-size N`: Decompression bomb limit (default: 10GB)

**Implementation**:
- Memory-based extraction (no temporary files)
- Flat unpacking: nested files appear at parent level
- First-wins collision handling
- Thread-safe via existing rwlocks

**Security**:
- FNV-1a cycle detection (prevents A→B→A loops)
- Path sanitization (blocks `../` and absolute paths)
- Depth limits (prevents stack exhaustion)
- Size limits (prevents decompression bombs)

**Example**:
```bash
# Archive: video.rar contains video.mkv + subtitles.rar (en.srt, es.srt)
rar2fs --recursive /archives /mnt/rar
ls /mnt/rar/
# Output: video.mkv  en.srt  es.srt
```

## Implementation

- FUSE3: Clean compilation, no regressions, thread-safe rwlock usage validated
- Recursive RAR: Security validations (path sanitization, size bombs, depth limits, cycle detection)

## Documentation

- `man/rar2fs.1`: FUSE3 options, recursive unpacking, security
- `README`: Migration guide, usage examples
- `ChangeLog`: v3.0.0 documentation
