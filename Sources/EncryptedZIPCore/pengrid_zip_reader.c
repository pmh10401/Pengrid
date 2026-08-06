#include "pengrid_zip_reader.h"

#include "mz.h"
#include "mz_os.h"
#include "mz_zip.h"
#include "pengrid_fd_stream.h"
#include "pengrid_root_writer.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define PENGRID_ZIP_READ_BUFFER_SIZE (64u * 1024u)
#define PENGRID_ZIP_MAX_LINK_TARGET (PATH_MAX)
#define PENGRID_ZIP_FLAG_STRONG_ENCRYPTION (1u << 6)

typedef struct pengrid_reader_entry_s {
    char *path;
    char *linkname;
    uint64_t uncompressed_size;
    uint64_t compressed_size;
    uint8_t is_directory;
    uint8_t is_symlink;
    uint8_t is_encrypted;
    uint8_t has_mode;
    mode_t mode;
    time_t modified_date;
} pengrid_reader_entry;

typedef struct pengrid_reader_entry_list_s {
    pengrid_reader_entry *entries;
    size_t count;
    size_t capacity;
    uint64_t total_uncompressed;
} pengrid_reader_entry_list;

static int32_t pengrid_reader_map_status(int32_t status, uint8_t extracting) {
    switch (status) {
    case MZ_OK:
    case MZ_END_OF_LIST:
        return PENGRID_ZIP_STATUS_OK;
    case MZ_MEM_ERROR:
    case MZ_INTERNAL_ERROR:
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    case MZ_PASSWORD_ERROR:
    case MZ_CRYPT_ERROR:
    case MZ_CRC_ERROR:
    case MZ_DATA_ERROR:
        return extracting ? PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE
                          : PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
    case MZ_SUPPORT_ERROR:
        return PENGRID_ZIP_STATUS_UNSUPPORTED_COMPRESSION;
    case MZ_PARAM_ERROR:
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    case MZ_READ_ERROR:
    case MZ_WRITE_ERROR:
    case MZ_SEEK_ERROR:
    case MZ_TELL_ERROR:
    case MZ_OPEN_ERROR:
    case MZ_CLOSE_ERROR:
    case MZ_STREAM_ERROR:
        return PENGRID_ZIP_STATUS_IO_ERROR;
    default:
        return extracting ? PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE
                          : PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
    }
}

static uint64_t pengrid_reader_max_entries(pengrid_zip_limits_t limits) {
    return limits.maximum_entry_count;
}

static int32_t pengrid_reader_validate_limits(pengrid_zip_limits_t limits) {
    if (limits.maximum_entry_count > SIZE_MAX ||
        limits.maximum_output_bytes > INT64_MAX ||
        limits.capacity_reserve_bytes > INT64_MAX)
        return PENGRID_ZIP_STATUS_OVERFLOW;
    return PENGRID_ZIP_STATUS_OK;
}

static void pengrid_reader_entry_list_destroy(pengrid_reader_entry_list *list) {
    if (!list)
        return;
    for (size_t index = 0; index < list->count; index++) {
        free(list->entries[index].path);
        free(list->entries[index].linkname);
    }
    free(list->entries);
    memset(list, 0, sizeof(*list));
}

static int32_t pengrid_reader_entry_list_append(
    pengrid_reader_entry_list *list,
    const char *path,
    const char *linkname,
    uint64_t uncompressed_size,
    uint64_t compressed_size,
    uint8_t is_directory,
    uint8_t is_symlink,
    uint8_t is_encrypted,
    uint8_t has_mode,
    mode_t mode,
    time_t modified_date) {
    pengrid_reader_entry *grown;
    if (list->count == list->capacity) {
        size_t next = list->capacity == 0 ? 32 : list->capacity * 2;
        if (next < list->capacity || next > SIZE_MAX / sizeof(*grown))
            return PENGRID_ZIP_STATUS_OVERFLOW;
        grown = (pengrid_reader_entry *)realloc(list->entries, next * sizeof(*grown));
        if (!grown)
            return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        list->entries = grown;
        list->capacity = next;
    }
    memset(&list->entries[list->count], 0, sizeof(list->entries[list->count]));
    list->entries[list->count].path = strdup(path);
    if (!list->entries[list->count].path)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    if (linkname && linkname[0] != '\0') {
        list->entries[list->count].linkname = strdup(linkname);
        if (!list->entries[list->count].linkname) {
            free(list->entries[list->count].path);
            list->entries[list->count].path = NULL;
            return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        }
    }
    list->entries[list->count].uncompressed_size = uncompressed_size;
    list->entries[list->count].compressed_size = compressed_size;
    list->entries[list->count].is_directory = is_directory;
    list->entries[list->count].is_symlink = is_symlink;
    list->entries[list->count].is_encrypted = is_encrypted;
    list->entries[list->count].has_mode = has_mode;
    list->entries[list->count].mode = mode;
    list->entries[list->count].modified_date = modified_date;
    list->count += 1;
    return PENGRID_ZIP_STATUS_OK;
}

static int pengrid_reader_entry_compare(const void *lhs, const void *rhs) {
    const pengrid_reader_entry *left = *(const pengrid_reader_entry *const *)lhs;
    const pengrid_reader_entry *right = *(const pengrid_reader_entry *const *)rhs;
    return strcmp(left->path, right->path);
}

static pengrid_reader_entry *pengrid_reader_find_sorted_entry(
    pengrid_reader_entry **sorted,
    size_t count,
    const char *path) {
    size_t lower = 0;
    size_t upper = count;
    while (lower < upper) {
        size_t middle = lower + (upper - lower) / 2;
        int comparison = strcmp(sorted[middle]->path, path);
        if (comparison == 0)
            return sorted[middle];
        if (comparison < 0)
            lower = middle + 1;
        else
            upper = middle;
    }
    return NULL;
}

static int32_t pengrid_reader_validate_topology(const pengrid_reader_entry_list *list) {
    pengrid_reader_entry **sorted;
    if (list->count == 0)
        return PENGRID_ZIP_STATUS_OK;
    sorted = (pengrid_reader_entry **)malloc(list->count * sizeof(*sorted));
    if (!sorted)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    for (size_t index = 0; index < list->count; index++)
        sorted[index] = &list->entries[index];
    qsort(sorted, list->count, sizeof(*sorted), pengrid_reader_entry_compare);
    for (size_t index = 1; index < list->count; index++) {
        const char *previous = sorted[index - 1]->path;
        const char *current = sorted[index]->path;
        size_t previous_length = strlen(previous);
        if (strcmp(previous, current) == 0) {
            free(sorted);
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
        if (strncmp(previous, current, previous_length) == 0 && current[previous_length] == '/') {
            if (!sorted[index - 1]->is_directory) {
                free(sorted);
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            }
        }
    }
    for (size_t index = 0; index < list->count; index++) {
        char *prefix = strdup(sorted[index]->path);
        char *slash;
        if (!prefix) {
            free(sorted);
            return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        }
        slash = strchr(prefix, '/');
        while (slash) {
            *slash = '\0';
            pengrid_reader_entry *ancestor = pengrid_reader_find_sorted_entry(sorted, list->count, prefix);
            if (ancestor && !ancestor->is_directory) {
                free(prefix);
                free(sorted);
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            }
            *slash = '/';
            slash = strchr(slash + 1, '/');
        }
        free(prefix);
    }
    free(sorted);
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_reader_copy_link_payload(
    void *zip,
    const mz_zip_file *info,
    char **target_out,
    uint64_t *payload_length_out,
    uint8_t extracting,
    const char *password) {
    uint8_t buffer[PENGRID_ZIP_MAX_LINK_TARGET + 1];
    int32_t status;
    int32_t read_count;
    size_t total = 0;

    if (!target_out || !payload_length_out)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    *target_out = NULL;
    *payload_length_out = 0;
    if (!extracting)
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    status = mz_zip_entry_read_open(zip, 0, password);
    if (status != MZ_OK)
        return pengrid_reader_map_status(status, extracting);
    while ((read_count = mz_zip_entry_read(zip, buffer + total,
                                           (int32_t)(sizeof(buffer) - 1 - total))) > 0) {
        total += (size_t)read_count;
        if (total >= sizeof(buffer) - 1) {
            mz_zip_entry_close(zip);
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
    }
    if (read_count < 0) {
        mz_zip_entry_close(zip);
        return pengrid_reader_map_status(read_count, extracting);
    }
    status = pengrid_reader_map_status(mz_zip_entry_close(zip), extracting);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    if (memchr(buffer, '\0', total) != NULL)
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    if (info->uncompressed_size < 0 ||
        (uint64_t)info->uncompressed_size > SIZE_MAX ||
        total != (size_t)info->uncompressed_size)
        return extracting ? PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE
                          : PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
    buffer[total] = '\0';
    *target_out = strdup((const char *)buffer);
    *payload_length_out = (uint64_t)total;
    return *target_out ? PENGRID_ZIP_STATUS_OK : PENGRID_ZIP_STATUS_INTERNAL_ERROR;
}

static char *pengrid_reader_link_parent(const char *path) {
    char *parent = strdup(path);
    char *slash;
    if (!parent)
        return NULL;
    slash = strrchr(parent, '/');
    if (slash)
        *slash = '\0';
    else
        parent[0] = '\0';
    return parent;
}

static int32_t pengrid_reader_validate_metadata_link(const mz_zip_file *info) {
    size_t offset = 0;

    if (!info || !info->extrafield || info->extrafield_size == 0)
        return PENGRID_ZIP_STATUS_OK;
    while (offset + 4 <= info->extrafield_size) {
        uint16_t field_type = (uint16_t)info->extrafield[offset] |
            (uint16_t)info->extrafield[offset + 1] << 8;
        uint16_t field_length = (uint16_t)info->extrafield[offset + 2] |
            (uint16_t)info->extrafield[offset + 3] << 8;
        size_t body = offset + 4;
        if ((size_t)field_length > info->extrafield_size - body)
            return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        if (field_type == MZ_ZIP_EXTENSION_UNIX1 && field_length >= 12) {
            const uint8_t *target = info->extrafield + body + 12;
            size_t target_length = field_length - 12;
            if (memchr(target, 0, target_length) != NULL)
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
        offset = body + field_length;
    }
    return offset == info->extrafield_size
        ? PENGRID_ZIP_STATUS_OK
        : PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
}

static int32_t pengrid_reader_collect_entries(
    void *zip,
    int root_fd,
    pengrid_zip_limits_t limits,
    pengrid_zip_inspection_t *inspection,
    pengrid_reader_entry_list *list,
    uint8_t extracting) {
    int32_t status;

    status = mz_zip_goto_first_entry(zip);
    if (status == MZ_END_OF_LIST)
        return PENGRID_ZIP_STATUS_OK;
    if (status != MZ_OK)
        return pengrid_reader_map_status(status, extracting);
    while (status == MZ_OK) {
        mz_zip_file *info = NULL;
        char *normalized = NULL;
        char *linkname = NULL;
        uint64_t uncompressed_size;
        uint64_t compressed_size;
        uint8_t is_directory;
        uint8_t is_symlink;
        uint8_t encrypted;
        uint32_t posix_attributes = 0;
        mode_t sanitized_mode = 0;
        uint8_t has_mode = 0;
        int32_t limit_status;

        if (list->count >= pengrid_reader_max_entries(limits))
            return PENGRID_ZIP_STATUS_OVERFLOW;
        if (mz_zip_entry_get_info(zip, &info) != MZ_OK || !info)
            return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        if (info->filename_size == 0 || !info->filename)
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        if (info->uncompressed_size < 0 || info->compressed_size < 0)
            return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        uncompressed_size = (uint64_t)info->uncompressed_size;
        compressed_size = (uint64_t)info->compressed_size;
        if (uncompressed_size > (uint64_t)INT64_MAX ||
            list->total_uncompressed > UINT64_MAX - uncompressed_size ||
            list->total_uncompressed > (uint64_t)INT64_MAX - uncompressed_size)
            return PENGRID_ZIP_STATUS_OVERFLOW;
        if (list->total_uncompressed + uncompressed_size > limits.maximum_output_bytes)
            return PENGRID_ZIP_STATUS_OUTPUT_BUDGET;

        encrypted = (info->flag & MZ_ZIP_FLAG_ENCRYPTED) != 0;
        if (encrypted && (info->flag & PENGRID_ZIP_FLAG_STRONG_ENCRYPTION))
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENCRYPTION;
        if (encrypted && info->aes_version != 0 &&
            (info->aes_strength < MZ_AES_STRENGTH_128 || info->aes_strength > MZ_AES_STRENGTH_256))
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENCRYPTION;
        if (info->compression_method != MZ_COMPRESS_METHOD_STORE &&
            info->compression_method != MZ_COMPRESS_METHOD_DEFLATE)
            return PENGRID_ZIP_STATUS_UNSUPPORTED_COMPRESSION;

        limit_status = pengrid_root_validate_path(
            root_fd,
            info->filename,
            (size_t)info->filename_size,
            &normalized
        );
        if (limit_status != PENGRID_ZIP_STATUS_OK)
            return limit_status;
        is_directory = mz_zip_attrib_is_dir(info->external_fa, info->version_madeby) == MZ_OK;
        if (!is_directory) {
            size_t filename_length = strlen(info->filename);
            if (filename_length > 0 &&
                (info->filename[filename_length - 1] == '/' || info->filename[filename_length - 1] == '\\'))
                is_directory = 1;
        }
        is_symlink = mz_zip_attrib_is_symlink(info->external_fa, info->version_madeby) == MZ_OK;
        if (is_directory && is_symlink) {
            free(normalized);
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
        if (is_directory && uncompressed_size != 0) {
            free(normalized);
            return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        }
        if (mz_zip_attrib_convert(
                (uint8_t)(info->version_madeby >> 8),
                info->external_fa,
                MZ_HOST_SYSTEM_UNIX,
                &posix_attributes
            ) == MZ_OK) {
            uint32_t mode_type = posix_attributes & S_IFMT;
            if (mode_type != 0 && mode_type != S_IFREG && mode_type != S_IFDIR && mode_type != S_IFLNK) {
                free(normalized);
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            }
            if (posix_attributes != 0) {
                sanitized_mode = (mode_t)(posix_attributes & 0777);
                has_mode = 1;
            }
        }
        if (is_symlink) {
            limit_status = pengrid_reader_validate_metadata_link(info);
            if (limit_status != PENGRID_ZIP_STATUS_OK) {
                free(normalized);
                return limit_status;
            }
            /* The central directory must carry the target. Preflight is a
               metadata-only gate and never opens the entry payload, including
               encrypted entries. */
            if (!info->linkname || info->linkname[0] == '\0') {
                free(normalized);
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            }
            linkname = strdup(info->linkname);
            if (!linkname) {
                free(normalized);
                return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
            }
            if (linkname) {
                char *parent_path = pengrid_reader_link_parent(normalized);
                if (!parent_path) {
                    free(normalized);
                    free(linkname);
                    return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
                }
                limit_status = pengrid_root_validate_link_target(
                    parent_path,
                    linkname,
                    strlen(linkname)
                );
                free(parent_path);
                if (limit_status != PENGRID_ZIP_STATUS_OK) {
                    free(normalized);
                    free(linkname);
                    return limit_status;
                }
            }
        }
        limit_status = pengrid_reader_entry_list_append(
            list,
            normalized,
            linkname,
            uncompressed_size,
            compressed_size,
            is_directory,
            is_symlink,
            encrypted,
            has_mode,
            sanitized_mode,
            info->modified_date
        );
        free(normalized);
        free(linkname);
        if (limit_status != PENGRID_ZIP_STATUS_OK)
            return limit_status;
        list->total_uncompressed += uncompressed_size;
        if (inspection) {
            if (list->count == UINT64_MAX)
                return PENGRID_ZIP_STATUS_OVERFLOW;
            inspection->entry_count += 1;
            inspection->total_uncompressed_bytes = list->total_uncompressed;
            if (encrypted)
                inspection->has_encrypted_entries = 1;
            if (info->aes_version != 0 && info->aes_strength > inspection->strongest_aes_strength)
                inspection->strongest_aes_strength = info->aes_strength;
        }
        status = mz_zip_goto_next_entry(zip);
        if (status == MZ_END_OF_LIST)
            break;
        if (status != MZ_OK)
            return pengrid_reader_map_status(status, extracting);
    }
    return pengrid_reader_validate_topology(list);
}

static int32_t pengrid_reader_probe_entries(
    int root_fd,
    const pengrid_reader_entry_list *list,
    pengrid_root_created_list *created,
    dev_t root_device,
    ino_t root_inode) {
    pengrid_reader_entry **sorted;
    int32_t status = PENGRID_ZIP_STATUS_OK;
    if (list->count == 0)
        return status;
    sorted = (pengrid_reader_entry **)malloc(list->count * sizeof(*sorted));
    if (!sorted)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    for (size_t index = 0; index < list->count; index++)
        sorted[index] = &list->entries[index];
    qsort(sorted, list->count, sizeof(*sorted), pengrid_reader_entry_compare);
    for (size_t index = 0; index < list->count; index++) {
        status = pengrid_root_verify_identity(root_fd, root_device, root_inode);
        if (status != PENGRID_ZIP_STATUS_OK)
            break;
        status = pengrid_root_probe_path(
            root_fd,
            sorted[index]->path,
            sorted[index]->is_directory,
            created
        );
        if (status != PENGRID_ZIP_STATUS_OK)
            break;
    }
    free(sorted);
    return status;
}

static int32_t pengrid_reader_open_zip(int archive_fd, void **stream_out, void **zip_out) {
    void *stream;
    void *zip;
    int32_t status;

    stream = pengrid_fd_stream_create(archive_fd);
    if (!stream)
        return PENGRID_ZIP_STATUS_IO_ERROR;
    zip = mz_zip_create();
    if (!zip) {
        mz_stream_delete(&stream);
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    }
    status = mz_zip_open(zip, stream, MZ_OPEN_MODE_READ);
    if (status != MZ_OK) {
        mz_zip_delete(&zip);
        mz_stream_delete(&stream);
        return pengrid_reader_map_status(status, 0);
    }
    *stream_out = stream;
    *zip_out = zip;
    return PENGRID_ZIP_STATUS_OK;
}

static void pengrid_reader_close_zip(void **stream, void **zip) {
    if (zip && *zip) {
        mz_zip_close(*zip);
        mz_zip_delete(zip);
    }
    if (stream && *stream)
        mz_stream_delete(stream);
}

static int32_t pengrid_reader_check_root_identity(int root_fd, dev_t device, ino_t inode) {
    struct stat information;
    if (fstat(root_fd, &information) != 0)
        return PENGRID_ZIP_STATUS_IO_ERROR;
    if (information.st_dev != device || information.st_ino != inode || !S_ISDIR(information.st_mode))
        return PENGRID_ZIP_STATUS_IDENTITY_CHANGED;
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_reader_check_capacity(
    int root_fd,
    uint64_t reserve,
    size_t chunk_length) {
    struct statfs filesystem;
    uint64_t available;
    uint64_t block_size;
    if (fstatfs(root_fd, &filesystem) != 0)
        return PENGRID_ZIP_STATUS_IO_ERROR;
    block_size = filesystem.f_bsize > 0 ? (uint64_t)filesystem.f_bsize : 1;
    if ((uint64_t)filesystem.f_bavail > UINT64_MAX / block_size)
        available = UINT64_MAX;
    else
        available = (uint64_t)filesystem.f_bavail * block_size;
    if (available < reserve || (uint64_t)chunk_length > available - reserve)
        return PENGRID_ZIP_STATUS_CAPACITY;
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_reader_write_all(int descriptor, const uint8_t *bytes, size_t length) {
    size_t written = 0;
    while (written < length) {
        ssize_t result = write(descriptor, bytes + written, length - written);
        if (result < 0 && errno == EINTR)
            continue;
        if (result <= 0)
            return PENGRID_ZIP_STATUS_IO_ERROR;
        written += (size_t)result;
    }
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_reader_extract_entries(
    void *zip,
    int root_fd,
    const char *password,
    pengrid_zip_limits_t limits,
    const pengrid_reader_entry_list *validated_entries,
    uint64_t total,
    pengrid_zip_progress_callback progress,
    void *progress_context,
    pengrid_root_created_list *created,
    dev_t root_device,
    ino_t root_inode) {
    uint8_t *buffer = NULL;
    uint64_t completed = 0;
    size_t entry_index = 0;
    int32_t status = PENGRID_ZIP_STATUS_OK;

    buffer = (uint8_t *)malloc(PENGRID_ZIP_READ_BUFFER_SIZE);
    if (!buffer)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    if (progress && progress(0, total, progress_context) != 0) {
        status = PENGRID_ZIP_STATUS_CANCELLED;
        goto cleanup;
    }
    {
        int32_t first_status = mz_zip_goto_first_entry(zip);
        if (first_status == MZ_END_OF_LIST) {
            status = PENGRID_ZIP_STATUS_OK;
            if (progress && progress(total, total, progress_context) != 0)
                status = PENGRID_ZIP_STATUS_CANCELLED;
            goto cleanup;
        }
        status = pengrid_reader_map_status(first_status, 1);
    }
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    while (1) {
        mz_zip_file *info = NULL;
        char *normalized = NULL;
        char *linkname = NULL;
        uint8_t is_directory;
        uint8_t is_symlink;
        uint64_t expected;
        uint64_t actual = 0;
        uint64_t link_payload_length = 0;
        int descriptor = -1;
        int32_t read_count;
        const pengrid_reader_entry *validated_entry;

        if (mz_zip_entry_get_info(zip, &info) != MZ_OK || !info) {
            status = PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
            goto cleanup;
        }
        if (!validated_entries || entry_index >= validated_entries->count) {
            status = PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
            goto cleanup;
        }
        validated_entry = &validated_entries->entries[entry_index];
        status = pengrid_root_validate_path(root_fd, info->filename,
                                            info->filename_size, &normalized);
        if (status != PENGRID_ZIP_STATUS_OK)
            goto entry_cleanup;
        if (strcmp(normalized, validated_entry->path) != 0) {
            status = PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
            goto entry_cleanup;
        }
        is_directory = mz_zip_attrib_is_dir(info->external_fa, info->version_madeby) == MZ_OK;
        if (!is_directory) {
            size_t filename_length = strlen(info->filename);
            if (filename_length > 0 &&
                (info->filename[filename_length - 1] == '/' || info->filename[filename_length - 1] == '\\'))
                is_directory = 1;
        }
        is_symlink = mz_zip_attrib_is_symlink(info->external_fa, info->version_madeby) == MZ_OK;
        expected = info->uncompressed_size < 0 ? UINT64_MAX : (uint64_t)info->uncompressed_size;
        if (is_directory && expected != 0) {
            status = PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
            goto entry_cleanup;
        }
        if (is_directory) {
            status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_cleanup;
            status = pengrid_root_create_directory(root_fd, normalized, created);
            goto entry_cleanup;
        }
        if (is_symlink) {
            status = pengrid_reader_copy_link_payload(
                zip, info, &linkname, &link_payload_length, 1, password
            );
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_cleanup;
            if (!linkname) {
                status = PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
                goto entry_cleanup;
            }
            if (!validated_entry->linkname || strcmp(linkname, validated_entry->linkname) != 0) {
                status = (info->flag & MZ_ZIP_FLAG_ENCRYPTED)
                    ? PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE
                    : PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
                goto entry_cleanup;
            }
            if (link_payload_length > total || completed > total - link_payload_length) {
                status = PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE;
                goto entry_cleanup;
            }
            status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_cleanup;
            completed += link_payload_length;
            if (progress && progress(completed, total, progress_context) != 0) {
                status = PENGRID_ZIP_STATUS_CANCELLED;
                goto entry_cleanup;
            }
            char *parent_path = pengrid_reader_link_parent(normalized);
            if (!parent_path) {
                status = PENGRID_ZIP_STATUS_INTERNAL_ERROR;
                goto entry_cleanup;
            }
            status = pengrid_root_validate_link_target(parent_path, linkname, strlen(linkname));
            free(parent_path);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_cleanup;
            status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_cleanup;
            status = pengrid_root_create_symlink(root_fd, normalized, linkname, strlen(linkname), created);
            goto entry_cleanup;
        }

        status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
        if (status != PENGRID_ZIP_STATUS_OK)
            goto entry_cleanup;
        status = pengrid_root_create_file(root_fd, normalized, created, &descriptor);
        if (status != PENGRID_ZIP_STATUS_OK)
            goto entry_cleanup;
        status = pengrid_reader_map_status(mz_zip_entry_read_open(zip, 0, password), 1);
        if (status != PENGRID_ZIP_STATUS_OK)
            goto entry_cleanup;
        while ((read_count = mz_zip_entry_read(zip, buffer, PENGRID_ZIP_READ_BUFFER_SIZE)) > 0) {
            if ((uint64_t)read_count > expected ||
                actual > expected - (uint64_t)read_count ||
                (uint64_t)read_count > total ||
                completed > total - (uint64_t)read_count) {
                status = PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE;
                goto entry_read_cleanup;
            }
            status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_read_cleanup;
            status = pengrid_reader_check_capacity(root_fd, limits.capacity_reserve_bytes, (size_t)read_count);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_read_cleanup;
            status = pengrid_reader_write_all(descriptor, buffer, (size_t)read_count);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto entry_read_cleanup;
            actual += (uint64_t)read_count;
            completed += (uint64_t)read_count;
            if (progress && progress(completed, total, progress_context) != 0) {
                status = PENGRID_ZIP_STATUS_CANCELLED;
                goto entry_read_cleanup;
            }
        }
        if (read_count < 0) {
            status = pengrid_reader_map_status(read_count, 1);
            goto entry_read_cleanup;
        }
        status = pengrid_reader_map_status(mz_zip_entry_close(zip), 1);
        if (status == PENGRID_ZIP_STATUS_OK && actual != expected) {
            status = (info->flag & MZ_ZIP_FLAG_ENCRYPTED)
                ? PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE
                : PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        }
        if (status == PENGRID_ZIP_STATUS_OK && validated_entry->has_mode) {
            status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
            if (status == PENGRID_ZIP_STATUS_OK)
                status = pengrid_root_apply_file_metadata(
                    descriptor, validated_entry->mode, validated_entry->modified_date
                );
        }
entry_read_cleanup:
        if (descriptor >= 0) {
            if (close(descriptor) != 0 && status == PENGRID_ZIP_STATUS_OK)
                status = PENGRID_ZIP_STATUS_IO_ERROR;
        }
entry_cleanup:
        free(normalized);
        free(linkname);
        if (status != PENGRID_ZIP_STATUS_OK)
            goto cleanup;
        entry_index += 1;
        int32_t next_status = mz_zip_goto_next_entry(zip);
        if (next_status == MZ_END_OF_LIST)
            break;
        status = pengrid_reader_map_status(next_status, 1);
        if (status != PENGRID_ZIP_STATUS_OK)
            goto cleanup;
    }
    if (completed != total)
        status = PENGRID_ZIP_STATUS_WRONG_PASSWORD_OR_DAMAGE;
    if (status == PENGRID_ZIP_STATUS_OK && validated_entries) {
        /* Apply directory metadata after all children so the final directory
           mtime is not changed by later child creation. */
        for (size_t index = validated_entries->count; index > 0; index--) {
            const pengrid_reader_entry *entry = &validated_entries->entries[index - 1];
            if (!entry->is_directory || !entry->has_mode)
                continue;
            status = pengrid_reader_check_root_identity(root_fd, root_device, root_inode);
            if (status != PENGRID_ZIP_STATUS_OK)
                break;
            status = pengrid_root_apply_directory_metadata(
                root_fd, entry->path, entry->mode, entry->modified_date
            );
            if (status != PENGRID_ZIP_STATUS_OK)
                break;
        }
    }
    if (status == PENGRID_ZIP_STATUS_OK && progress && progress(total, total, progress_context) != 0)
        status = PENGRID_ZIP_STATUS_CANCELLED;
cleanup:
    if (buffer) {
        pengrid_secure_clear(buffer, PENGRID_ZIP_READ_BUFFER_SIZE);
        free(buffer);
    }
    return status;
}

static int32_t pengrid_reader_preflight_owned(
    int archive_fd,
    int destination_probe_root_fd,
    pengrid_zip_limits_t limits,
    pengrid_zip_inspection_t *inspection,
    dev_t root_device,
    ino_t root_inode) {
    void *stream = NULL;
    void *zip = NULL;
    int32_t status;
    pengrid_reader_entry_list list;
    pengrid_root_created_list created;

    memset(&list, 0, sizeof(list));
    memset(&created, 0, sizeof(created));
    if (archive_fd < 0 || destination_probe_root_fd < 0 || !inspection)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    memset(inspection, 0, sizeof(*inspection));
    status = pengrid_root_verify_identity(destination_probe_root_fd, root_device, root_inode);
    if (status == PENGRID_ZIP_STATUS_OK)
        status = pengrid_root_is_empty(destination_probe_root_fd);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_reader_open_zip(archive_fd, &stream, &zip);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_reader_collect_entries(
        zip,
        destination_probe_root_fd,
        limits,
        inspection,
        &list,
        0
    );
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_reader_probe_entries(
        destination_probe_root_fd, &list, &created, root_device, root_inode
    );
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_root_verify_identity(destination_probe_root_fd, root_device, root_inode);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_root_cleanup(destination_probe_root_fd, &created);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_root_verify_identity(destination_probe_root_fd, root_device, root_inode);
    if (status == PENGRID_ZIP_STATUS_OK)
        status = pengrid_root_is_empty(destination_probe_root_fd);
cleanup:
    if (status != PENGRID_ZIP_STATUS_OK) {
        int32_t identity_status = pengrid_root_verify_identity(
            destination_probe_root_fd, root_device, root_inode
        );
        int32_t cleanup_status = identity_status == PENGRID_ZIP_STATUS_OK
            ? pengrid_root_cleanup(destination_probe_root_fd, &created)
            : PENGRID_ZIP_STATUS_RECOVERY_REQUIRED;
        if (cleanup_status != PENGRID_ZIP_STATUS_OK)
            status = PENGRID_ZIP_STATUS_RECOVERY_REQUIRED;
    }
    pengrid_reader_entry_list_destroy(&list);
    pengrid_reader_close_zip(&stream, &zip);
    return status;
}

int32_t pengrid_zip_preflight_fd(
    int archive_fd,
    int destination_probe_root_fd,
    pengrid_zip_limits_t limits,
    pengrid_zip_inspection_t *inspection) {
    int owned_archive = -1;
    int owned_root = -1;
    struct stat root_information;
    int32_t status;

    if (archive_fd < 0 || destination_probe_root_fd < 0 || !inspection)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    status = pengrid_reader_validate_limits(limits);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    owned_archive = pengrid_root_duplicate_fd(archive_fd);
    owned_root = pengrid_root_duplicate_fd(destination_probe_root_fd);
    if (owned_archive < 0 || owned_root < 0) {
        if (owned_archive >= 0) close(owned_archive);
        if (owned_root >= 0) close(owned_root);
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    if (fstat(owned_root, &root_information) != 0 || !S_ISDIR(root_information.st_mode)) {
        close(owned_archive);
        close(owned_root);
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    }
    status = pengrid_reader_preflight_owned(
        owned_archive,
        owned_root,
        limits,
        inspection,
        root_information.st_dev,
        root_information.st_ino
    );
    if (owned_archive >= 0) close(owned_archive);
    if (owned_root >= 0) close(owned_root);
    return status;
}

int32_t pengrid_zip_extract(
    int archive_fd,
    int destination_root_fd,
    const uint8_t *password,
    size_t password_length,
    pengrid_zip_limits_t limits,
    pengrid_zip_progress_callback progress,
    void *progress_context) {
    pengrid_zip_inspection_t inspection;
    pengrid_root_created_list created;
    pengrid_reader_entry_list validated_entries;
    void *stream = NULL;
    void *zip = NULL;
    uint8_t *password_copy = NULL;
    struct stat root_information;
    int owned_archive = -1;
    int owned_root = -1;
    int32_t status;

    memset(&created, 0, sizeof(created));
    memset(&validated_entries, 0, sizeof(validated_entries));
    memset(&root_information, 0, sizeof(root_information));
    if (archive_fd < 0 || destination_root_fd < 0 || !password || password_length < 1 || password_length > 1024)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    for (size_t index = 0; index < password_length; index++) {
        if (password[index] == 0)
            return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    }
    status = pengrid_reader_validate_limits(limits);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    owned_archive = pengrid_root_duplicate_fd(archive_fd);
    owned_root = pengrid_root_duplicate_fd(destination_root_fd);
    if (owned_archive < 0 || owned_root < 0) {
        if (owned_archive >= 0) close(owned_archive);
        if (owned_root >= 0) close(owned_root);
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    if (fstat(owned_root, &root_information) != 0 || !S_ISDIR(root_information.st_mode)) {
        status = PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
        goto cleanup;
    }
    status = pengrid_root_verify_identity(owned_root, root_information.st_dev, root_information.st_ino);
    if (status == PENGRID_ZIP_STATUS_OK)
        status = pengrid_root_is_empty(owned_root);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_reader_preflight_owned(
        owned_archive,
        owned_root,
        limits,
        &inspection,
        root_information.st_dev,
        root_information.st_ino
    );
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_root_verify_identity(owned_root, root_information.st_dev, root_information.st_ino);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_root_is_empty(owned_root);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    password_copy = (uint8_t *)malloc(password_length + 1);
    if (!password_copy) {
        status = PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        goto cleanup;
    }
    memcpy(password_copy, password, password_length);
    password_copy[password_length] = '\0';
    status = pengrid_reader_open_zip(owned_archive, &stream, &zip);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    status = pengrid_reader_collect_entries(
        zip, owned_root, limits, NULL, &validated_entries, 1
    );
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    if (validated_entries.total_uncompressed != inspection.total_uncompressed_bytes) {
        status = PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
        goto cleanup;
    }
    status = pengrid_reader_extract_entries(
        zip,
        owned_root,
        (const char *)password_copy,
        limits,
        &validated_entries,
        inspection.total_uncompressed_bytes,
        progress,
        progress_context,
        &created,
        root_information.st_dev,
        root_information.st_ino
    );
cleanup:
    pengrid_reader_close_zip(&stream, &zip);
    if (status != PENGRID_ZIP_STATUS_OK) {
        int32_t identity_status = pengrid_root_verify_identity(
            owned_root, root_information.st_dev, root_information.st_ino
        );
        int32_t cleanup_status = identity_status == PENGRID_ZIP_STATUS_OK
            ? pengrid_root_cleanup(owned_root, &created)
            : PENGRID_ZIP_STATUS_RECOVERY_REQUIRED;
        if (cleanup_status != PENGRID_ZIP_STATUS_OK)
            status = PENGRID_ZIP_STATUS_RECOVERY_REQUIRED;
    } else {
        pengrid_root_created_list_destroy(&created);
    }
    if (password_copy) {
        pengrid_secure_clear(password_copy, password_length + 1);
        free(password_copy);
    }
    pengrid_reader_entry_list_destroy(&validated_entries);
    if (owned_archive >= 0) close(owned_archive);
    if (owned_root >= 0) close(owned_root);
    return status;
}
