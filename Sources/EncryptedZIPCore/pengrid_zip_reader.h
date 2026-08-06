#ifndef PENGRID_ZIP_READER_H
#define PENGRID_ZIP_READER_H

#include "pengrid_encrypted_zip.h"

#ifdef __cplusplus
extern "C" {
#endif

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
