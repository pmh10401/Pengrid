#include "pengrid_fd_stream.h"

#include "mz.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct pengrid_fd_stream_s {
    mz_stream stream;
    int32_t fd;
    int32_t error;
    int64_t position;
    int64_t size;
    int64_t total_in;
    int64_t disk_number;
} pengrid_fd_stream;

static int32_t pengrid_fd_stream_open(void *stream, const char *path, int32_t mode);
static int32_t pengrid_fd_stream_is_open(void *stream);
static int32_t pengrid_fd_stream_read(void *stream, void *buf, int32_t size);
static int32_t pengrid_fd_stream_write(void *stream, const void *buf, int32_t size);
static int64_t pengrid_fd_stream_tell(void *stream);
static int32_t pengrid_fd_stream_seek(void *stream, int64_t offset, int32_t origin);
static int32_t pengrid_fd_stream_close(void *stream);
static int32_t pengrid_fd_stream_error(void *stream);
static void *pengrid_fd_stream_create_vtbl(void);
static void pengrid_fd_stream_destroy(void **stream);
static int32_t pengrid_fd_stream_get_prop(void *stream, int32_t prop, int64_t *value);
static int32_t pengrid_fd_stream_set_prop(void *stream, int32_t prop, int64_t value);

static mz_stream_vtbl pengrid_fd_stream_vtbl = {
    pengrid_fd_stream_open,
    pengrid_fd_stream_is_open,
    pengrid_fd_stream_read,
    pengrid_fd_stream_write,
    pengrid_fd_stream_tell,
    pengrid_fd_stream_seek,
    pengrid_fd_stream_close,
    pengrid_fd_stream_error,
    pengrid_fd_stream_create_vtbl,
    pengrid_fd_stream_destroy,
    pengrid_fd_stream_get_prop,
    pengrid_fd_stream_set_prop
};

static int32_t pengrid_duplicate_fd(int32_t fd) {
    int32_t duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
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

static int32_t pengrid_fd_stream_open(void *stream, const char *path, int32_t mode) {
    MZ_UNUSED(stream);
    MZ_UNUSED(path);
    MZ_UNUSED(mode);
    return MZ_OK;
}

static int32_t pengrid_fd_stream_is_open(void *stream) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    if (!fd_stream || fd_stream->fd < 0)
        return MZ_OPEN_ERROR;
    return MZ_OK;
}

static int32_t pengrid_fd_stream_read(void *stream, void *buf, int32_t size) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    ssize_t count;

    if (!fd_stream || !buf || size < 0)
        return MZ_PARAM_ERROR;
    if (fd_stream->fd < 0)
        return MZ_STREAM_ERROR;
    if (size == 0)
        return 0;
    if (fd_stream->position > INT64_MAX - size)
        return MZ_READ_ERROR;

    count = pread(fd_stream->fd, buf, (size_t)size, (off_t)fd_stream->position);
    if (count < 0) {
        fd_stream->error = errno;
        return MZ_READ_ERROR;
    }
    if (count > INT32_MAX)
        count = INT32_MAX;
    fd_stream->position += (int64_t)count;
    fd_stream->total_in += (int64_t)count;
    return (int32_t)count;
}

static int32_t pengrid_fd_stream_write(void *stream, const void *buf, int32_t size) {
    MZ_UNUSED(stream);
    MZ_UNUSED(buf);
    MZ_UNUSED(size);
    return MZ_WRITE_ERROR;
}

static int64_t pengrid_fd_stream_tell(void *stream) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    if (!fd_stream || fd_stream->fd < 0)
        return MZ_TELL_ERROR;
    return fd_stream->position;
}

static int32_t pengrid_fd_stream_seek(void *stream, int64_t offset, int32_t origin) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    int64_t base;
    int64_t position;

    if (!fd_stream || fd_stream->fd < 0)
        return MZ_SEEK_ERROR;
    switch (origin) {
    case MZ_SEEK_SET:
        base = 0;
        break;
    case MZ_SEEK_CUR:
        base = fd_stream->position;
        break;
    case MZ_SEEK_END:
        base = fd_stream->size;
        break;
    default:
        return MZ_SEEK_ERROR;
    }
    if ((offset > 0 && base > INT64_MAX - offset) ||
        (offset < 0 && base < INT64_MIN - offset)) {
        fd_stream->error = EOVERFLOW;
        return MZ_SEEK_ERROR;
    }
    position = base + offset;
    if (position < 0) {
        fd_stream->error = EINVAL;
        return MZ_SEEK_ERROR;
    }
    fd_stream->position = position;
    return MZ_OK;
}

static int32_t pengrid_fd_stream_close(void *stream) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    int32_t status;

    if (!fd_stream || fd_stream->fd < 0)
        return MZ_OK;
    status = close(fd_stream->fd);
    if (status != 0) {
        fd_stream->error = errno;
        fd_stream->fd = -1;
        return MZ_CLOSE_ERROR;
    }
    fd_stream->fd = -1;
    return MZ_OK;
}

static int32_t pengrid_fd_stream_error(void *stream) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    if (!fd_stream)
        return MZ_PARAM_ERROR;
    return fd_stream->error;
}

static void *pengrid_fd_stream_create_vtbl(void) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)calloc(1, sizeof(*fd_stream));
    if (fd_stream) {
        fd_stream->stream.vtbl = &pengrid_fd_stream_vtbl;
        fd_stream->fd = -1;
    }
    return fd_stream;
}

static void pengrid_fd_stream_destroy(void **stream) {
    pengrid_fd_stream *fd_stream;
    if (!stream)
        return;
    fd_stream = (pengrid_fd_stream *)*stream;
    if (!fd_stream)
        return;
    pengrid_fd_stream_close(fd_stream);
    free(fd_stream);
    *stream = NULL;
}

static int32_t pengrid_fd_stream_get_prop(void *stream, int32_t prop, int64_t *value) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    if (!fd_stream || !value)
        return MZ_PARAM_ERROR;
    switch (prop) {
    case MZ_STREAM_PROP_TOTAL_IN:
        *value = fd_stream->total_in;
        return MZ_OK;
    case MZ_STREAM_PROP_TOTAL_IN_MAX:
    case MZ_STREAM_PROP_TOTAL_OUT_MAX:
        *value = fd_stream->size;
        return MZ_OK;
    case MZ_STREAM_PROP_DISK_SIZE:
        *value = fd_stream->size;
        return MZ_OK;
    case MZ_STREAM_PROP_DISK_NUMBER:
        *value = fd_stream->disk_number;
        return MZ_OK;
    }
    return MZ_EXIST_ERROR;
}

static int32_t pengrid_fd_stream_set_prop(void *stream, int32_t prop, int64_t value) {
    pengrid_fd_stream *fd_stream = (pengrid_fd_stream *)stream;
    if (!fd_stream)
        return MZ_PARAM_ERROR;
    if (prop == MZ_STREAM_PROP_DISK_NUMBER) {
        fd_stream->disk_number = value;
        return MZ_OK;
    }
    return MZ_EXIST_ERROR;
}

void *pengrid_fd_stream_create(int archive_fd) {
    pengrid_fd_stream *fd_stream;
    struct stat information;
    int32_t duplicate;

    if (archive_fd < 0)
        return NULL;
    duplicate = pengrid_duplicate_fd(archive_fd);
    if (duplicate < 0)
        return NULL;
    if (fstat(duplicate, &information) != 0 || information.st_size < 0 || information.st_size > INT64_MAX) {
        close(duplicate);
        return NULL;
    }
    fd_stream = (pengrid_fd_stream *)pengrid_fd_stream_create_vtbl();
    if (!fd_stream) {
        close(duplicate);
        return NULL;
    }
    fd_stream->fd = duplicate;
    fd_stream->size = (int64_t)information.st_size;
    fd_stream->disk_number = 0;
    return fd_stream;
}
