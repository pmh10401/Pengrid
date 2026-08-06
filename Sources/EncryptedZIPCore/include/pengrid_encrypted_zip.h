#ifndef PENGRID_ENCRYPTED_ZIP_H
#define PENGRID_ENCRYPTED_ZIP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *pengrid_zip_core_version(void);
void pengrid_secure_clear(void *bytes, size_t length);

#ifdef __cplusplus
}
#endif

#endif
