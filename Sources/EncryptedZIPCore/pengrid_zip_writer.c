#include "pengrid_zip_writer.h"

#include "mz.h"
#include "mz_os.h"
#include "mz_strm.h"
#include "mz_zip.h"
#include "mz_zip_rw.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define PENGRID_ZIP_MAX_PASSWORD_LENGTH (256u)
#define PENGRID_ZIP_WRITE_BUFFER_SIZE (64u * 1024u)

static volatile int32_t pengrid_zip_override_regular_size_count;
static volatile uint64_t pengrid_zip_override_regular_size;

/* Test-only native cancellation checkpoint.  The fast-path flag keeps the
 * default (unarmed) writer free of mutex work; the hook is otherwise a
 * one-shot, process-local gate used by integration tests. */
static volatile int32_t pengrid_zip_progress_gate_armed;
static int32_t pengrid_zip_progress_gate_entered;
static int32_t pengrid_zip_progress_gate_released;
static int32_t pengrid_zip_progress_gate_consumed;
static pthread_mutex_t pengrid_zip_progress_gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pengrid_zip_progress_gate_condition = PTHREAD_COND_INITIALIZER;

void pengrid_zip_test_override_next_regular_size(uint64_t size) {
    __sync_lock_test_and_set(&pengrid_zip_override_regular_size, size);
    __sync_fetch_and_add(&pengrid_zip_override_regular_size_count, 1);
}

void pengrid_zip_test_arm_first_positive_progress_checkpoint(void) {
    pthread_mutex_lock(&pengrid_zip_progress_gate_mutex);
    pengrid_zip_progress_gate_entered = 0;
    pengrid_zip_progress_gate_released = 0;
    pengrid_zip_progress_gate_consumed = 0;
    __sync_lock_test_and_set(&pengrid_zip_progress_gate_armed, 1);
    pthread_cond_broadcast(&pengrid_zip_progress_gate_condition);
    pthread_mutex_unlock(&pengrid_zip_progress_gate_mutex);
}

void pengrid_zip_test_release_first_positive_progress_checkpoint(void) {
    pthread_mutex_lock(&pengrid_zip_progress_gate_mutex);
    pengrid_zip_progress_gate_released = 1;
    pthread_cond_broadcast(&pengrid_zip_progress_gate_condition);
    pthread_mutex_unlock(&pengrid_zip_progress_gate_mutex);
}

void pengrid_zip_test_clear_first_positive_progress_checkpoint(void) {
    pthread_mutex_lock(&pengrid_zip_progress_gate_mutex);
    __sync_lock_test_and_set(&pengrid_zip_progress_gate_armed, 0);
    pengrid_zip_progress_gate_released = 1;
    pthread_cond_broadcast(&pengrid_zip_progress_gate_condition);
    pthread_mutex_unlock(&pengrid_zip_progress_gate_mutex);
}

int32_t pengrid_zip_test_wait_for_first_positive_progress_checkpoint(uint32_t timeout_milliseconds) {
    struct timespec deadline;
    int32_t entered = 0;

    if (clock_gettime(CLOCK_REALTIME, &deadline) != 0)
        return 0;
    deadline.tv_sec += (time_t)(timeout_milliseconds / 1000u);
    deadline.tv_nsec += (long)(timeout_milliseconds % 1000u) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&pengrid_zip_progress_gate_mutex);
    while (!pengrid_zip_progress_gate_entered &&
           __sync_fetch_and_add(&pengrid_zip_progress_gate_armed, 0) != 0) {
        int32_t status = pthread_cond_timedwait(
            &pengrid_zip_progress_gate_condition,
            &pengrid_zip_progress_gate_mutex,
            &deadline
        );
        if (status == ETIMEDOUT)
            break;
    }
    entered = pengrid_zip_progress_gate_entered;
    pthread_mutex_unlock(&pengrid_zip_progress_gate_mutex);
    return entered;
}

static void pengrid_zip_test_hold_first_positive_progress_checkpoint(
    uint64_t completed,
    uint64_t total
) {
    if (completed == 0 || total == 0 || completed >= total ||
        __sync_fetch_and_add(&pengrid_zip_progress_gate_armed, 0) == 0)
        return;

    pthread_mutex_lock(&pengrid_zip_progress_gate_mutex);
    if (!pengrid_zip_progress_gate_consumed &&
        __sync_fetch_and_add(&pengrid_zip_progress_gate_armed, 0) != 0) {
        pengrid_zip_progress_gate_consumed = 1;
        pengrid_zip_progress_gate_entered = 1;
        pthread_cond_broadcast(&pengrid_zip_progress_gate_condition);
        while (!pengrid_zip_progress_gate_released &&
               __sync_fetch_and_add(&pengrid_zip_progress_gate_armed, 0) != 0) {
            pthread_cond_wait(
                &pengrid_zip_progress_gate_condition,
                &pengrid_zip_progress_gate_mutex
            );
        }
    }
    pthread_mutex_unlock(&pengrid_zip_progress_gate_mutex);
}

typedef enum {
    PENGRID_ZIP_ENTRY_DIRECTORY = 1,
    PENGRID_ZIP_ENTRY_REGULAR = 2,
    PENGRID_ZIP_ENTRY_SYMLINK = 3
} pengrid_zip_entry_kind;

typedef struct {
    char *relative_path;
    uint8_t *link_target;
    size_t link_target_length;
    struct stat information;
    pengrid_zip_entry_kind kind;
} pengrid_zip_entry;

typedef struct {
    pengrid_zip_entry *entries;
    size_t count;
    size_t capacity;
    uint64_t total_uncompressed;
} pengrid_zip_entry_list;

typedef struct {
    mz_stream stream;
    int32_t fd;
    int32_t error;
    int64_t position;
    int64_t size;
    int64_t total_in;
    int64_t total_out;
    int64_t disk_number;
} pengrid_zip_output_stream;

static int32_t pengrid_zip_output_open(void *stream, const char *path, int32_t mode);
static int32_t pengrid_zip_output_is_open(void *stream);
static int32_t pengrid_zip_output_read(void *stream, void *buf, int32_t size);
static int32_t pengrid_zip_output_write(void *stream, const void *buf, int32_t size);
static int64_t pengrid_zip_output_tell(void *stream);
static int32_t pengrid_zip_output_seek(void *stream, int64_t offset, int32_t origin);
static int32_t pengrid_zip_output_close(void *stream);
static int32_t pengrid_zip_output_error(void *stream);
static void *pengrid_zip_output_create(void);
static void pengrid_zip_output_destroy(void **stream);
static int32_t pengrid_zip_output_get_prop(void *stream, int32_t prop, int64_t *value);
static int32_t pengrid_zip_output_set_prop(void *stream, int32_t prop, int64_t value);

static mz_stream_vtbl pengrid_zip_output_vtbl = {
    pengrid_zip_output_open,
    pengrid_zip_output_is_open,
    pengrid_zip_output_read,
    pengrid_zip_output_write,
    pengrid_zip_output_tell,
    pengrid_zip_output_seek,
    pengrid_zip_output_close,
    pengrid_zip_output_error,
    pengrid_zip_output_create,
    pengrid_zip_output_destroy,
    pengrid_zip_output_get_prop,
    pengrid_zip_output_set_prop
};

static int32_t pengrid_zip_duplicate_fd(int32_t fd) {
    int32_t duplicate;

    if (fd < 0)
        return -1;
    duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (duplicate >= 0)
        return duplicate;
    duplicate = dup(fd);
    if (duplicate < 0)
        return -1;
    if (fcntl(duplicate, F_SETFD, FD_CLOEXEC) < 0) {
        int saved_errno = errno;
        close(duplicate);
        errno = saved_errno;
        return -1;
    }
    return duplicate;
}

static int32_t pengrid_map_writer_status(int32_t status) {
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
    case MZ_PARAM_ERROR:
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    default:
        return PENGRID_ZIP_STATUS_MALFORMED_ARCHIVE;
    }
}

static int32_t pengrid_zip_output_open(void *stream, const char *path, int32_t mode) {
    MZ_UNUSED(stream);
    MZ_UNUSED(path);
    MZ_UNUSED(mode);
    return MZ_OK;
}

static int32_t pengrid_zip_output_is_open(void *stream) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    if (!output || output->fd < 0)
        return MZ_OPEN_ERROR;
    return MZ_OK;
}

static int32_t pengrid_zip_output_read(void *stream, void *buf, int32_t size) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    ssize_t count;

    if (!output || !buf || size < 0)
        return MZ_PARAM_ERROR;
    if (output->fd < 0)
        return MZ_STREAM_ERROR;
    if (size == 0)
        return 0;
    if (output->position > INT64_MAX - size) {
        output->error = EOVERFLOW;
        return MZ_READ_ERROR;
    }
    do {
        count = pread(output->fd, buf, (size_t)size, (off_t)output->position);
    } while (count < 0 && errno == EINTR);
    if (count < 0) {
        output->error = errno;
        return MZ_READ_ERROR;
    }
    output->position += (int64_t)count;
    output->total_in += (int64_t)count;
    return (int32_t)count;
}

static int32_t pengrid_zip_output_write(void *stream, const void *buf, int32_t size) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    const uint8_t *cursor = (const uint8_t *)buf;
    int32_t remaining;
    int32_t written = 0;

    if (!output || !buf || size < 0)
        return MZ_PARAM_ERROR;
    if (output->fd < 0)
        return MZ_STREAM_ERROR;
    remaining = size;
    while (remaining > 0) {
        ssize_t count;
        do {
            count = pwrite(output->fd, cursor, (size_t)remaining, (off_t)output->position);
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            output->error = errno;
            return MZ_WRITE_ERROR;
        }
        if (count == 0)
            return MZ_WRITE_ERROR;
        if (output->position > INT64_MAX - count) {
            output->error = EOVERFLOW;
            return MZ_WRITE_ERROR;
        }
        output->position += (int64_t)count;
        output->total_out += (int64_t)count;
        if (output->position > output->size)
            output->size = output->position;
        cursor += count;
        remaining -= (int32_t)count;
        written += (int32_t)count;
    }
    return written;
}

static int64_t pengrid_zip_output_tell(void *stream) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    if (!output || output->fd < 0)
        return MZ_TELL_ERROR;
    return output->position;
}

static int32_t pengrid_zip_output_seek(void *stream, int64_t offset, int32_t origin) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    int64_t base;
    int64_t position;

    if (!output || output->fd < 0)
        return MZ_SEEK_ERROR;
    switch (origin) {
    case MZ_SEEK_SET:
        base = 0;
        break;
    case MZ_SEEK_CUR:
        base = output->position;
        break;
    case MZ_SEEK_END:
        base = output->size;
        break;
    default:
        return MZ_SEEK_ERROR;
    }
    if ((offset > 0 && base > INT64_MAX - offset) ||
        (offset < 0 && base < INT64_MIN - offset)) {
        output->error = EOVERFLOW;
        return MZ_SEEK_ERROR;
    }
    position = base + offset;
    if (position < 0) {
        output->error = EINVAL;
        return MZ_SEEK_ERROR;
    }
    output->position = position;
    return MZ_OK;
}

static int32_t pengrid_zip_output_close(void *stream) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    if (!output || output->fd < 0)
        return MZ_OK;
    if (close(output->fd) != 0) {
        output->error = errno;
        output->fd = -1;
        return MZ_CLOSE_ERROR;
    }
    output->fd = -1;
    return MZ_OK;
}

static int32_t pengrid_zip_output_error(void *stream) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    if (!output)
        return MZ_PARAM_ERROR;
    return output->error;
}

static void *pengrid_zip_output_create(void) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)calloc(1, sizeof(*output));
    if (output) {
        output->stream.vtbl = &pengrid_zip_output_vtbl;
        output->fd = -1;
    }
    return output;
}

static void pengrid_zip_output_destroy(void **stream) {
    pengrid_zip_output_stream *output;
    if (!stream)
        return;
    output = (pengrid_zip_output_stream *)*stream;
    if (!output)
        return;
    pengrid_zip_output_close(output);
    free(output);
    *stream = NULL;
}

static int32_t pengrid_zip_output_get_prop(void *stream, int32_t prop, int64_t *value) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    if (!output || !value)
        return MZ_PARAM_ERROR;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN:
        *value = output->total_in;
        return MZ_OK;
    case MZ_STREAM_PROP_TOTAL_OUT:
        *value = output->total_out;
        return MZ_OK;
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
    case MZ_STREAM_PROP_TOTAL_OUT_MAX:
        *value = output->size;
        return MZ_OK;
    case MZ_STREAM_PROP_DISK_SIZE:
        /* A single output fd is never a split archive.  A positive value
         * would make minizip synthesize a second disk in the EOCD records. */
        *value = 0;
        return MZ_OK;
    case MZ_STREAM_PROP_DISK_NUMBER:
        *value = output->disk_number;
        return MZ_OK;
    }
    return MZ_EXIST_ERROR;
}

static int32_t pengrid_zip_output_set_prop(void *stream, int32_t prop, int64_t value) {
    pengrid_zip_output_stream *output = (pengrid_zip_output_stream *)stream;
    if (!output)
        return MZ_PARAM_ERROR;
    if (prop == MZ_STREAM_PROP_DISK_NUMBER) {
        output->disk_number = value;
        return MZ_OK;
    }
    return MZ_EXIST_ERROR;
}

static void pengrid_zip_entry_list_destroy(pengrid_zip_entry_list *list) {
    size_t index;
    if (!list)
        return;
    for (index = 0; index < list->count; index++) {
        if (list->entries[index].link_target) {
            pengrid_secure_clear(list->entries[index].link_target, list->entries[index].link_target_length);
            free(list->entries[index].link_target);
        }
        free(list->entries[index].relative_path);
    }
    free(list->entries);
    memset(list, 0, sizeof(*list));
}

static int pengrid_zip_entry_compare(const void *lhs, const void *rhs) {
    const pengrid_zip_entry *left = (const pengrid_zip_entry *)lhs;
    const pengrid_zip_entry *right = (const pengrid_zip_entry *)rhs;
    return strcmp(left->relative_path, right->relative_path);
}

static char *pengrid_zip_join_path(const char *prefix, const char *name) {
    size_t prefix_length = prefix ? strlen(prefix) : 0;
    size_t name_length = strlen(name);
    size_t separator = prefix_length > 0 ? 1 : 0;
    size_t length;
    char *result;

    if (name_length == 0 || name_length > UINT16_MAX)
        return NULL;
    if (prefix_length > UINT16_MAX || prefix_length > SIZE_MAX - name_length - separator - 1)
        return NULL;
    length = prefix_length + separator + name_length;
    if (length > UINT16_MAX)
        return NULL;
    result = (char *)malloc(length + 1);
    if (!result)
        return NULL;
    if (prefix_length > 0) {
        memcpy(result, prefix, prefix_length);
        result[prefix_length] = '/';
    }
    memcpy(result + prefix_length + separator, name, name_length);
    result[length] = 0;
    return result;
}

static int32_t pengrid_zip_read_link(int32_t directory_fd, const char *name, uint8_t **target, size_t *target_length) {
    size_t capacity = 256;
    uint8_t *buffer = NULL;

    if (!target || !target_length)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    for (;;) {
        ssize_t length;
        uint8_t *grown;
        if (capacity > SIZE_MAX - 1)
            return PENGRID_ZIP_STATUS_OVERFLOW;
        grown = (uint8_t *)realloc(buffer, capacity + 1);
        if (!grown) {
            free(buffer);
            return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        }
        buffer = grown;
        do {
            length = readlinkat(directory_fd, name, (char *)buffer, capacity);
        } while (length < 0 && errno == EINTR);
        if (length < 0) {
            free(buffer);
            return PENGRID_ZIP_STATUS_IO_ERROR;
        }
        if ((size_t)length < capacity) {
            buffer[length] = 0;
            *target = buffer;
            *target_length = (size_t)length;
            return PENGRID_ZIP_STATUS_OK;
        }
        if (capacity > SIZE_MAX / 2) {
            free(buffer);
            return PENGRID_ZIP_STATUS_OVERFLOW;
        }
        capacity *= 2;
    }
}

static int32_t pengrid_zip_append_entry(
    pengrid_zip_entry_list *list,
    const char *relative_path,
    const struct stat *information,
    pengrid_zip_entry_kind kind,
    uint8_t *link_target,
    size_t link_target_length
) {
    pengrid_zip_entry *entry;
    uint64_t content_size = 0;

    if (!list || !relative_path || !information)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    if (kind == PENGRID_ZIP_ENTRY_REGULAR) {
        if (information->st_size < 0)
            return PENGRID_ZIP_STATUS_OVERFLOW;
        content_size = (uint64_t)information->st_size;
    } else if (kind == PENGRID_ZIP_ENTRY_SYMLINK) {
        if (link_target_length > (size_t)INT64_MAX)
            return PENGRID_ZIP_STATUS_OVERFLOW;
        content_size = (uint64_t)link_target_length;
    }
    if (list->total_uncompressed > UINT64_MAX - content_size)
        return PENGRID_ZIP_STATUS_OVERFLOW;
    if (list->total_uncompressed > (uint64_t)INT64_MAX - content_size)
        return PENGRID_ZIP_STATUS_OVERFLOW;
    if (list->count == SIZE_MAX)
        return PENGRID_ZIP_STATUS_OVERFLOW;
    if (list->count == list->capacity) {
        size_t capacity = list->capacity == 0 ? 64 : list->capacity * 2;
        pengrid_zip_entry *grown;
        if (capacity < list->capacity || capacity > SIZE_MAX / sizeof(*grown))
            return PENGRID_ZIP_STATUS_OVERFLOW;
        grown = (pengrid_zip_entry *)realloc(list->entries, capacity * sizeof(*grown));
        if (!grown)
            return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        list->entries = grown;
        list->capacity = capacity;
    }
    entry = &list->entries[list->count];
    memset(entry, 0, sizeof(*entry));
    entry->relative_path = strdup(relative_path);
    if (!entry->relative_path)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    entry->information = *information;
    entry->kind = kind;
    entry->link_target = link_target;
    entry->link_target_length = link_target_length;
    list->count += 1;
    list->total_uncompressed += content_size;
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_zip_collect_directory(
    int32_t directory_fd,
    const char *prefix,
    pengrid_zip_entry_list *list
) {
    DIR *directory = NULL;
    struct dirent *item;
    int32_t status = PENGRID_ZIP_STATUS_OK;

    directory = fdopendir(directory_fd);
    if (!directory) {
        close(directory_fd);
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    while ((item = readdir(directory)) != NULL) {
        struct stat information;
        char *relative_path;
        int32_t child_fd = -1;
        uint8_t *link_target = NULL;
        size_t link_target_length = 0;
        pengrid_zip_entry_kind kind;
        int32_t result;

        if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0)
            continue;
        if (fstatat(dirfd(directory), item->d_name, &information, AT_SYMLINK_NOFOLLOW) != 0) {
            status = PENGRID_ZIP_STATUS_IO_ERROR;
            break;
        }
        if (S_ISREG(information.st_mode) &&
            __sync_fetch_and_add(&pengrid_zip_override_regular_size_count, 0) > 0) {
            __sync_fetch_and_sub(&pengrid_zip_override_regular_size_count, 1);
            information.st_size = (off_t)__sync_fetch_and_add(
                &pengrid_zip_override_regular_size, 0
            );
        }
        relative_path = pengrid_zip_join_path(prefix, item->d_name);
        if (!relative_path) {
            status = PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
            break;
        }
        if (S_ISDIR(information.st_mode)) {
            kind = PENGRID_ZIP_ENTRY_DIRECTORY;
        } else if (S_ISREG(information.st_mode)) {
            kind = PENGRID_ZIP_ENTRY_REGULAR;
        } else if (S_ISLNK(information.st_mode)) {
            kind = PENGRID_ZIP_ENTRY_SYMLINK;
            result = pengrid_zip_read_link(dirfd(directory), item->d_name, &link_target, &link_target_length);
            if (result != PENGRID_ZIP_STATUS_OK) {
                free(relative_path);
                status = result;
                break;
            }
        } else {
            free(relative_path);
            status = PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            break;
        }

        result = pengrid_zip_append_entry(
            list,
            relative_path,
            &information,
            kind,
            link_target,
            link_target_length
        );
        free(relative_path);
        if (result != PENGRID_ZIP_STATUS_OK) {
            if (link_target) {
                pengrid_secure_clear(link_target, link_target_length);
                free(link_target);
            }
            status = result;
            break;
        }

        if (kind == PENGRID_ZIP_ENTRY_DIRECTORY) {
            child_fd = openat(
                dirfd(directory),
                item->d_name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            );
            if (child_fd < 0) {
                status = PENGRID_ZIP_STATUS_IO_ERROR;
                break;
            }
            status = pengrid_zip_collect_directory(
                child_fd,
                list->entries[list->count - 1].relative_path,
                list
            );
            if (status != PENGRID_ZIP_STATUS_OK)
                break;
        }
    }
    closedir(directory);
    return status;
}

static int32_t pengrid_zip_open_relative_regular(int32_t root_fd, const char *relative_path) {
    char *path = NULL;
    char *component;
    char *next;
    int32_t current_fd;

    path = strdup(relative_path);
    if (!path)
        return -1;
    current_fd = pengrid_zip_duplicate_fd(root_fd);
    if (current_fd < 0) {
        free(path);
        return -1;
    }
    component = path;
    while (component && *component) {
        int32_t next_fd;
        next = strchr(component, '/');
        if (next)
            *next++ = 0;
        if (*component == 0) {
            close(current_fd);
            free(path);
            return -1;
        }
        if (next && *next) {
            next_fd = openat(current_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            close(current_fd);
            current_fd = next_fd;
            if (current_fd < 0) {
                free(path);
                return -1;
            }
        } else {
            /* O_NONBLOCK prevents a path swapped to a FIFO/device between
             * enumeration and open from blocking the worker indefinitely. */
            next_fd = openat(current_fd, component, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
            close(current_fd);
            free(path);
            return next_fd;
        }
        component = next;
    }
    close(current_fd);
    free(path);
    return -1;
}

static int pengrid_zip_stat_matches(const struct stat *expected, const struct stat *actual) {
    if (!expected || !actual)
        return 0;
    if ((expected->st_mode & S_IFMT) != (actual->st_mode & S_IFMT))
        return 0;
    if (expected->st_dev != actual->st_dev || expected->st_ino != actual->st_ino)
        return 0;
    if (expected->st_size != actual->st_size)
        return 0;
    if (expected->st_mtimespec.tv_sec != actual->st_mtimespec.tv_sec ||
        expected->st_mtimespec.tv_nsec != actual->st_mtimespec.tv_nsec)
        return 0;
    if (expected->st_ctimespec.tv_sec != actual->st_ctimespec.tv_sec ||
        expected->st_ctimespec.tv_nsec != actual->st_ctimespec.tv_nsec)
        return 0;
    return 1;
}

static int32_t pengrid_zip_progress(
    pengrid_zip_progress_callback callback,
    void *context,
    uint64_t completed,
    uint64_t total
) {
    if (!callback)
        return PENGRID_ZIP_STATUS_OK;
    pengrid_zip_test_hold_first_positive_progress_checkpoint(completed, total);
    return callback(completed, total, context) == 0
        ? PENGRID_ZIP_STATUS_OK
        : PENGRID_ZIP_STATUS_CANCELLED;
}

static int32_t pengrid_zip_write_bytes(
    void *writer,
    const uint8_t *bytes,
    size_t length,
    uint64_t *completed,
    uint64_t total,
    pengrid_zip_progress_callback progress,
    void *progress_context,
    uint8_t *buffer
) {
    size_t offset = 0;
    while (offset < length) {
        size_t remaining = length - offset;
        int32_t chunk = (int32_t)(remaining > PENGRID_ZIP_WRITE_BUFFER_SIZE
            ? PENGRID_ZIP_WRITE_BUFFER_SIZE
            : remaining);
        int32_t written = mz_zip_writer_entry_write(writer, bytes + offset, chunk);
        if (written != chunk)
            return written < 0 ? pengrid_map_writer_status(written) : PENGRID_ZIP_STATUS_IO_ERROR;
        if (*completed > UINT64_MAX - (uint64_t)chunk)
            return PENGRID_ZIP_STATUS_OVERFLOW;
        *completed += (uint64_t)chunk;
        if (pengrid_zip_progress(progress, progress_context, *completed, total) != PENGRID_ZIP_STATUS_OK)
            return PENGRID_ZIP_STATUS_CANCELLED;
        offset += (size_t)chunk;
    }
    MZ_UNUSED(buffer);
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_zip_write_regular(
    void *writer,
    int32_t root_fd,
    const pengrid_zip_entry *entry,
    uint64_t *completed,
    uint64_t total,
    pengrid_zip_progress_callback progress,
    void *progress_context,
    uint8_t *buffer
) {
    int32_t fd = -1;
    struct stat current_information;
    int32_t status = PENGRID_ZIP_STATUS_OK;
    uint64_t remaining;

    fd = pengrid_zip_open_relative_regular(root_fd, entry->relative_path);
    if (fd < 0)
        return PENGRID_ZIP_STATUS_IO_ERROR;
    if (fstat(fd, &current_information) != 0 || !S_ISREG(current_information.st_mode) ||
        current_information.st_size < 0 || !pengrid_zip_stat_matches(&entry->information, &current_information)) {
        close(fd);
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    remaining = (uint64_t)entry->information.st_size;
    while (remaining > 0) {
        ssize_t count;
        size_t requested = remaining > PENGRID_ZIP_WRITE_BUFFER_SIZE
            ? PENGRID_ZIP_WRITE_BUFFER_SIZE
            : (size_t)remaining;
        do {
            count = read(fd, buffer, requested);
        } while (count < 0 && errno == EINTR);
        if (count < 0) {
            status = PENGRID_ZIP_STATUS_IO_ERROR;
            break;
        }
        if (count == 0) {
            /* A short read is never accepted for an enumerated regular
             * file.  This keeps EOF and concurrent truncation distinct. */
            status = PENGRID_ZIP_STATUS_IO_ERROR;
            break;
        }
        status = pengrid_zip_write_bytes(
            writer,
            buffer,
            (size_t)count,
            completed,
            total,
            progress,
            progress_context,
            buffer
        );
        if (status != PENGRID_ZIP_STATUS_OK)
            break;
        remaining -= (uint64_t)count;
    }
    if (status == PENGRID_ZIP_STATUS_OK) {
        uint8_t extra_byte;
        ssize_t extra_count;
        do {
            extra_count = read(fd, &extra_byte, sizeof(extra_byte));
        } while (extra_count < 0 && errno == EINTR);
        if (extra_count != 0)
            status = PENGRID_ZIP_STATUS_IO_ERROR;
    }
    if (status == PENGRID_ZIP_STATUS_OK &&
        (fstat(fd, &current_information) != 0 ||
         !pengrid_zip_stat_matches(&entry->information, &current_information))) {
        status = PENGRID_ZIP_STATUS_IO_ERROR;
    }
    if (close(fd) != 0 && status == PENGRID_ZIP_STATUS_OK)
        status = PENGRID_ZIP_STATUS_IO_ERROR;
    return status;
}

static int32_t pengrid_zip_write_entry(
    void *writer,
    int32_t source_root_fd,
    const pengrid_zip_entry *entry,
    uint64_t *completed,
    uint64_t total,
    pengrid_zip_progress_callback progress,
    void *progress_context,
    uint8_t *buffer
) {
    mz_zip_file file_info;
    int32_t status;
    uint8_t entry_open = 0;

    memset(&file_info, 0, sizeof(file_info));
    file_info.version_madeby = MZ_VERSION_MADEBY;
    file_info.filename = entry->relative_path;
    file_info.modified_date = entry->information.st_mtimespec.tv_sec;
    file_info.accessed_date = entry->information.st_atimespec.tv_sec;
    file_info.creation_date = entry->information.st_birthtimespec.tv_sec;
    file_info.external_fa = ((uint32_t)entry->information.st_mode) << 16;
    file_info.flag = MZ_ZIP_FLAG_UTF8;
    file_info.zip64 = MZ_ZIP64_FORCE;

    if (entry->kind == PENGRID_ZIP_ENTRY_DIRECTORY) {
        file_info.compression_method = MZ_COMPRESS_METHOD_STORE;
        file_info.uncompressed_size = 0;
    } else if (entry->kind == PENGRID_ZIP_ENTRY_SYMLINK) {
        file_info.compression_method = MZ_COMPRESS_METHOD_STORE;
        file_info.uncompressed_size = (int64_t)entry->link_target_length;
        if (entry->link_target_length <= UINT16_MAX)
            file_info.linkname = (const char *)entry->link_target;
        file_info.aes_version = MZ_AES_VERSION;
        file_info.aes_strength = MZ_AES_STRENGTH_256;
    } else {
        file_info.compression_method = MZ_COMPRESS_METHOD_DEFLATE;
        file_info.uncompressed_size = (int64_t)entry->information.st_size;
        file_info.aes_version = MZ_AES_VERSION;
        file_info.aes_strength = MZ_AES_STRENGTH_256;
    }

    status = pengrid_map_writer_status(mz_zip_writer_entry_open(writer, &file_info));
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    entry_open = 1;
    if (entry->kind == PENGRID_ZIP_ENTRY_REGULAR) {
        status = pengrid_zip_write_regular(
            writer,
            source_root_fd,
            entry,
            completed,
            total,
            progress,
            progress_context,
            buffer
        );
    } else if (entry->kind == PENGRID_ZIP_ENTRY_SYMLINK) {
        status = pengrid_zip_write_bytes(
            writer,
            entry->link_target,
            entry->link_target_length,
            completed,
            total,
            progress,
            progress_context,
            buffer
        );
    }
    if (entry_open) {
        int32_t close_status = pengrid_map_writer_status(mz_zip_writer_entry_close(writer));
        if (status == PENGRID_ZIP_STATUS_OK)
            status = close_status;
    }
    return status;
}

int32_t pengrid_zip_create_aes256(
    int source_root_fd,
    int destination_fd,
    const uint8_t *password,
    size_t password_length,
    pengrid_zip_progress_callback progress,
    void *progress_context
) {
    int32_t source_enumeration_fd = -1;
    int32_t source_read_fd = -1;
    int32_t destination_duplicate_fd = -1;
    void *output_stream = NULL;
    void *writer = NULL;
    uint8_t *password_copy = NULL;
    uint8_t *buffer = NULL;
    pengrid_zip_entry_list entries;
    uint64_t completed = 0;
    int32_t status = PENGRID_ZIP_STATUS_OK;
    size_t index;
    struct stat root_information;

    memset(&entries, 0, sizeof(entries));
    if (source_root_fd < 0 || destination_fd < 0 || !password || password_length < 8 ||
        password_length > PENGRID_ZIP_MAX_PASSWORD_LENGTH)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    for (index = 0; index < password_length; index++) {
        if (password[index] == 0)
            return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    }
    if (password_length == SIZE_MAX)
        return PENGRID_ZIP_STATUS_OVERFLOW;

    password_copy = (uint8_t *)malloc(password_length + 1);
    if (!password_copy)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    memcpy(password_copy, password, password_length);
    password_copy[password_length] = 0;

    source_enumeration_fd = pengrid_zip_duplicate_fd(source_root_fd);
    source_read_fd = pengrid_zip_duplicate_fd(source_root_fd);
    destination_duplicate_fd = pengrid_zip_duplicate_fd(destination_fd);
    if (source_enumeration_fd < 0 || source_read_fd < 0 || destination_duplicate_fd < 0) {
        status = PENGRID_ZIP_STATUS_IO_ERROR;
        goto cleanup;
    }
    if (fstat(source_enumeration_fd, &root_information) != 0 || !S_ISDIR(root_information.st_mode)) {
        status = PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
        goto cleanup;
    }
    status = pengrid_zip_collect_directory(source_enumeration_fd, NULL, &entries);
    source_enumeration_fd = -1; /* fdopendir/closedir owns it */
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    qsort(entries.entries, entries.count, sizeof(*entries.entries), pengrid_zip_entry_compare);
    status = pengrid_zip_progress(progress, progress_context, 0, entries.total_uncompressed);
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;

    output_stream = pengrid_zip_output_create();
    if (!output_stream) {
        status = PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        goto cleanup;
    }
    ((pengrid_zip_output_stream *)output_stream)->fd = destination_duplicate_fd;
    destination_duplicate_fd = -1;
    if (fstat(((pengrid_zip_output_stream *)output_stream)->fd, &root_information) != 0 || root_information.st_size < 0) {
        status = PENGRID_ZIP_STATUS_IO_ERROR;
        goto cleanup;
    }
    ((pengrid_zip_output_stream *)output_stream)->size = (int64_t)root_information.st_size;
    if (ftruncate(((pengrid_zip_output_stream *)output_stream)->fd, 0) != 0) {
        status = PENGRID_ZIP_STATUS_IO_ERROR;
        goto cleanup;
    }
    ((pengrid_zip_output_stream *)output_stream)->size = 0;

    writer = mz_zip_writer_create();
    if (!writer) {
        status = PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        goto cleanup;
    }
    mz_zip_writer_set_password(writer, (const char *)password_copy);
    mz_zip_writer_set_aes(writer, 1);
    mz_zip_writer_set_follow_links(writer, 0);
    mz_zip_writer_set_store_links(writer, 1);
    mz_zip_writer_set_compress_method(writer, MZ_COMPRESS_METHOD_DEFLATE);
    mz_zip_writer_set_compress_level(writer, MZ_COMPRESS_LEVEL_BEST);
    status = pengrid_map_writer_status(mz_zip_writer_open(writer, output_stream, 0));
    if (status != PENGRID_ZIP_STATUS_OK)
        goto cleanup;
    buffer = (uint8_t *)malloc(PENGRID_ZIP_WRITE_BUFFER_SIZE);
    if (!buffer) {
        status = PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        goto cleanup;
    }
    for (index = 0; index < entries.count; index++) {
        status = pengrid_zip_write_entry(
            writer,
            source_read_fd,
            &entries.entries[index],
            &completed,
            entries.total_uncompressed,
            progress,
            progress_context,
            buffer
        );
        if (status != PENGRID_ZIP_STATUS_OK)
            goto cleanup;
    }
    if (completed != entries.total_uncompressed) {
        status = PENGRID_ZIP_STATUS_OVERFLOW;
        goto cleanup;
    }
    status = pengrid_zip_progress(progress, progress_context, entries.total_uncompressed, entries.total_uncompressed);

cleanup:
    if (writer) {
        int32_t close_status = pengrid_map_writer_status(mz_zip_writer_close(writer));
        if (status == PENGRID_ZIP_STATUS_OK)
            status = close_status;
        mz_zip_writer_delete(&writer);
    }
    if (output_stream)
        mz_stream_delete(&output_stream);
    if (destination_duplicate_fd >= 0)
        close(destination_duplicate_fd);
    if (source_enumeration_fd >= 0)
        close(source_enumeration_fd);
    if (source_read_fd >= 0)
        close(source_read_fd);
    if (buffer) {
        pengrid_secure_clear(buffer, PENGRID_ZIP_WRITE_BUFFER_SIZE);
        free(buffer);
    }
    pengrid_zip_entry_list_destroy(&entries);
    if (password_copy) {
        pengrid_secure_clear(password_copy, password_length + 1);
        free(password_copy);
    }
    return status;
}
