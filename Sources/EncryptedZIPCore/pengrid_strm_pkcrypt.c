/* pengrid_strm_pkcrypt.c -- Pengrid-owned, ABI-compatible ZipCrypto stream.
 *
 * The wire algorithm and minizip-ng stream ABI are retained from the pinned
 * upstream mz_strm_pkcrypt.c snapshot.  The stream lifecycle is owned here so
 * all derived state is cleared before a stream is returned, closed, or freed.
 */

#include "mz.h"
#include "mz_crypt.h"
#include "mz_strm.h"
#include "mz_strm_pkcrypt.h"
#include "pengrid_encrypted_zip.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* Cleanup path categories are intentionally private to the test-only hooks. */
#define PENGRID_ZIPCRYPTO_CLEANUP_OPEN_FAILURE (1)
#define PENGRID_ZIPCRYPTO_CLEANUP_CLOSE        (2)
#define PENGRID_ZIPCRYPTO_CLEANUP_DELETE       (3)

/* The instrumentation is opt-in and has no work in the production default. */
static volatile int32_t pengrid_zipcrypto_test_enabled;
static volatile int32_t pengrid_zipcrypto_test_dirty;
static volatile int32_t pengrid_zipcrypto_test_zero;
static volatile uint32_t pengrid_zipcrypto_test_cleanups;
static volatile int32_t pengrid_zipcrypto_test_last_path;

typedef struct mz_stream_pkcrypt_s {
    mz_stream stream;
    int32_t mode;
    int32_t error;
    int16_t initialized;
    uint8_t buffer[UINT16_MAX];
    int64_t total_in;
    int64_t max_total_in;
    int64_t total_out;
    uint32_t keys[3]; /* keys defining the pseudo-random sequence */
    uint8_t verify1;
    uint8_t verify2;
    uint16_t verify_version;
    const char *password;
} mz_stream_pkcrypt;

static mz_stream_vtbl mz_stream_pkcrypt_vtbl = {
    mz_stream_pkcrypt_open,   mz_stream_pkcrypt_is_open,        mz_stream_pkcrypt_read,
    mz_stream_pkcrypt_write,  mz_stream_pkcrypt_tell,           mz_stream_pkcrypt_seek,
    mz_stream_pkcrypt_close,  mz_stream_pkcrypt_error,          mz_stream_pkcrypt_create,
    mz_stream_pkcrypt_delete, mz_stream_pkcrypt_get_prop_int64, mz_stream_pkcrypt_set_prop_int64};

static int pengrid_zipcrypto_bytes_nonzero(const uint8_t *bytes, size_t length) {
    size_t index;
    if (!bytes)
        return 0;
    for (index = 0; index < length; index += 1) {
        if (bytes[index] != 0)
            return 1;
    }
    return 0;
}

static int pengrid_zipcrypto_state_dirty(const mz_stream_pkcrypt *pkcrypt) {
    if (!pkcrypt)
        return 0;
    return pkcrypt->mode != 0 || pkcrypt->initialized != 0 || pkcrypt->error != 0 ||
           pkcrypt->total_in != 0 || pkcrypt->max_total_in != 0 || pkcrypt->total_out != 0 ||
           pkcrypt->keys[0] != 0 || pkcrypt->keys[1] != 0 || pkcrypt->keys[2] != 0 ||
           pkcrypt->verify1 != 0 || pkcrypt->verify2 != 0 || pkcrypt->verify_version != 0 ||
           pkcrypt->password != NULL ||
           pengrid_zipcrypto_bytes_nonzero(pkcrypt->buffer, sizeof(pkcrypt->buffer));
}

static int pengrid_zipcrypto_state_zero(const mz_stream_pkcrypt *pkcrypt, int32_t preserve_totals) {
    if (!pkcrypt)
        return 1;
    return pkcrypt->mode == 0 && pkcrypt->initialized == 0 && pkcrypt->error == 0 &&
           (preserve_totals ||
            (pkcrypt->total_in == 0 && pkcrypt->max_total_in == 0 && pkcrypt->total_out == 0)) &&
           pkcrypt->keys[0] == 0 && pkcrypt->keys[1] == 0 && pkcrypt->keys[2] == 0 &&
           pkcrypt->verify1 == 0 && pkcrypt->verify2 == 0 && pkcrypt->verify_version == 0 &&
           pkcrypt->password == NULL &&
           !pengrid_zipcrypto_bytes_nonzero(pkcrypt->buffer, sizeof(pkcrypt->buffer));
}

static void pengrid_zipcrypto_record_cleanup(
    const mz_stream_pkcrypt *pkcrypt,
    int32_t path,
    int32_t preserve_error,
    int32_t preserve_totals) {
    if (__sync_fetch_and_add(&pengrid_zipcrypto_test_enabled, 0) == 0)
        return;
    if (pengrid_zipcrypto_state_dirty(pkcrypt))
        __sync_lock_test_and_set(&pengrid_zipcrypto_test_dirty, 1);
    if (!preserve_error && pengrid_zipcrypto_state_zero(pkcrypt, preserve_totals))
        __sync_lock_test_and_set(&pengrid_zipcrypto_test_zero, 1);
    __sync_fetch_and_add(&pengrid_zipcrypto_test_cleanups, 1);
    __sync_lock_test_and_set(&pengrid_zipcrypto_test_last_path, path);
}

/* Preserve stream.vtbl and stream.base until close/delete no longer needs the
 * ABI linkage.  The borrowed password is cleared without dereferencing it. */
static void mz_stream_pkcrypt_clear_state(
    mz_stream_pkcrypt *pkcrypt,
    int32_t path,
    int32_t preserve_error,
    int32_t preserve_totals) {
    int32_t saved_error = 0;
    int64_t saved_total_in = 0;
    int64_t saved_max_total_in = 0;
    int64_t saved_total_out = 0;
    if (!pkcrypt)
        return;

    pengrid_zipcrypto_record_cleanup(pkcrypt, path, preserve_error, preserve_totals);
    if (preserve_error)
        saved_error = pkcrypt->error;
    if (preserve_totals) {
        saved_total_in = pkcrypt->total_in;
        saved_max_total_in = pkcrypt->max_total_in;
        saved_total_out = pkcrypt->total_out;
    }

    pengrid_secure_clear(&pkcrypt->mode, sizeof(pkcrypt->mode));
    pengrid_secure_clear(pkcrypt->keys, sizeof(pkcrypt->keys));
    pengrid_secure_clear(pkcrypt->buffer, sizeof(pkcrypt->buffer));
    pengrid_secure_clear(&pkcrypt->verify1, sizeof(pkcrypt->verify1));
    pengrid_secure_clear(&pkcrypt->verify2, sizeof(pkcrypt->verify2));
    pengrid_secure_clear(&pkcrypt->verify_version, sizeof(pkcrypt->verify_version));
    pengrid_secure_clear(&pkcrypt->total_in, sizeof(pkcrypt->total_in));
    pengrid_secure_clear(&pkcrypt->max_total_in, sizeof(pkcrypt->max_total_in));
    pengrid_secure_clear(&pkcrypt->total_out, sizeof(pkcrypt->total_out));
    pengrid_secure_clear(&pkcrypt->error, sizeof(pkcrypt->error));
    pkcrypt->initialized = 0;
    pkcrypt->password = NULL;
    if (preserve_error)
        pkcrypt->error = saved_error;
    if (preserve_totals) {
        pkcrypt->total_in = saved_total_in;
        pkcrypt->max_total_in = saved_max_total_in;
        pkcrypt->total_out = saved_total_out;
    }

    if (__sync_fetch_and_add(&pengrid_zipcrypto_test_enabled, 0) != 0 && !preserve_error &&
        pengrid_zipcrypto_state_zero(pkcrypt, preserve_totals))
        __sync_lock_test_and_set(&pengrid_zipcrypto_test_zero, 1);
}

#define mz_stream_pkcrypt_decode(strm, c) \
    (mz_stream_pkcrypt_update_keys(strm, c ^= mz_stream_pkcrypt_decrypt_byte(strm)))

#define mz_stream_pkcrypt_encode(strm, c, t) \
    (t = mz_stream_pkcrypt_decrypt_byte(strm), mz_stream_pkcrypt_update_keys(strm, (uint8_t)c), (uint8_t)(t ^ (c)))

static uint8_t mz_stream_pkcrypt_decrypt_byte(void *stream) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    unsigned temp;

    temp = pkcrypt->keys[2] | 2;
    return (uint8_t)(((temp * (temp ^ 1)) >> 8) & 0xff);
}

static uint8_t mz_stream_pkcrypt_update_keys(void *stream, uint8_t c) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    uint8_t buf = c;

    pkcrypt->keys[0] = (uint32_t)~mz_crypt_crc32_update(~pkcrypt->keys[0], &buf, 1);
    pkcrypt->keys[1] += pkcrypt->keys[0] & 0xff;
    pkcrypt->keys[1] *= 134775813L;
    pkcrypt->keys[1] += 1;
    buf = (uint8_t)(pkcrypt->keys[1] >> 24);
    pkcrypt->keys[2] = (uint32_t)~mz_crypt_crc32_update(~pkcrypt->keys[2], &buf, 1);
    return c;
}

static void mz_stream_pkcrypt_init_keys(void *stream, const char *password) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;

    pkcrypt->keys[0] = 305419896L;
    pkcrypt->keys[1] = 591751049L;
    pkcrypt->keys[2] = 878082192L;
    while (*password != 0) {
        mz_stream_pkcrypt_update_keys(stream, (uint8_t)*password);
        password += 1;
    }
}

int32_t mz_stream_pkcrypt_open(void *stream, const char *path, int32_t mode) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    uint16_t t = 0;
    int16_t i = 0;
    uint8_t verify1 = 0;
    uint8_t verify2 = 0;
    uint8_t header[MZ_PKCRYPT_HEADER_SIZE];
    const char *password = path;
    int32_t status = MZ_OK;

    pengrid_secure_clear(header, sizeof(header));
    if (!pkcrypt)
        return MZ_PARAM_ERROR;
    /* A stream is normally fresh, but preserve the configured borrowed
     * password until this open has consumed it. */
    pkcrypt->total_in = 0;
    pkcrypt->total_out = 0;
    pkcrypt->max_total_in = 0;
    pkcrypt->mode = 0;
    pkcrypt->error = 0;
    pkcrypt->initialized = 0;
    pengrid_secure_clear(pkcrypt->keys, sizeof(pkcrypt->keys));
    pengrid_secure_clear(pkcrypt->buffer, sizeof(pkcrypt->buffer));

    if (mz_stream_is_open(pkcrypt->stream.base) != MZ_OK) {
        status = MZ_OPEN_ERROR;
        goto cleanup;
    }
    if (!password)
        password = pkcrypt->password;
    if (!password) {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }

    mz_stream_pkcrypt_init_keys(stream, password);

    if (mode & MZ_OPEN_MODE_WRITE) {
        if (mz_crypt_rand(header, MZ_PKCRYPT_HEADER_SIZE - 2) != MZ_PKCRYPT_HEADER_SIZE - 2) {
            status = MZ_CRYPT_ERROR;
            goto cleanup;
        }
        for (i = 0; i < MZ_PKCRYPT_HEADER_SIZE - 2; i++)
            header[i] = mz_stream_pkcrypt_encode(stream, header[i], t);
        header[i++] = mz_stream_pkcrypt_encode(stream, pkcrypt->verify1, t);
        header[i++] = mz_stream_pkcrypt_encode(stream, pkcrypt->verify2, t);
        if (mz_stream_write(pkcrypt->stream.base, header, sizeof(header)) != sizeof(header)) {
            status = MZ_WRITE_ERROR;
            goto cleanup;
        }
        pkcrypt->total_out += MZ_PKCRYPT_HEADER_SIZE;
    } else if (mode & MZ_OPEN_MODE_READ) {
        if (mz_stream_read(pkcrypt->stream.base, header, sizeof(header)) != sizeof(header)) {
            status = MZ_READ_ERROR;
            goto cleanup;
        }
        for (i = 0; i < MZ_PKCRYPT_HEADER_SIZE - 2; i++)
            header[i] = mz_stream_pkcrypt_decode(stream, header[i]);
        verify1 = mz_stream_pkcrypt_decode(stream, header[i++]);
        verify2 = mz_stream_pkcrypt_decode(stream, header[i++]);
        if (verify2 != pkcrypt->verify2) {
            status = MZ_PASSWORD_ERROR;
            goto cleanup;
        }
        if (pkcrypt->verify_version < 2 && verify1 != pkcrypt->verify1) {
            status = MZ_PASSWORD_ERROR;
            goto cleanup;
        }
        pkcrypt->total_in += MZ_PKCRYPT_HEADER_SIZE;
    } else {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }

    pkcrypt->mode = mode;
    pkcrypt->initialized = 1;

cleanup:
    pengrid_secure_clear(header, sizeof(header));
    pengrid_secure_clear(&verify1, sizeof(verify1));
    pengrid_secure_clear(&verify2, sizeof(verify2));
    pengrid_secure_clear(&t, sizeof(t));
    if (status != MZ_OK) {
        pkcrypt->error = status;
        mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_OPEN_FAILURE, 0, 0);
    }
    return status;
}

int32_t mz_stream_pkcrypt_is_open(void *stream) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (!pkcrypt || !pkcrypt->initialized)
        return MZ_OPEN_ERROR;
    return MZ_OK;
}

int32_t mz_stream_pkcrypt_read(void *stream, void *buf, int32_t size) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    uint8_t *buf_ptr = (uint8_t *)buf;
    int32_t bytes_to_read = size;
    int32_t read = 0;
    int32_t i = 0;

    if (!pkcrypt || !buf || size < 0) {
        if (pkcrypt) {
            pkcrypt->error = MZ_PARAM_ERROR;
            mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_CLOSE, 1, 0);
        }
        return MZ_PARAM_ERROR;
    }
    if ((int64_t)bytes_to_read > (pkcrypt->max_total_in - pkcrypt->total_in))
        bytes_to_read = (int32_t)(pkcrypt->max_total_in - pkcrypt->total_in);
    if (bytes_to_read < 0)
        bytes_to_read = 0;
    read = mz_stream_read(pkcrypt->stream.base, buf, bytes_to_read);
    if (read < 0) {
        pkcrypt->error = read;
        mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_CLOSE, 1, 0);
        return read;
    }
    for (i = 0; i < read; i++)
        buf_ptr[i] = mz_stream_pkcrypt_decode(stream, buf_ptr[i]);
    if (read > 0)
        pkcrypt->total_in += read;
    return read;
}

int32_t mz_stream_pkcrypt_write(void *stream, const void *buf, int32_t size) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    const uint8_t *buf_ptr = (const uint8_t *)buf;
    int32_t bytes_to_write = 0;
    int32_t total_written = 0;
    int32_t written = 0;
    int32_t i = 0;
    uint16_t t = 0;

    if (!pkcrypt || !buf || size < 0) {
        if (pkcrypt) {
            pkcrypt->error = MZ_PARAM_ERROR;
            mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_CLOSE, 1, 0);
        }
        return MZ_PARAM_ERROR;
    }
    bytes_to_write = sizeof(pkcrypt->buffer);
    do {
        if (bytes_to_write > size - total_written)
            bytes_to_write = size - total_written;
        for (i = 0; i < bytes_to_write; i += 1) {
            pkcrypt->buffer[i] = mz_stream_pkcrypt_encode(stream, *buf_ptr, t);
            buf_ptr += 1;
        }
        written = mz_stream_write(pkcrypt->stream.base, pkcrypt->buffer, bytes_to_write);
        if (written < 0) {
            pkcrypt->error = written;
            mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_CLOSE, 1, 0);
            pengrid_secure_clear(&t, sizeof(t));
            return written;
        }
        total_written += written;
    } while (total_written < size && written > 0);
    pkcrypt->total_out += total_written;
    pengrid_secure_clear(&t, sizeof(t));
    return total_written;
}

int64_t mz_stream_pkcrypt_tell(void *stream) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    int64_t result;
    if (!pkcrypt)
        return MZ_TELL_ERROR;
    result = mz_stream_tell(pkcrypt->stream.base);
    if (result < 0) {
        pkcrypt->error = (int32_t)result;
        mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_CLOSE, 1, 0);
    }
    return result;
}

int32_t mz_stream_pkcrypt_seek(void *stream, int64_t offset, int32_t origin) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    int32_t result;
    if (!pkcrypt)
        return MZ_SEEK_ERROR;
    result = mz_stream_seek(pkcrypt->stream.base, offset, origin);
    if (result != MZ_OK) {
        pkcrypt->error = result;
        mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_CLOSE, 1, 0);
    }
    return result;
}

int32_t mz_stream_pkcrypt_close(void *stream) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (!pkcrypt)
        return MZ_PARAM_ERROR;
    mz_stream_pkcrypt_clear_state(
        pkcrypt,
        PENGRID_ZIPCRYPTO_CLEANUP_CLOSE,
        0,
        (pkcrypt->mode & MZ_OPEN_MODE_WRITE) != 0
    );
    return MZ_OK;
}

int32_t mz_stream_pkcrypt_error(void *stream) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    return pkcrypt ? pkcrypt->error : MZ_PARAM_ERROR;
}

void mz_stream_pkcrypt_set_password(void *stream, const char *password) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (pkcrypt)
        pkcrypt->password = password;
}

void mz_stream_pkcrypt_set_verify(void *stream, uint8_t verify1, uint8_t verify2, uint16_t version) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (!pkcrypt)
        return;
    pkcrypt->verify1 = verify1;
    pkcrypt->verify2 = verify2;
    pkcrypt->verify_version = version;
}

void mz_stream_pkcrypt_get_verify(void *stream, uint8_t *verify1, uint8_t *verify2, uint16_t *version) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (!pkcrypt || !verify1 || !verify2 || !version)
        return;
    *verify1 = pkcrypt->verify1;
    *verify2 = pkcrypt->verify2;
    *version = pkcrypt->verify_version;
}

int32_t mz_stream_pkcrypt_get_prop_int64(void *stream, int32_t prop, int64_t *value) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (!pkcrypt || !value)
        return MZ_PARAM_ERROR;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN:
        *value = pkcrypt->total_in;
        break;
    case MZ_STREAM_PROP_TOTAL_OUT:
        *value = pkcrypt->total_out;
        break;
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
        *value = pkcrypt->max_total_in;
        break;
    case MZ_STREAM_PROP_HEADER_SIZE:
        *value = MZ_PKCRYPT_HEADER_SIZE;
        break;
    case MZ_STREAM_PROP_FOOTER_SIZE:
        *value = 0;
        break;
    default:
        return MZ_EXIST_ERROR;
    }
    return MZ_OK;
}

int32_t mz_stream_pkcrypt_set_prop_int64(void *stream, int32_t prop, int64_t value) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)stream;
    if (!pkcrypt)
        return MZ_PARAM_ERROR;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
        pkcrypt->max_total_in = value;
        return MZ_OK;
    default:
        return MZ_EXIST_ERROR;
    }
}

void *mz_stream_pkcrypt_create(void) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)calloc(1, sizeof(mz_stream_pkcrypt));
    if (pkcrypt)
        pkcrypt->stream.vtbl = &mz_stream_pkcrypt_vtbl;
    return pkcrypt;
}

void mz_stream_pkcrypt_delete(void **stream) {
    mz_stream_pkcrypt *pkcrypt;
    if (!stream)
        return;
    pkcrypt = (mz_stream_pkcrypt *)*stream;
    if (pkcrypt) {
        mz_stream_pkcrypt_clear_state(pkcrypt, PENGRID_ZIPCRYPTO_CLEANUP_DELETE, 0, 0);
        /* The vtable/base linkage is no longer needed once the whole object
         * has been cleared, immediately before free. */
        pengrid_secure_clear(pkcrypt, sizeof(*pkcrypt));
        free(pkcrypt);
    }
    *stream = NULL;
}

void *mz_stream_pkcrypt_get_interface(void) {
    return (void *)&mz_stream_pkcrypt_vtbl;
}

/* Test-only hooks.  They expose only cleanup observability, never state. */
void pengrid_zipcrypto_test_reset(void) {
    __sync_lock_test_and_set(&pengrid_zipcrypto_test_dirty, 0);
    __sync_lock_test_and_set(&pengrid_zipcrypto_test_zero, 0);
    __sync_lock_test_and_set(&pengrid_zipcrypto_test_cleanups, 0);
    __sync_lock_test_and_set(&pengrid_zipcrypto_test_last_path, 0);
    __sync_lock_test_and_set(&pengrid_zipcrypto_test_enabled, 1);
}

int32_t pengrid_zipcrypto_test_dirty_observed(void) {
    return __sync_fetch_and_add(&pengrid_zipcrypto_test_dirty, 0);
}

int32_t pengrid_zipcrypto_test_zero_observed(void) {
    return __sync_fetch_and_add(&pengrid_zipcrypto_test_zero, 0);
}

uint32_t pengrid_zipcrypto_test_cleanup_count(void) {
    return __sync_fetch_and_add(&pengrid_zipcrypto_test_cleanups, 0);
}

int32_t pengrid_zipcrypto_test_last_cleanup_path(void) {
    return __sync_fetch_and_add(&pengrid_zipcrypto_test_last_path, 0);
}

static void pengrid_zipcrypto_test_prime(mz_stream_pkcrypt *pkcrypt) {
    size_t index;
    pkcrypt->error = MZ_INTERNAL_ERROR;
    pkcrypt->mode = MZ_OPEN_MODE_READ;
    pkcrypt->initialized = 1;
    pkcrypt->total_in = 17;
    pkcrypt->max_total_in = 31;
    pkcrypt->total_out = 23;
    pkcrypt->keys[0] = 0x12345678;
    pkcrypt->keys[1] = 0x23456789;
    pkcrypt->keys[2] = 0x34567890;
    pkcrypt->verify1 = 0xA1;
    pkcrypt->verify2 = 0xB2;
    pkcrypt->verify_version = 20;
    pkcrypt->password = "borrowed";
    for (index = 0; index < sizeof(pkcrypt->buffer); index += 1)
        pkcrypt->buffer[index] = 0xA5;
}

void pengrid_zipcrypto_test_prime_and_close_twice(void) {
    mz_stream_pkcrypt *pkcrypt = (mz_stream_pkcrypt *)mz_stream_pkcrypt_create();
    if (!pkcrypt)
        return;
    pengrid_zipcrypto_test_prime(pkcrypt);
    mz_stream_pkcrypt_close(pkcrypt);
    mz_stream_pkcrypt_close(pkcrypt);
    pengrid_secure_clear(pkcrypt, sizeof(*pkcrypt));
    free(pkcrypt);
}

void pengrid_zipcrypto_test_prime_and_delete_without_close(void) {
    void *stream = mz_stream_pkcrypt_create();
    if (!stream)
        return;
    pengrid_zipcrypto_test_prime((mz_stream_pkcrypt *)stream);
    mz_stream_pkcrypt_delete(&stream);
}
