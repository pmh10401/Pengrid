#include "mz.h"
#include "mz_crypt.h"
#include "pengrid_encrypted_zip.h"

#include <stdint.h>
#include <string.h>

#if defined(HAVE_ZLIB)
#include <zlib.h>
#endif

/* Pengrid-owned replacements for the small portions of mz_crypt.c used by
 * WinZip AES.  The upstream implementation remains byte-for-byte unchanged
 * in vendor/minizip-ng and is excluded from the target. */
uint32_t mz_crypt_crc32_update(uint32_t value, const uint8_t *buf, int32_t size) {
#if defined(HAVE_ZLIB)
    if (size < 0)
        return value;
    return (uint32_t)crc32((uLong)value, buf, (uInt)size);
#else
    uint32_t crc = ~value;
    int32_t index;
    if (!buf || size < 0)
        return value;
    while (size-- > 0) {
        crc ^= *buf++;
        for (index = 0; index < 8; index++)
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(crc & 1));
    }
    return ~crc;
#endif
}

#if defined(HAVE_WZAES)
int32_t mz_crypt_pbkdf2(const uint8_t *password, int32_t password_length, const uint8_t *salt, int32_t salt_length,
                        uint32_t iteration_count, uint8_t *key, uint16_t key_length) {
    void *hmac1 = NULL;
    void *hmac2 = NULL;
    void *hmac3 = NULL;
    int32_t err = MZ_OK;
    uint16_t i = 0;
    uint32_t j = 0;
    uint16_t k = 0;
    uint16_t block_count = 0;
    uint8_t uu[MZ_HASH_SHA1_SIZE];
    uint8_t ux[MZ_HASH_SHA1_SIZE];

    memset(uu, 0, sizeof(uu));
    memset(ux, 0, sizeof(ux));
    if (!password || !salt || !key) {
        err = MZ_PARAM_ERROR;
        goto pbkdf2_cleanup;
    }

    memset(key, 0, key_length);
    hmac1 = mz_crypt_hmac_create();
    hmac2 = mz_crypt_hmac_create();
    hmac3 = mz_crypt_hmac_create();
    if (!hmac1 || !hmac2 || !hmac3) {
        err = MZ_MEM_ERROR;
        goto pbkdf2_cleanup;
    }

    mz_crypt_hmac_set_algorithm(hmac1, MZ_HASH_SHA1);
    mz_crypt_hmac_set_algorithm(hmac2, MZ_HASH_SHA1);
    mz_crypt_hmac_set_algorithm(hmac3, MZ_HASH_SHA1);

    err = mz_crypt_hmac_init(hmac1, password, password_length);
    if (err == MZ_OK)
        err = mz_crypt_hmac_init(hmac2, password, password_length);
    if (err == MZ_OK)
        err = mz_crypt_hmac_update(hmac2, salt, salt_length);

    if (err == MZ_OK && key_length > 0)
        block_count = (uint16_t)(1 + ((uint16_t)key_length - 1) / MZ_HASH_SHA1_SIZE);

    for (i = 0; (err == MZ_OK) && (i < block_count); i += 1) {
        memset(ux, 0, sizeof(ux));
        err = mz_crypt_hmac_copy(hmac2, hmac3);
        if (err != MZ_OK)
            break;

        uu[0] = (uint8_t)((i + 1) >> 24);
        uu[1] = (uint8_t)((i + 1) >> 16);
        uu[2] = (uint8_t)((i + 1) >> 8);
        uu[3] = (uint8_t)(i + 1);
        for (j = 0, k = 4; j < iteration_count; j += 1) {
            err = mz_crypt_hmac_update(hmac3, uu, k);
            if (err == MZ_OK)
                err = mz_crypt_hmac_end(hmac3, uu, sizeof(uu));
            if (err != MZ_OK)
                break;
            for (k = 0; k < MZ_HASH_SHA1_SIZE; k += 1)
                ux[k] ^= uu[k];
            err = mz_crypt_hmac_copy(hmac1, hmac3);
            if (err != MZ_OK)
                break;
        }
        if (err != MZ_OK)
            break;

        j = 0;
        k = (uint16_t)(i * MZ_HASH_SHA1_SIZE);
        while (j < MZ_HASH_SHA1_SIZE && k < key_length)
            key[k++] = ux[j++];
    }

pbkdf2_cleanup:
    mz_crypt_hmac_delete(&hmac3);
    mz_crypt_hmac_delete(&hmac1);
    mz_crypt_hmac_delete(&hmac2);
    pengrid_secure_clear(uu, sizeof(uu));
    pengrid_secure_clear(ux, sizeof(ux));
    return err;
}
#endif
