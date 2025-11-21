/*
    Copyright (C) 2025 EP004 Implementation

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/**
 * EP004 Phase 2: Recursive RAR Archive Unpacking
 *
 * This module implements security-critical functions for nested RAR handling:
 * - Cycle detection via FNV-1a fingerprinting (prevents A→B→A loops)
 * - Path sanitization (blocks directory traversal attacks)
 * - Recursion context management (stack-allocated, thread-safe)
 * - Size limit enforcement (prevents decompression bombs)
 *
 * All functions follow fail-secure principles: errors return safe defaults.
 */

#include "platform.h"
#include "recursion.h"
#include "optdb.h"
#include "debug.h"
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>

/* UnRAR library types for callback */
#ifndef UINT
#define UINT unsigned int
#endif
#ifndef LPARAM
#define LPARAM long
#endif
#ifndef CALLBACK
#define CALLBACK
#endif
#define UCM_PROCESSDATA 1

/* Forward declarations for internal helper functions */
static uint64_t fnv1a_hash_64(const void *data, size_t len);
static bool is_absolute_path(const char *path);
static bool is_windows_absolute_path(const char *path);
static char *strip_dotdot_components(const char *path);
static bool is_valid_utf8(const char *path);

/**
 * Initialize recursion context with configuration defaults.
 * Reads --recursion-depth and --max-unpack-size from optdb.
 *
 * @param ctx Pointer to context structure (must not be NULL)
 */
void recursion_context_init(struct recursion_context *ctx)
{
        if (!ctx) {
                printd(1, "recursion_context_init: NULL context pointer\n");
                return;
        }

        memset(ctx, 0, sizeof(*ctx));

        /* Read max_depth from --recursion-depth option (default 5, max 10) */
        ctx->max_depth = DEFAULT_MAX_RECURSION_DEPTH;
        if (OPT_SET(OPT_KEY_RECURSION_DEPTH)) {
                int configured = OPT_INT(OPT_KEY_RECURSION_DEPTH, 0);
                if (configured >= 1 && configured <= MAX_RECURSION_DEPTH) {
                        ctx->max_depth = configured;
                } else {
                        printd(2, "recursion_context_init: invalid depth %d, "
                                  "using default %d\n",
                               configured, DEFAULT_MAX_RECURSION_DEPTH);
                }
        }

        /* Read max_unpacked_size from --max-unpack-size option (default 10GB) */
        ctx->max_unpacked_size = 10ULL * 1024 * 1024 * 1024; /* 10GB default */
        if (OPT_SET(OPT_KEY_MAX_UNPACK_SIZE)) {
                off_t configured = (off_t)OPT_INT(OPT_KEY_MAX_UNPACK_SIZE, 0);
                if (configured > 0) {
                        ctx->max_unpacked_size = configured;
                }
        }

        /* Initialize start time for timeout enforcement */
        clock_gettime(CLOCK_MONOTONIC, &ctx->start_time);

        printd(3, "recursion_context_init: max_depth=%d, max_size=%lld\n",
               ctx->max_depth, (long long)ctx->max_unpacked_size);
}

/**
 * Clean up recursion context (free dynamic allocations).
 * Must be called when done with context to avoid memory leaks.
 *
 * @param ctx Pointer to context structure
 */
void recursion_context_cleanup(struct recursion_context *ctx)
{
        if (!ctx) {
                return;
        }

        /* Free all archive chain path strings */
        for (int i = 0; i < MAX_RECURSION_DEPTH; i++) {
                if (ctx->archive_chain[i]) {
                        free(ctx->archive_chain[i]);
                        ctx->archive_chain[i] = NULL;
                }
        }

        printd(4, "recursion_context_cleanup: freed %d archive chain entries\n",
               ctx->depth);
}

/**
 * FNV-1a 64-bit hash algorithm (public domain).
 * Fast non-cryptographic hash with good distribution properties.
 *
 * @param data Pointer to data buffer
 * @param len Length of data in bytes
 * @return 64-bit hash value
 */
static uint64_t fnv1a_hash_64(const void *data, size_t len)
{
        uint64_t hash = FNV_64_OFFSET_BASIS;
        const unsigned char *p = (const unsigned char *)data;

        for (size_t i = 0; i < len; i++) {
                hash ^= p[i];
                hash *= FNV_64_PRIME;
        }

        return hash;
}

/**
 * Compute archive fingerprint using FNV-1a 64-bit hash.
 * Hashes first 4KB and last 4KB for fast uniqueness checking.
 *
 * @param rar_data Pointer to archive data in memory
 * @param rar_size Size of archive in bytes
 * @param mtime Modification time of archive (TOCTOU mitigation)
 * @return Archive fingerprint structure
 */
struct archive_fingerprint compute_archive_fingerprint(
        const void *rar_data,
        size_t rar_size,
        time_t mtime)
{
        struct archive_fingerprint fp = {0};

        if (!rar_data || rar_size == 0) {
                printd(3, "compute_archive_fingerprint: invalid input "
                          "(data=%p, size=%zu)\n", rar_data, rar_size);
                return fp;
        }

        fp.size = rar_size;
        fp.mtime = mtime;

        /* Hash first chunk (up to 4KB) */
        size_t first_chunk_size = (rar_size < FINGERPRINT_CHUNK_SIZE)
                                  ? rar_size : FINGERPRINT_CHUNK_SIZE;
        uint64_t hash1 = fnv1a_hash_64(rar_data, first_chunk_size);

        /* Hash last chunk (up to 4KB) if file is larger */
        uint64_t hash2 = 0;
        if (rar_size > FINGERPRINT_CHUNK_SIZE) {
                const unsigned char *last_chunk =
                        (const unsigned char *)rar_data + rar_size -
                        FINGERPRINT_CHUNK_SIZE;
                size_t last_chunk_size = FINGERPRINT_CHUNK_SIZE;
                hash2 = fnv1a_hash_64(last_chunk, last_chunk_size);
        }

        /* Combine hashes: XOR first and last, then hash the combination */
        uint64_t combined = hash1 ^ hash2;
        fp.hash = fnv1a_hash_64(&combined, sizeof(combined));

        printd(4, "compute_archive_fingerprint: size=%zu, hash=0x%016llx\n",
               rar_size, (unsigned long long)fp.hash);

        return fp;
}

/**
 * Check if archive creates a cycle (already visited in current chain).
 * Compares fingerprint against all entries in visited array.
 *
 * @param ctx Pointer to recursion context
 * @param fp Pointer to fingerprint to check
 * @return true if cycle detected, false otherwise
 */
bool is_cycle_detected(struct recursion_context *ctx,
                      const struct archive_fingerprint *fp)
{
        if (!ctx || !fp) {
                printd(2, "is_cycle_detected: NULL pointer (ctx=%p, fp=%p)\n",
                       ctx, fp);
                return true; /* Fail-secure: treat as cycle */
        }

        /* Check fingerprint against all visited archives in current chain */
        for (int i = 0; i < ctx->depth; i++) {
                const struct archive_fingerprint *visited = &ctx->visited[i];

                /* Match requires: same hash AND same size AND same mtime */
                if (visited->hash == fp->hash &&
                    visited->size == fp->size &&
                    visited->mtime == fp->mtime) {
                        printd(2, "is_cycle_detected: CYCLE at depth %d "
                                  "(hash=0x%016llx, size=%lld)\n",
                               i, (unsigned long long)fp->hash,
                               (long long)fp->size);

                        /* Log full chain for forensics */
                        printd(2, "Archive chain:\n");
                        for (int j = 0; j <= i; j++) {
                                printd(2, "  [%d] %s\n", j,
                                       ctx->archive_chain[j]
                                       ? ctx->archive_chain[j] : "(unknown)");
                        }

                        return true;
                }
        }

        return false;
}

/**
 * Push archive onto visited stack (call after cycle check passes).
 * Increments depth and adds fingerprint to visited array.
 *
 * @param ctx Pointer to recursion context
 * @param fp Pointer to archive fingerprint
 * @param archive_path Path to archive (for error reporting)
 * @return 0 on success, -ELOOP if max depth exceeded
 */
int recursion_push_archive(struct recursion_context *ctx,
                           const struct archive_fingerprint *fp,
                           const char *archive_path)
{
        if (!ctx || !fp) {
                printd(1, "recursion_push_archive: NULL pointer\n");
                return -EINVAL;
        }

        /* Check depth limit BEFORE incrementing */
        if (ctx->depth >= ctx->max_depth) {
                printd(2, "recursion_push_archive: DEPTH LIMIT exceeded "
                          "(current=%d, max=%d) for %s\n",
                       ctx->depth, ctx->max_depth,
                       archive_path ? archive_path : "(unknown)");
                return -ELOOP;
        }

        if (ctx->depth >= MAX_RECURSION_DEPTH) {
                printd(1, "recursion_push_archive: ABSOLUTE LIMIT exceeded "
                          "(depth=%d, max=%d)\n",
                       ctx->depth, MAX_RECURSION_DEPTH);
                return -ELOOP;
        }

        /* Store fingerprint in visited array */
        ctx->visited[ctx->depth] = *fp;

        /* Store archive path for error reporting (strdup for safety) */
        if (archive_path) {
                ctx->archive_chain[ctx->depth] = strdup(archive_path);
                if (!ctx->archive_chain[ctx->depth]) {
                        printd(1, "recursion_push_archive: strdup failed\n");
                        return -ENOMEM;
                }
        }

        ctx->depth++;

        printd(3, "recursion_push_archive: pushed %s at depth %d/%d\n",
               archive_path ? archive_path : "(unknown)",
               ctx->depth, ctx->max_depth);

        return 0;
}

/**
 * Pop archive from visited stack (call when exiting recursion level).
 * Decrements depth and clears fingerprint from visited array.
 *
 * @param ctx Pointer to recursion context
 */
void recursion_pop_archive(struct recursion_context *ctx)
{
        if (!ctx) {
                return;
        }

        if (ctx->depth <= 0) {
                printd(2, "recursion_pop_archive: underflow (depth=%d)\n",
                       ctx->depth);
                return;
        }

        ctx->depth--;

        /* Clear fingerprint */
        memset(&ctx->visited[ctx->depth], 0,
               sizeof(struct archive_fingerprint));

        /* Free archive path string */
        if (ctx->archive_chain[ctx->depth]) {
                printd(4, "recursion_pop_archive: popped %s from depth %d\n",
                       ctx->archive_chain[ctx->depth], ctx->depth);
                free(ctx->archive_chain[ctx->depth]);
                ctx->archive_chain[ctx->depth] = NULL;
        }
}

/**
 * Check if path is absolute (starts with / or \).
 *
 * @param path Path string to check
 * @return true if absolute, false otherwise
 */
static bool is_absolute_path(const char *path)
{
        if (!path || path[0] == '\0') {
                return false;
        }
        return (path[0] == '/' || path[0] == '\\');
}

/**
 * Check if path is Windows absolute path (e.g., C:\, D:\).
 *
 * @param path Path string to check
 * @return true if Windows absolute, false otherwise
 */
static bool is_windows_absolute_path(const char *path)
{
        if (!path || strlen(path) < 3) {
                return false;
        }

        /* Check for pattern: [A-Za-z]:[\\/] */
        return (isalpha((unsigned char)path[0]) &&
                path[1] == ':' &&
                (path[2] == '\\' || path[2] == '/'));
}

/**
 * Strip all ".." components from path.
 * Returns newly allocated string with components removed.
 *
 * @param path Path string to process
 * @return Sanitized path (caller must free) or NULL on error
 */
static char *strip_dotdot_components(const char *path)
{
        if (!path) {
                return NULL;
        }

        size_t len = strlen(path);
        char *result = malloc(len + 1);
        if (!result) {
                printd(1, "strip_dotdot_components: malloc failed\n");
                return NULL;
        }

        const char *src = path;
        char *dst = result;

        while (*src) {
                /* Check for ".." component */
                if (src[0] == '.' && src[1] == '.' &&
                    (src[2] == '/' || src[2] == '\\' || src[2] == '\0')) {
                        /* Skip ".." and following separator */
                        printd(3, "strip_dotdot_components: removing '..' "
                                  "at position %ld\n", src - path);
                        src += 2;
                        if (*src == '/' || *src == '\\') {
                                src++;
                        }
                        continue;
                }

                /* Copy character */
                *dst++ = *src++;
        }

        *dst = '\0';

        /* Remove any remaining ".." at the start */
        if (result[0] == '.' && result[1] == '.' &&
            (result[2] == '/' || result[2] == '\0')) {
                printd(2, "strip_dotdot_components: leading '..' detected\n");
                free(result);
                return NULL;
        }

        return result;
}

/**
 * Validate UTF-8 encoding of path string.
 * Rejects invalid byte sequences and overlong encodings.
 *
 * @param path Path string to validate
 * @return true if valid UTF-8, false otherwise
 */
static bool is_valid_utf8(const char *path)
{
        if (!path) {
                return false;
        }

        const unsigned char *bytes = (const unsigned char *)path;

        while (*bytes) {
                if ((*bytes & 0x80) == 0) {
                        /* Single-byte character (0xxxxxxx) */
                        bytes++;
                } else if ((*bytes & 0xE0) == 0xC0) {
                        /* Two-byte character (110xxxxx 10xxxxxx) */
                        if ((bytes[1] & 0xC0) != 0x80) {
                                return false;
                        }
                        /* Check for overlong encoding */
                        if ((*bytes & 0xFE) == 0xC0) {
                                return false;
                        }
                        bytes += 2;
                } else if ((*bytes & 0xF0) == 0xE0) {
                        /* Three-byte character (1110xxxx 10xxxxxx 10xxxxxx) */
                        if ((bytes[1] & 0xC0) != 0x80 ||
                            (bytes[2] & 0xC0) != 0x80) {
                                return false;
                        }
                        /* Check for overlong encoding */
                        if (*bytes == 0xE0 && (bytes[1] & 0xE0) == 0x80) {
                                return false;
                        }
                        bytes += 3;
                } else if ((*bytes & 0xF8) == 0xF0) {
                        /* Four-byte character (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx) */
                        if ((bytes[1] & 0xC0) != 0x80 ||
                            (bytes[2] & 0xC0) != 0x80 ||
                            (bytes[3] & 0xC0) != 0x80) {
                                return false;
                        }
                        /* Check for overlong encoding */
                        if (*bytes == 0xF0 && (bytes[1] & 0xF0) == 0x80) {
                                return false;
                        }
                        /* Check for values > U+10FFFF */
                        if (*bytes > 0xF4) {
                                return false;
                        }
                        bytes += 4;
                } else {
                        /* Invalid UTF-8 start byte */
                        return false;
                }
        }

        return true;
}

/**
 * Sanitize nested archive path for security.
 * Applies 6 validation rules per SECURITY_DESIGN.md Section 3.1:
 * 1. Reject absolute paths (/ or \)
 * 2. Reject Windows absolute paths (C:\)
 * 3. Strip all .. components
 * 4. Convert backslashes to forward slashes
 * 5. Validate UTF-8 encoding
 * 6. Reject paths >4096 characters
 *
 * @param path Path to sanitize
 * @return Sanitized path (caller must free) or NULL if malicious
 */
char *sanitize_nested_path(const char *path)
{
        if (!path) {
                printd(2, "sanitize_nested_path: NULL path\n");
                return NULL;
        }

        /* Rule 6: Reject paths exceeding maximum length */
        size_t len = strlen(path);
        if (len == 0) {
                printd(2, "sanitize_nested_path: empty path\n");
                return NULL;
        }
        if (len > MAX_NESTED_PATH_LENGTH) {
                printd(2, "sanitize_nested_path: path too long (%zu > %d)\n",
                       len, MAX_NESTED_PATH_LENGTH);
                return NULL;
        }

        /* Rule 1: Reject absolute paths */
        if (is_absolute_path(path)) {
                printd(2, "sanitize_nested_path: absolute path rejected: %s\n",
                       path);
                return NULL;
        }

        /* Rule 2: Reject Windows absolute paths */
        if (is_windows_absolute_path(path)) {
                printd(2, "sanitize_nested_path: Windows absolute path "
                          "rejected: %s\n", path);
                return NULL;
        }

        /* Rule 5: Validate UTF-8 encoding */
        if (!is_valid_utf8(path)) {
                printd(2, "sanitize_nested_path: invalid UTF-8 encoding: %s\n",
                       path);
                return NULL;
        }

        /* Rule 4: Convert backslashes to forward slashes */
        char *normalized = strdup(path);
        if (!normalized) {
                printd(1, "sanitize_nested_path: strdup failed\n");
                return NULL;
        }

        for (size_t i = 0; normalized[i]; i++) {
                if (normalized[i] == '\\') {
                        normalized[i] = '/';
                }
        }

        /* Rule 3: Strip all ".." components */
        char *sanitized = strip_dotdot_components(normalized);
        free(normalized);

        if (!sanitized) {
                printd(2, "sanitize_nested_path: path contains '..' "
                          "components: %s\n", path);
                return NULL;
        }

        /* Final validation: ensure result is not empty after sanitization */
        if (sanitized[0] == '\0') {
                printd(2, "sanitize_nested_path: path sanitized to empty "
                          "string: %s\n", path);
                free(sanitized);
                return NULL;
        }

        printd(4, "sanitize_nested_path: OK: %s → %s\n", path, sanitized);
        return sanitized;
}

/**
 * Check if archive cumulative unpack size exceeds limit.
 * Tracks total unpacked size across all nesting levels.
 *
 * @param ctx Pointer to recursion context
 * @param archive_size Size of archive to unpack (in bytes)
 * @return 0 if within limit, -EFBIG if exceeded
 */
int check_unpack_size_limit(struct recursion_context *ctx, off_t archive_size)
{
        if (!ctx) {
                printd(1, "check_unpack_size_limit: NULL context\n");
                return -EINVAL;
        }

        if (archive_size < 0) {
                printd(2, "check_unpack_size_limit: negative size %lld\n",
                       (long long)archive_size);
                return -EINVAL;
        }

        /* Check for overflow before adding */
        if (ctx->total_unpacked_size >
            ctx->max_unpacked_size - archive_size) {
                printd(2, "check_unpack_size_limit: SIZE LIMIT exceeded "
                          "(current=%lld + new=%lld > max=%lld)\n",
                       (long long)ctx->total_unpacked_size,
                       (long long)archive_size,
                       (long long)ctx->max_unpacked_size);
                return -EFBIG;
        }

        /* Add to cumulative total */
        ctx->total_unpacked_size += archive_size;

        printd(4, "check_unpack_size_limit: added %lld bytes "
                  "(total=%lld/%lld)\n",
               (long long)archive_size,
               (long long)ctx->total_unpacked_size,
               (long long)ctx->max_unpacked_size);

        return 0;
}

/**
 * UCM_PROCESSDATA callback for extracting RAR file to memory buffer.
 * Called by UnRAR library with data chunks during extraction.
 *
 * @param msg Message type (UCM_PROCESSDATA expected)
 * @param UserData Pointer to struct extract_buffer
 * @param P1 Pointer to data chunk
 * @param P2 Size of data chunk
 * @return 1 to continue, -1 to abort
 */
static int CALLBACK extract_to_memory_callback(UINT msg, LPARAM UserData,
                                               LPARAM P1, LPARAM P2)
{
        if (msg != UCM_PROCESSDATA) {
                return 1; /* Ignore other messages */
        }

        struct extract_buffer *buf = (struct extract_buffer *)UserData;
        if (!buf || buf->error) {
                return -1; /* Already in error state */
        }

        size_t chunk_size = (size_t)P2;
        void *chunk_data = (void *)P1;

        if (chunk_size == 0 || !chunk_data) {
                return 1; /* Empty chunk, continue */
        }

        /* Check if we need to grow the buffer */
        if (buf->size + chunk_size > buf->capacity) {
                /* Double capacity (or set to chunk_size if larger) */
                size_t new_capacity = buf->capacity * 2;
                if (new_capacity < buf->size + chunk_size) {
                        new_capacity = buf->size + chunk_size;
                }

                /* Limit to 1GB to prevent decompression bombs */
                if (new_capacity > 1024ULL * 1024 * 1024) {
                        printd(1, "extract_to_memory_callback: buffer too large "
                                  "(%zu bytes)\n", new_capacity);
                        buf->error = 1;
                        return -1;
                }

                void *new_data = realloc(buf->data, new_capacity);
                if (!new_data) {
                        printd(1, "extract_to_memory_callback: realloc failed "
                                  "for %zu bytes\n", new_capacity);
                        buf->error = 1;
                        return -1;
                }

                buf->data = new_data;
                buf->capacity = new_capacity;
                printd(4, "extract_to_memory_callback: grew buffer to %zu bytes\n",
                       new_capacity);
        }

        /* Copy chunk to buffer */
        memcpy((char *)buf->data + buf->size, chunk_data, chunk_size);
        buf->size += chunk_size;

        printd(4, "extract_to_memory_callback: copied %zu bytes (total=%zu)\n",
               chunk_size, buf->size);

        return 1; /* Continue extraction */
}

/**
 * Free extract buffer (if allocated).
 *
 * @param buffer Pointer to extract buffer
 */
void free_extract_buffer(struct extract_buffer *buffer)
{
        if (!buffer) {
                return;
        }

        if (buffer->data) {
                free(buffer->data);
                buffer->data = NULL;
        }

        buffer->size = 0;
        buffer->capacity = 0;
        buffer->error = 0;
}

/**
 * Extract nested RAR file to memory buffer.
 * NOTE: This function requires UnRAR library types which are not
 * included in recursion.h to avoid circular dependencies.
 * Implementation will be completed in rar2fs.c where UnRAR types are available.
 *
 * This is a placeholder - actual implementation moved to rar2fs.c.
 */
int extract_nested_rar_to_memory(void *rar_handle,
                                 const char *filename,
                                 struct extract_buffer *out_buffer,
                                 time_t *out_mtime)
{
        printd(1, "extract_nested_rar_to_memory: not implemented "
                  "(moved to rar2fs.c)\n");
        return -ENOSYS;
}

/**
 * Write extracted buffer to temporary file for recursive processing.
 * Creates a secure temporary file in /tmp.
 *
 * @param buffer Pointer to extract buffer
 * @param out_path Buffer for temp file path (must be PATH_MAX size)
 * @return 0 on success, negative errno on error
 */
int write_buffer_to_tempfile(struct extract_buffer *buffer, char *out_path)
{
        if (!buffer || !buffer->data || buffer->size == 0 || !out_path) {
                printd(1, "write_buffer_to_tempfile: invalid arguments\n");
                return -EINVAL;
        }

        /* Create unique temp file name */
        snprintf(out_path, PATH_MAX, "/tmp/rar2fs_nested_XXXXXX");

        /* Create secure temp file */
        int fd = mkstemp(out_path);
        if (fd < 0) {
                printd(1, "write_buffer_to_tempfile: mkstemp failed: %s\n",
                       strerror(errno));
                return -errno;
        }

        /* Write all data */
        ssize_t written = write(fd, buffer->data, buffer->size);
        if (written != (ssize_t)buffer->size) {
                printd(1, "write_buffer_to_tempfile: write failed "
                          "(wrote %zd of %zu bytes)\n",
                       written, buffer->size);
                close(fd);
                unlink(out_path);
                return -EIO;
        }

        /* Sync to ensure data is on disk */
        if (fsync(fd) < 0) {
                printd(2, "write_buffer_to_tempfile: fsync failed: %s\n",
                       strerror(errno));
                /* Continue anyway - not critical */
        }

        close(fd);

        printd(3, "write_buffer_to_tempfile: wrote %zu bytes to %s\n",
               buffer->size, out_path);

        return 0;
}
