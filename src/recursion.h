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

#ifndef RECURSION_H_
#define RECURSION_H_

#include <platform.h>
#include <sys/types.h>
#include <stdint.h>
#include <time.h>

/* EP004 Phase 2: Recursive RAR Unpacking */

/* Maximum recursion depth (absolute security limit) */
#define MAX_RECURSION_DEPTH 10

/* Default recursion depth */
#define DEFAULT_MAX_RECURSION_DEPTH 5

/* FNV-1a 64-bit hash constants */
#define FNV_64_PRIME 0x100000001b3ULL
#define FNV_64_OFFSET_BASIS 0xcbf29ce484222325ULL

/* Fingerprint chunk size for hashing (4KB) */
#define FINGERPRINT_CHUNK_SIZE 4096

/* Maximum path length for nested paths */
#define MAX_NESTED_PATH_LENGTH 4096

/**
 * Archive fingerprint structure for cycle detection.
 * Uses FNV-1a 64-bit hash for fast comparison with low collision rate.
 */
struct archive_fingerprint {
        uint64_t hash;           /* 64-bit FNV-1a hash of first/last 4KB */
        off_t size;              /* File size (exact match required) */
        time_t mtime;            /* Modification time (TOCTOU mitigation) */
};

/**
 * Recursion context structure (stack-allocated for thread safety).
 * Tracks state during recursive archive unpacking.
 *
 * Memory layout: ~448 bytes
 * - Basic fields: 32 bytes
 * - visited array: 10 × 24 = 240 bytes
 * - archive_chain pointers: 10 × 8 = 80 bytes
 * - archive_chain strings: ~100 bytes average (dynamically allocated)
 */
struct recursion_context {
        int depth;                                              /* Current nesting level (0-based) */
        int max_depth;                                          /* Configured limit (default 5, max 10) */
        struct archive_fingerprint visited[MAX_RECURSION_DEPTH]; /* Stack of visited archives */
        char *archive_chain[MAX_RECURSION_DEPTH];               /* Virtual path chain for error reporting */
        off_t total_unpacked_size;                              /* Cumulative bytes unpacked */
        off_t max_unpacked_size;                                /* Size limit (default 10GB) */
        struct timespec start_time;                             /* For timeout enforcement */
};

/**
 * Initialize recursion context with configuration defaults.
 * Must be called before first use.
 *
 * @param ctx Pointer to context structure
 */
void recursion_context_init(struct recursion_context *ctx);

/**
 * Clean up recursion context (free dynamic allocations).
 * Must be called when done with context.
 *
 * @param ctx Pointer to context structure
 */
void recursion_context_cleanup(struct recursion_context *ctx);

/**
 * Compute archive fingerprint using FNV-1a 64-bit hash.
 * Hashes first 4KB and last 4KB for uniqueness.
 *
 * @param rar_data Pointer to archive data
 * @param rar_size Size of archive in bytes
 * @param mtime Modification time of archive
 * @return Archive fingerprint structure
 */
struct archive_fingerprint compute_archive_fingerprint(
        const void *rar_data,
        size_t rar_size,
        time_t mtime);

/**
 * Check if archive creates a cycle (already visited in current chain).
 * Returns true if fingerprint matches any entry in visited array.
 *
 * @param ctx Pointer to recursion context
 * @param fp Pointer to fingerprint to check
 * @return true if cycle detected, false otherwise
 */
bool is_cycle_detected(struct recursion_context *ctx,
                      const struct archive_fingerprint *fp);

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
                           const char *archive_path);

/**
 * Pop archive from visited stack (call when exiting recursion level).
 * Decrements depth and clears fingerprint from visited array.
 *
 * @param ctx Pointer to recursion context
 */
void recursion_pop_archive(struct recursion_context *ctx);

/**
 * Sanitize nested archive path for security.
 * Applies 6 validation rules:
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
char *sanitize_nested_path(const char *path);

/**
 * Check if archive cumulative unpack size exceeds limit.
 * Tracks total unpacked size across all nesting levels.
 *
 * @param ctx Pointer to recursion context
 * @param archive_size Size of archive to unpack
 * @return 0 if within limit, -EFBIG if exceeded
 */
int check_unpack_size_limit(struct recursion_context *ctx, off_t archive_size);

/**
 * Memory buffer for extracting nested RAR to RAM.
 * Used by extract_nested_rar_to_memory() function.
 */
struct extract_buffer {
        void *data;              /* Extracted data buffer (malloc'd) */
        size_t size;             /* Current data size */
        size_t capacity;         /* Allocated buffer capacity */
        int error;               /* Error flag (0=OK, 1=error) */
};

/**
 * Extract nested RAR file to memory buffer.
 * Uses UnRAR RARProcessFile with UCM_PROCESSDATA callback.
 *
 * @param rar_handle RAR archive handle
 * @param filename Filename within archive to extract
 * @param out_buffer Pointer to buffer struct (filled on success)
 * @param out_mtime Pointer to store file modification time
 * @return 0 on success, negative errno on error
 */
int extract_nested_rar_to_memory(void *rar_handle,
                                 const char *filename,
                                 struct extract_buffer *out_buffer,
                                 time_t *out_mtime);

/**
 * Write extracted buffer to temporary file for recursive processing.
 * Creates a secure temporary file in /tmp with random name.
 *
 * @param buffer Pointer to extract buffer
 * @param out_path Buffer for temp file path (must be PATH_MAX size)
 * @return 0 on success, negative errno on error
 */
int write_buffer_to_tempfile(struct extract_buffer *buffer, char *out_path);

/**
 * Free extract buffer (if allocated).
 *
 * @param buffer Pointer to extract buffer
 */
void free_extract_buffer(struct extract_buffer *buffer);

#endif /* RECURSION_H_ */
