#ifndef PENGRID_ENCRYPTED_ZIP_H
#define PENGRID_ENCRYPTED_ZIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *pengrid_zip_core_version(void);
void pengrid_secure_clear(void *bytes, size_t length);

typedef struct {
    uint64_t entry_count;
    uint64_t total_uncompressed_bytes;
    uint8_t has_encrypted_entries;
    uint8_t has_unsupported_encryption;
    uint8_t has_unsupported_compression;
    uint8_t strongest_aes_strength;
} pengrid_zip_inspection_t;

/* Stable Pengrid-owned statuses; callers must not depend on minizip values. */
#define PENGRID_ZIP_STATUS_OK                  (0)
#define PENGRID_ZIP_STATUS_INVALID_ARGUMENT   (-2000)
#define PENGRID_ZIP_STATUS_IO_ERROR           (-2001)
#define PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE  (-2002)
#define PENGRID_ZIP_STATUS_OVERFLOW           (-2003)
#define PENGRID_ZIP_STATUS_INTERNAL_ERROR     (-2004)
#define PENGRID_ZIP_STATUS_CANCELLED          (-2005)
#define PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY  (-2006)
#define PENGRID_ZIP_STATUS_UNSUPPORTED_COMPRESSION (-2007)
#define PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE (-2008)
#define PENGRID_ZIP_STATUS_CAPACITY           (-2009)
#define PENGRID_ZIP_STATUS_OUTPUT_BUDGET      (-2010)
#define PENGRID_ZIP_STATUS_IDENTITY_CHANGED   (-2011)
#define PENGRID_ZIP_STATUS_UNSUPPORTED_ENCRYPTION (-2012)
#define PENGRID_ZIP_STATUS_RECOVERY_REQUIRED  (-2013)

/* Short aliases are retained for C clients that prefer unqualified statuses. */
#define PENGRID_ZIP_OK                  PENGRID_ZIP_STATUS_OK
#define PENGRID_ZIP_INVALID_ARGUMENT   PENGRID_ZIP_STATUS_INVALID_ARGUMENT
#define PENGRID_ZIP_IO_ERROR           PENGRID_ZIP_STATUS_IO_ERROR
#define PENGRID_ZIP_MALFORMED_ARCHIVE  PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE
#define PENGRID_ZIP_OVERFLOW           PENGRID_ZIP_STATUS_OVERFLOW
#define PENGRID_ZIP_INTERNAL_ERROR     PENGRID_ZIP_STATUS_INTERNAL_ERROR

int32_t pengrid_zip_inspect_fd(int archive_fd, pengrid_zip_inspection_t *result);

typedef struct {
    uint64_t maximum_entry_count;
    uint64_t maximum_output_bytes;
    uint64_t capacity_reserve_bytes;
} pengrid_zip_limits_t;

typedef int32_t (*pengrid_zip_progress_callback)(
    uint64_t completed,
    uint64_t total,
    void *context);

int32_t pengrid_zip_create_aes256(
    int source_root_fd,
    int destination_fd,
    const uint8_t *password,
    size_t password_length,
    pengrid_zip_progress_callback progress,
    void *progress_context);

int32_t pengrid_zip_preflight_fd(
    int archive_fd,
    int destination_probe_root_fd,
    pengrid_zip_limits_t limits,
    pengrid_zip_inspection_t *inspection);

int32_t pengrid_zip_extract(
    int archive_fd,
    int destination_root_fd,
    const uint8_t *password,
    size_t password_length,
    pengrid_zip_limits_t limits,
    pengrid_zip_progress_callback progress,
    void *progress_context);

#ifdef __cplusplus
}
#endif

#endif
