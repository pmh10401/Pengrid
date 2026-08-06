#include "pengrid_encrypted_zip.h"

#include <string.h>

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
