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

/* Short aliases are retained for C clients that prefer unqualified statuses. */
#define PENGRID_ZIP_OK                  PENGRID_ZIP_STATUS_OK
#define PENGRID_ZIP_INVALID_ARGUMENT   PENGRID_ZIP_STATUS_INVALID_ARGUMENT
#define PENGRID_ZIP_IO_ERROR           PENGRID_ZIP_STATUS_IO_ERROR
#define PENGRID_ZIP_MALFORMED_ARCHIVE  PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE
#define PENGRID_ZIP_OVERFLOW           PENGRID_ZIP_STATUS_OVERFLOW
#define PENGRID_ZIP_INTERNAL_ERROR     PENGRID_ZIP_STATUS_INTERNAL_ERROR

int32_t pengrid_zip_inspect_fd(int archive_fd, pengrid_zip_inspection_t *result);

#ifdef __cplusplus
}
#endif

#endif
