/* pengrid_strm_wzaes.c -- Audited Pengrid WinZip AES stream replacement.
 *
 * The implementation follows minizip-ng's stream ABI and wire format while
 * extending the password bound to 256 bytes and clearing transient and
 * persistent key material on every exit path.
 */

#include "mz.h"
#include "mz_crypt.h"
#include "mz_strm.h"
#include "mz_strm_wzaes.h"
#include "pengrid_encrypted_zip.h"

#include <string.h>

#define MZ_AES_KEY_LENGTH(STRENGTH)  (8 * (STRENGTH & 3) + 8)
#define MZ_AES_KEYING_ITERATIONS     (1000)
#define MZ_AES_SALT_LENGTH(STRENGTH) (4 * (STRENGTH & 3) + 4)
#define MZ_AES_SALT_LENGTH_MAX       (16)
#define MZ_AES_PW_LENGTH_MAX         (256)
#define MZ_AES_PW_VERIFY_SIZE        (2)
#define MZ_AES_AUTHCODE_SIZE         (10)

typedef struct mz_stream_wzaes_s {
    mz_stream stream;
    int32_t mode;
    int32_t error;
    int16_t initialized;
    uint8_t buffer[UINT16_MAX];
    int64_t total_in;
    int64_t max_total_in;
    int64_t total_out;
    uint8_t strength;
    const char *password;
    void *aes;
    uint32_t crypt_pos;
    uint8_t crypt_block[MZ_AES_BLOCK_SIZE];
    void *hmac;
    uint8_t nonce[MZ_AES_BLOCK_SIZE];
    uint8_t footer_checked;
    uint8_t hmac_finalized;
} mz_stream_wzaes;

static mz_stream_vtbl mz_stream_wzaes_vtbl = {
    mz_stream_wzaes_open,   mz_stream_wzaes_is_open, mz_stream_wzaes_read,           mz_stream_wzaes_write,
    mz_stream_wzaes_tell,   mz_stream_wzaes_seek,    mz_stream_wzaes_close,          mz_stream_wzaes_error,
    mz_stream_wzaes_create, mz_stream_wzaes_delete,  mz_stream_wzaes_get_prop_int64, mz_stream_wzaes_set_prop_int64};

static void mz_stream_wzaes_clear_state(mz_stream_wzaes *wzaes) {
    if (!wzaes)
        return;
    if (wzaes->aes)
        mz_crypt_aes_reset(wzaes->aes);
    if (wzaes->hmac)
        mz_crypt_hmac_reset(wzaes->hmac);
    pengrid_secure_clear(wzaes->buffer, sizeof(wzaes->buffer));
    pengrid_secure_clear(wzaes->crypt_block, sizeof(wzaes->crypt_block));
    pengrid_secure_clear(wzaes->nonce, sizeof(wzaes->nonce));
    wzaes->crypt_pos = 0;
    wzaes->mode = 0;
    wzaes->initialized = 0;
    wzaes->footer_checked = 0;
    wzaes->hmac_finalized = 0;
}

int32_t mz_stream_wzaes_open(void *stream, const char *path, int32_t mode) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    uint16_t salt_length = 0;
    uint16_t password_length = 0;
    uint16_t key_length = 0;
    uint8_t kbuf[2 * MZ_AES_KEY_LENGTH_MAX + MZ_AES_PW_VERIFY_SIZE];
    uint8_t verify[MZ_AES_PW_VERIFY_SIZE];
    uint8_t verify_expected[MZ_AES_PW_VERIFY_SIZE];
    uint8_t salt_value[MZ_AES_SALT_LENGTH_MAX];
    const char *password = path;
    int32_t status = MZ_OK;

    pengrid_secure_clear(kbuf, sizeof(kbuf));
    pengrid_secure_clear(verify, sizeof(verify));
    pengrid_secure_clear(verify_expected, sizeof(verify_expected));
    pengrid_secure_clear(salt_value, sizeof(salt_value));
    if (!wzaes)
        return MZ_PARAM_ERROR;
    wzaes->total_in = 0;
    wzaes->total_out = 0;
    wzaes->initialized = 0;
    wzaes->footer_checked = 0;
    wzaes->hmac_finalized = 0;

    if (mz_stream_is_open(wzaes->stream.base) != MZ_OK) {
        status = MZ_OPEN_ERROR;
        goto cleanup;
    }
    if (!password)
        password = wzaes->password;
    if (!password) {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }
    if (strlen(password) > MZ_AES_PW_LENGTH_MAX) {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }
    password_length = (uint16_t)strlen(password);
    if (password_length > MZ_AES_PW_LENGTH_MAX) {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }
    if (wzaes->strength < 1 || wzaes->strength > 3) {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }

    key_length = (uint16_t)MZ_AES_KEY_LENGTH(wzaes->strength);
    salt_length = (uint16_t)MZ_AES_SALT_LENGTH(wzaes->strength);
    if (mode & MZ_OPEN_MODE_WRITE) {
        if (mz_crypt_rand(salt_value, salt_length) != salt_length) {
            status = MZ_INTERNAL_ERROR;
            goto cleanup;
        }
    } else if (mode & MZ_OPEN_MODE_READ) {
        if (mz_stream_read(wzaes->stream.base, salt_value, salt_length) != salt_length) {
            status = MZ_READ_ERROR;
            goto cleanup;
        }
    }

    status = mz_crypt_pbkdf2((const uint8_t *)password, password_length, salt_value, salt_length,
                             MZ_AES_KEYING_ITERATIONS, kbuf,
                             (uint16_t)(2 * key_length + MZ_AES_PW_VERIFY_SIZE));
    if (status != MZ_OK)
        goto cleanup;

    wzaes->crypt_pos = MZ_AES_BLOCK_SIZE;
    pengrid_secure_clear(wzaes->nonce, sizeof(wzaes->nonce));
    mz_crypt_aes_reset(wzaes->aes);
    status = mz_crypt_aes_set_encrypt_key(wzaes->aes, kbuf, key_length, NULL, 0);
    if (status != MZ_OK)
        goto cleanup;
    mz_crypt_hmac_reset(wzaes->hmac);
    mz_crypt_hmac_set_algorithm(wzaes->hmac, MZ_HASH_SHA1);
    status = mz_crypt_hmac_init(wzaes->hmac, kbuf + key_length, key_length);
    if (status != MZ_OK)
        goto cleanup;
    memcpy(verify, kbuf + (2 * key_length), MZ_AES_PW_VERIFY_SIZE);

    if (mode & MZ_OPEN_MODE_WRITE) {
        if (mz_stream_write(wzaes->stream.base, salt_value, salt_length) != salt_length) {
            status = MZ_WRITE_ERROR;
            goto cleanup;
        }
        wzaes->total_out += salt_length;
        if (mz_stream_write(wzaes->stream.base, verify, MZ_AES_PW_VERIFY_SIZE) != MZ_AES_PW_VERIFY_SIZE) {
            status = MZ_WRITE_ERROR;
            goto cleanup;
        }
        wzaes->total_out += MZ_AES_PW_VERIFY_SIZE;
    } else if (mode & MZ_OPEN_MODE_READ) {
        wzaes->total_in += salt_length;
        if (mz_stream_read(wzaes->stream.base, verify_expected, MZ_AES_PW_VERIFY_SIZE) != MZ_AES_PW_VERIFY_SIZE) {
            status = MZ_READ_ERROR;
            goto cleanup;
        }
        wzaes->total_in += MZ_AES_PW_VERIFY_SIZE;
        if (memcmp(verify_expected, verify, MZ_AES_PW_VERIFY_SIZE) != 0) {
            status = MZ_PASSWORD_ERROR;
            goto cleanup;
        }
    }

    wzaes->mode = mode;
    wzaes->initialized = 1;

cleanup:
    if (status != MZ_OK)
        mz_stream_wzaes_clear_state(wzaes);
    pengrid_secure_clear(kbuf, sizeof(kbuf));
    pengrid_secure_clear(verify, sizeof(verify));
    pengrid_secure_clear(verify_expected, sizeof(verify_expected));
    pengrid_secure_clear(salt_value, sizeof(salt_value));
    return status;
}

int32_t mz_stream_wzaes_is_open(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (!wzaes || !wzaes->initialized)
        return MZ_OPEN_ERROR;
    return MZ_OK;
}

static int32_t mz_stream_wzaes_ctr_encrypt(void *stream, uint8_t *buf, int32_t size) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    uint32_t pos = wzaes->crypt_pos;
    uint32_t i = 0;

    while (i < (uint32_t)size) {
        if (pos == MZ_AES_BLOCK_SIZE) {
            uint32_t j = 0;
            while (j < 8 && !++wzaes->nonce[j])
                j += 1;
            memcpy(wzaes->crypt_block, wzaes->nonce, MZ_AES_BLOCK_SIZE);
            mz_crypt_aes_encrypt(wzaes->aes, NULL, 0, wzaes->crypt_block, sizeof(wzaes->crypt_block));
            pos = 0;
        }
        buf[i++] ^= wzaes->crypt_block[pos++];
    }
    wzaes->crypt_pos = pos;
    return MZ_OK;
}

int32_t mz_stream_wzaes_read(void *stream, void *buf, int32_t size) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    int64_t max_total_in;
    int32_t bytes_to_read = size;
    int32_t read;

    if (!wzaes || !buf || size < 0)
        return MZ_PARAM_ERROR;
    max_total_in = wzaes->max_total_in - MZ_AES_FOOTER_SIZE;
    if ((int64_t)bytes_to_read > (max_total_in - wzaes->total_in))
        bytes_to_read = (int32_t)(max_total_in - wzaes->total_in);
    if (bytes_to_read <= 0) {
        uint8_t expected_hash[MZ_AES_AUTHCODE_SIZE];
        uint8_t computed_hash[MZ_HASH_SHA1_SIZE];
        int32_t status = MZ_OK;
        if ((wzaes->mode & MZ_OPEN_MODE_READ) == 0 || wzaes->footer_checked)
            return 0;
        pengrid_secure_clear(expected_hash, sizeof(expected_hash));
        pengrid_secure_clear(computed_hash, sizeof(computed_hash));
        if (mz_stream_read(wzaes->stream.base, expected_hash, MZ_AES_AUTHCODE_SIZE) != MZ_AES_AUTHCODE_SIZE) {
            status = MZ_READ_ERROR;
        } else if (!wzaes->hmac_finalized) {
            if (mz_crypt_hmac_end(wzaes->hmac, computed_hash, sizeof(computed_hash)) != MZ_OK)
                status = MZ_CRC_ERROR;
            else if (memcmp(computed_hash, expected_hash, MZ_AES_AUTHCODE_SIZE) != 0)
                status = MZ_CRC_ERROR;
            wzaes->hmac_finalized = 1;
        }
        wzaes->total_in += MZ_AES_AUTHCODE_SIZE;
        wzaes->footer_checked = 1;
        pengrid_secure_clear(expected_hash, sizeof(expected_hash));
        pengrid_secure_clear(computed_hash, sizeof(computed_hash));
        if (status != MZ_OK) {
            wzaes->error = status;
            return status;
        }
        return 0;
    }
    read = mz_stream_read(wzaes->stream.base, buf, bytes_to_read);
    if (read > 0) {
        mz_crypt_hmac_update(wzaes->hmac, (uint8_t *)buf, read);
        mz_stream_wzaes_ctr_encrypt(stream, (uint8_t *)buf, read);
        wzaes->total_in += read;
    }
    return read;
}

int32_t mz_stream_wzaes_write(void *stream, const void *buf, int32_t size) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    const uint8_t *buf_ptr = (const uint8_t *)buf;
    int32_t bytes_to_write;
    int32_t total_written = 0;
    int32_t written = 0;

    if (!wzaes || !buf || size < 0)
        return MZ_PARAM_ERROR;
    bytes_to_write = sizeof(wzaes->buffer);
    do {
        if (bytes_to_write > (size - total_written))
            bytes_to_write = (size - total_written);
        memcpy(wzaes->buffer, buf_ptr, bytes_to_write);
        buf_ptr += bytes_to_write;
        mz_stream_wzaes_ctr_encrypt(stream, wzaes->buffer, bytes_to_write);
        mz_crypt_hmac_update(wzaes->hmac, wzaes->buffer, bytes_to_write);
        written = mz_stream_write(wzaes->stream.base, wzaes->buffer, bytes_to_write);
        if (written < 0)
            return written;
        total_written += written;
    } while (total_written < size && written > 0);
    wzaes->total_out += total_written;
    return total_written;
}

int64_t mz_stream_wzaes_tell(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    return wzaes ? mz_stream_tell(wzaes->stream.base) : MZ_TELL_ERROR;
}

int32_t mz_stream_wzaes_seek(void *stream, int64_t offset, int32_t origin) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    return wzaes ? mz_stream_seek(wzaes->stream.base, offset, origin) : MZ_SEEK_ERROR;
}

int32_t mz_stream_wzaes_close(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    uint8_t expected_hash[MZ_AES_AUTHCODE_SIZE];
    uint8_t computed_hash[MZ_HASH_SHA1_SIZE];
    int32_t status = MZ_OK;

    pengrid_secure_clear(expected_hash, sizeof(expected_hash));
    pengrid_secure_clear(computed_hash, sizeof(computed_hash));
    if (!wzaes) {
        status = MZ_PARAM_ERROR;
        goto cleanup;
    }
    if (!wzaes->hmac_finalized) {
        if (mz_crypt_hmac_end(wzaes->hmac, computed_hash, sizeof(computed_hash)) != MZ_OK) {
            status = MZ_CRC_ERROR;
            goto cleanup;
        }
        wzaes->hmac_finalized = 1;
    }
    if (wzaes->mode & MZ_OPEN_MODE_WRITE) {
        if (mz_stream_write(wzaes->stream.base, computed_hash, MZ_AES_AUTHCODE_SIZE) != MZ_AES_AUTHCODE_SIZE) {
            status = MZ_WRITE_ERROR;
            goto cleanup;
        }
        wzaes->total_out += MZ_AES_AUTHCODE_SIZE;
    } else if (wzaes->mode & MZ_OPEN_MODE_READ) {
        if (!wzaes->footer_checked && mz_stream_read(wzaes->stream.base, expected_hash, MZ_AES_AUTHCODE_SIZE) != MZ_AES_AUTHCODE_SIZE) {
            status = MZ_READ_ERROR;
            goto cleanup;
        }
        if (!wzaes->footer_checked)
            wzaes->total_in += MZ_AES_AUTHCODE_SIZE;
        if (!wzaes->footer_checked && memcmp(computed_hash, expected_hash, MZ_AES_AUTHCODE_SIZE) != 0)
            status = MZ_CRC_ERROR;
        wzaes->footer_checked = 1;
    }

cleanup:
    pengrid_secure_clear(expected_hash, sizeof(expected_hash));
    pengrid_secure_clear(computed_hash, sizeof(computed_hash));
    mz_stream_wzaes_clear_state(wzaes);
    return status;
}

int32_t mz_stream_wzaes_error(void *stream) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    return wzaes ? wzaes->error : MZ_PARAM_ERROR;
}

void mz_stream_wzaes_set_password(void *stream, const char *password) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (wzaes)
        wzaes->password = password;
}

void mz_stream_wzaes_set_strength(void *stream, uint8_t strength) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (wzaes)
        wzaes->strength = strength;
}

int32_t mz_stream_wzaes_get_prop_int64(void *stream, int32_t prop, int64_t *value) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (!wzaes || !value)
        return MZ_PARAM_ERROR;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN:
        *value = wzaes->total_in;
        break;
    case MZ_STREAM_PROP_TOTAL_OUT:
        *value = wzaes->total_out;
        break;
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
        *value = wzaes->max_total_in;
        break;
    case MZ_STREAM_PROP_HEADER_SIZE:
        *value = MZ_AES_SALT_LENGTH((int64_t)wzaes->strength) + MZ_AES_PW_VERIFY_SIZE;
        break;
    case MZ_STREAM_PROP_FOOTER_SIZE:
        *value = MZ_AES_AUTHCODE_SIZE;
        break;
    default:
        return MZ_EXIST_ERROR;
    }
    return MZ_OK;
}

int32_t mz_stream_wzaes_set_prop_int64(void *stream, int32_t prop, int64_t value) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)stream;
    if (!wzaes)
        return MZ_PARAM_ERROR;
    if (prop == MZ_STREAM_PROP_TOTAL_IN_MAX) {
        wzaes->max_total_in = value;
        return MZ_OK;
    }
    return MZ_EXIST_ERROR;
}

void *mz_stream_wzaes_create(void) {
    mz_stream_wzaes *wzaes = (mz_stream_wzaes *)calloc(1, sizeof(mz_stream_wzaes));
    if (!wzaes)
        return NULL;
    wzaes->stream.vtbl = &mz_stream_wzaes_vtbl;
    wzaes->strength = MZ_AES_STRENGTH_256;
    wzaes->hmac = mz_crypt_hmac_create();
    if (!wzaes->hmac) {
        pengrid_secure_clear(wzaes, sizeof(*wzaes));
        free(wzaes);
        return NULL;
    }
    wzaes->aes = mz_crypt_aes_create();
    if (!wzaes->aes) {
        mz_crypt_hmac_delete(&wzaes->hmac);
        pengrid_secure_clear(wzaes, sizeof(*wzaes));
        free(wzaes);
        return NULL;
    }
    return wzaes;
}

void mz_stream_wzaes_delete(void **stream) {
    mz_stream_wzaes *wzaes;
    if (!stream)
        return;
    wzaes = (mz_stream_wzaes *)*stream;
    if (wzaes) {
        mz_stream_wzaes_clear_state(wzaes);
        mz_crypt_aes_delete(&wzaes->aes);
        mz_crypt_hmac_delete(&wzaes->hmac);
        pengrid_secure_clear(wzaes, sizeof(*wzaes));
        free(wzaes);
    }
    *stream = NULL;
}

void *mz_stream_wzaes_get_interface(void) {
    return (void *)&mz_stream_wzaes_vtbl;
}
