#include "pengrid_encrypted_zip.h"

#include "mz.h"
#include "mz_strm.h"
#include "mz_zip.h"
#include "pengrid_fd_stream.h"

#include <limits.h>
#include <string.h>

/* ZIP general-purpose bit 6 indicates strong encryption. */
#define PENGRID_ZIP_FLAG_STRONG_ENCRYPTION (1u << 6)

static int32_t pengrid_map_zip_status(int32_t status) {
    switch (status) {
    case MZ_OK:
        return PENGRID_ZIP_STATUS_OK;
    case MZ_MEM_ERROR:
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    case MZ_READ_ERROR:
    case MZ_WRITE_ERROR:
    case MZ_SEEK_ERROR:
    case MZ_TELL_ERROR:
    case MZ_OPEN_ERROR:
    case MZ_CLOSE_ERROR:
    case MZ_STREAM_ERROR:
        return PENGRID_ZIP_STATUS_IO_ERROR;
    default:
        return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
    }
}

static int32_t pengrid_inspect_entries(void *zip, pengrid_zip_inspection_t *result) {
    int32_t status = mz_zip_goto_first_entry(zip);
    if (status == MZ_END_OF_LIST)
        return PENGRID_ZIP_STATUS_OK;
    if (status != MZ_OK)
        return pengrid_map_zip_status(status);

    while (status == MZ_OK) {
        mz_zip_file *file_info = NULL;
        uint64_t uncompressed_size;

        if (result->entry_count == UINT64_MAX)
            return PENGRID_ZIP_STATUS_OVERFLOW;
        if (mz_zip_entry_get_info(zip, &file_info) != MZ_OK || !file_info)
            return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        if (file_info->uncompressed_size < 0)
            return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        uncompressed_size = (uint64_t)file_info->uncompressed_size;
        if (result->total_uncompressed_bytes > UINT64_MAX - uncompressed_size)
            return PENGRID_ZIP_STATUS_OVERFLOW;

        result->entry_count += 1;
        result->total_uncompressed_bytes += uncompressed_size;
        if ((file_info->flag & MZ_ZIP_FLAG_ENCRYPTED) != 0) {
            result->has_encrypted_entries = 1;
            if ((file_info->flag & PENGRID_ZIP_FLAG_STRONG_ENCRYPTION) != 0)
                result->has_unsupported_encryption = 1;
            if (file_info->aes_version != 0) {
                if (file_info->aes_strength < MZ_AES_STRENGTH_128 ||
                    file_info->aes_strength > MZ_AES_STRENGTH_256) {
                    result->has_unsupported_encryption = 1;
                } else if (file_info->aes_strength > result->strongest_aes_strength) {
                    result->strongest_aes_strength = file_info->aes_strength;
                }
            }
        }
        if (file_info->compression_method != MZ_COMPRESS_METHOD_STORE &&
            file_info->compression_method != MZ_COMPRESS_METHOD_DEFLATE) {
            result->has_unsupported_compression = 1;
        }

        status = mz_zip_goto_next_entry(zip);
        if (status == MZ_END_OF_LIST)
            return PENGRID_ZIP_STATUS_OK;
        if (status != MZ_OK)
            return pengrid_map_zip_status(status);
    }
    return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
}

const char *pengrid_zip_core_version(void) {
    return "minizip-ng 4.2.2";
}

void pengrid_secure_clear(void *bytes, size_t length) {
    if (bytes != NULL && length > 0 && memset_s(bytes, length, 0, length) != 0) {
        volatile unsigned char *cursor = (volatile unsigned char *)bytes;
        while (length > 0) {
            *cursor = 0;
            cursor += 1;
            length -= 1;
        }
    }
}

int32_t pengrid_zip_inspect_fd(int archive_fd, pengrid_zip_inspection_t *result) {
    void *stream = NULL;
    void *zip = NULL;
    int32_t status;

    if (archive_fd < 0 || !result)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    memset(result, 0, sizeof(*result));

    stream = pengrid_fd_stream_create(archive_fd);
    if (!stream)
        return PENGRID_ZIP_STATUS_IO_ERROR;
    zip = mz_zip_create();
    if (!zip) {
        mz_stream_delete(&stream);
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    }

    status = mz_zip_open(zip, stream, MZ_OPEN_MODE_READ);
    if (status == MZ_OK)
        status = pengrid_inspect_entries(zip, result);
    else
        status = pengrid_map_zip_status(status);

    mz_zip_close(zip);
    mz_zip_delete(&zip);
    mz_stream_delete(&stream);
    return status;
}
