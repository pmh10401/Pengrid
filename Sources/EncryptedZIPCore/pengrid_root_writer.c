#include "pengrid_root_writer.h"

#include "pengrid_encrypted_zip.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#ifndef NAME_MAX
#define NAME_MAX 255
#endif

static int32_t pengrid_root_status_from_errno(int error, uint8_t collision_is_unsafe) {
    switch (error) {
    case EEXIST:
    case ELOOP:
    case ENOTDIR:
    case ENAMETOOLONG:
        return collision_is_unsafe ? PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY : PENGRID_ZIP_STATUS_IO_ERROR;
    case ENOSPC:
    case EDQUOT:
        return PENGRID_ZIP_STATUS_CAPACITY;
    default:
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
}

int32_t pengrid_root_duplicate_fd(int fd) {
    int duplicate;

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

static int32_t pengrid_root_name_limit(int root_fd) {
    long value = fpathconf(root_fd, _PC_NAME_MAX);
    if (value <= 0 || value > INT32_MAX)
        return NAME_MAX > 0 ? NAME_MAX : 255;
    return (int32_t)value;
}

static int32_t pengrid_root_path_limit(int root_fd) {
    long value = fpathconf(root_fd, _PC_PATH_MAX);
    if (value <= 0 || value > INT32_MAX)
        return PATH_MAX;
    return (int32_t)value;
}

static int pengrid_root_is_separator(uint8_t byte) {
    return byte == '/' || byte == '\\';
}

static int pengrid_root_validate_utf8(const uint8_t *bytes, size_t length) {
    size_t index = 0;
    while (index < length) {
        uint8_t first = bytes[index++];
        size_t continuation;
        uint32_t codepoint;
        if (first < 0x80)
            continue;
        if (first >= 0xC2 && first <= 0xDF) {
            continuation = 1;
            codepoint = first & 0x1F;
        } else if (first >= 0xE0 && first <= 0xEF) {
            continuation = 2;
            codepoint = first & 0x0F;
        } else if (first >= 0xF0 && first <= 0xF4) {
            continuation = 3;
            codepoint = first & 0x07;
        } else {
            return 0;
        }
        if (index + continuation > length)
            return 0;
        for (size_t offset = 0; offset < continuation; offset++) {
            uint8_t next = bytes[index++];
            if ((next & 0xC0) != 0x80)
                return 0;
            codepoint = (codepoint << 6) | (next & 0x3F);
        }
        if ((continuation == 2 && codepoint < 0x800) ||
            (continuation == 3 && codepoint < 0x10000) ||
            codepoint > 0x10FFFF ||
            (codepoint >= 0xD800 && codepoint <= 0xDFFF))
            return 0;
    }
    return 1;
}

static int32_t pengrid_root_component_count(const char *path) {
    int32_t count = 0;
    const char *cursor = path;
    while (*cursor) {
        const char *slash = strchr(cursor, '/');
        count += 1;
        if (!slash)
            break;
        cursor = slash + 1;
    }
    return count;
}

int32_t pengrid_root_validate_path(
    int root_fd,
    const char *path,
    size_t path_length,
    char **normalized_path) {
    char *normalized;
    size_t output_length = 0;
    size_t component_length = 0;
    int32_t name_limit;
    int32_t path_limit;

    if (root_fd < 0 || !path || !normalized_path || path_length == 0)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    *normalized_path = NULL;
    if (memchr(path, '\0', path_length) != NULL)
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    if (!pengrid_root_validate_utf8((const uint8_t *)path, path_length))
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    if (pengrid_root_is_separator((uint8_t)path[0]))
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    if (path_length >= 3 && path[1] == ':' && pengrid_root_is_separator((uint8_t)path[2]))
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;

    name_limit = pengrid_root_name_limit(root_fd);
    path_limit = pengrid_root_path_limit(root_fd);
    if (path_length >= (size_t)path_limit)
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;

    normalized = (char *)malloc(path_length + 1);
    if (!normalized)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    for (size_t index = 0; index < path_length; index++) {
        uint8_t byte = (uint8_t)path[index];
        if (pengrid_root_is_separator(byte)) {
            if (component_length == 0) {
                /* One trailing separator is the directory spelling; all other
                   empty components are ambiguous and therefore unsafe. */
                if (index + 1 == path_length && (index == 0 || !pengrid_root_is_separator((uint8_t)path[index - 1])))
                    continue;
                free(normalized);
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            }
            normalized[output_length++] = '/';
            component_length = 0;
            continue;
        }
        component_length += 1;
        if (component_length > (size_t)name_limit) {
            free(normalized);
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
        if (byte == '.' && (component_length == 1 || component_length == 2)) {
            /* Check complete component below; retaining the bytes here keeps
               the parser allocation-free for ordinary names. */
        }
        normalized[output_length++] = (char)byte;
    }
    while (output_length > 0 && normalized[output_length - 1] == '/')
        output_length -= 1;
    if (output_length == 0) {
        free(normalized);
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    }
    normalized[output_length] = '\0';

    /* Reject dot components, drive-relative names, and colons in the first
       component. */
    {
        char *cursor = normalized;
        int first_component = 1;
        while (*cursor) {
            char *end = strchr(cursor, '/');
            if (!end)
                end = cursor + strlen(cursor);
            size_t length = (size_t)(end - cursor);
            if ((length == 1 && cursor[0] == '.') ||
                (length == 2 && cursor[0] == '.' && cursor[1] == '.') ||
                (first_component && memchr(cursor, ':', length) != NULL)) {
                free(normalized);
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            }
            first_component = 0;
            cursor = *end ? end + 1 : end;
        }
    }
    *normalized_path = normalized;
    return PENGRID_ZIP_STATUS_OK;
}

int32_t pengrid_root_validate_link_target(
    const char *parent_path,
    const char *target,
    size_t target_length) {
    int32_t depth;
    size_t index = 0;
    int first_component = 1;

    if (!parent_path || !target || target_length == 0 || target_length >= PATH_MAX)
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    if (memchr(target, '\0', target_length) != NULL ||
        !pengrid_root_validate_utf8((const uint8_t *)target, target_length) ||
        pengrid_root_is_separator((uint8_t)target[0]))
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    if (target_length >= 2 && target[1] == ':')
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    depth = pengrid_root_component_count(parent_path);
    while (index < target_length) {
        size_t start = index;
        while (index < target_length && !pengrid_root_is_separator((uint8_t)target[index]))
            index += 1;
        size_t length = index - start;
        if (length == 0) {
            if (index == target_length)
                break;
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
        if (first_component && memchr(target + start, ':', length) != NULL)
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        if (length == 1 && target[start] == '.') {
            /* no-op */
        } else if (length == 2 && target[start] == '.' && target[start + 1] == '.') {
            if (depth <= 0)
                return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
            depth -= 1;
        } else {
            depth += 1;
        }
        first_component = 0;
        while (index < target_length && pengrid_root_is_separator((uint8_t)target[index]))
            index += 1;
    }
    return PENGRID_ZIP_STATUS_OK;
}

int32_t pengrid_root_is_empty(int root_fd) {
    int duplicate;
    DIR *directory;
    struct dirent *item;

    if (root_fd < 0)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    /* Open a fresh description for enumeration; dup() would share the
       caller's directory offset with fdopendir/readdir. */
    duplicate = openat(root_fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (duplicate < 0)
        return PENGRID_ZIP_STATUS_IO_ERROR;
    directory = fdopendir(duplicate);
    if (!directory) {
        close(duplicate);
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    errno = 0;
    while ((item = readdir(directory)) != NULL) {
        if (strcmp(item->d_name, ".") != 0 && strcmp(item->d_name, "..") != 0) {
            closedir(directory);
            return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
    }
    if (errno != 0) {
        closedir(directory);
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    closedir(directory);
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_root_append_created(
    pengrid_root_created_list *created,
    const char *path,
    uint8_t is_directory) {
    pengrid_root_created_entry *grown;
    if (!created || !path)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    if (created->count == created->capacity) {
        size_t next = created->capacity == 0 ? 8 : created->capacity * 2;
        if (next < created->capacity || next > SIZE_MAX / sizeof(*grown))
            return PENGRID_ZIP_STATUS_OVERFLOW;
        grown = (pengrid_root_created_entry *)realloc(created->entries, next * sizeof(*grown));
        if (!grown)
            return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
        created->entries = grown;
        created->capacity = next;
    }
    created->entries[created->count].path = strdup(path);
    if (!created->entries[created->count].path)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    created->entries[created->count].is_directory = is_directory;
    created->count += 1;
    return PENGRID_ZIP_STATUS_OK;
}

static int pengrid_root_created_contains(
    const pengrid_root_created_list *created,
    const char *path,
    uint8_t is_directory) {
    if (!created || !path)
        return 0;
    for (size_t index = 0; index < created->count; index++) {
        if (created->entries[index].is_directory == is_directory &&
            strcmp(created->entries[index].path, path) == 0)
            return 1;
    }
    return 0;
}

static int32_t pengrid_root_open_parent(
    int root_fd,
    const char *path,
    int *parent_fd,
    char **leaf) {
    char *copy;
    char *slash;
    int current;

    if (root_fd < 0 || !path || !parent_fd || !leaf)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    *parent_fd = -1;
    *leaf = NULL;
    copy = strdup(path);
    if (!copy)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    slash = strrchr(copy, '/');
    if (slash) {
        *slash = '\0';
        *leaf = strdup(slash + 1);
    } else {
        *leaf = strdup(copy);
        copy[0] = '\0';
    }
    if (!*leaf || (*leaf)[0] == '\0') {
        free(copy);
        free(*leaf);
        *leaf = NULL;
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    }

    current = pengrid_root_duplicate_fd(root_fd);
    if (current < 0) {
        free(copy);
        free(*leaf);
        *leaf = NULL;
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    if (copy[0] != '\0') {
        char *cursor = copy;
        while (cursor && *cursor) {
            char *end = strchr(cursor, '/');
            int next;
            if (end)
                *end = '\0';
            next = openat(current, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (next < 0) {
                int status = pengrid_root_status_from_errno(errno, 1);
                close(current);
                free(copy);
                free(*leaf);
                *leaf = NULL;
                return status;
            }
            close(current);
            current = next;
            cursor = end ? end + 1 : NULL;
        }
    }
    free(copy);
    *parent_fd = current;
    return PENGRID_ZIP_STATUS_OK;
}

static int32_t pengrid_root_open_or_create_parent(
    int root_fd,
    const char *path,
    int *parent_fd,
    char **leaf,
    pengrid_root_created_list *created) {
    char *copy;
    char *slash;
    int current;

    if (root_fd < 0 || !path || !parent_fd || !leaf)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    *parent_fd = -1;
    *leaf = NULL;
    copy = strdup(path);
    if (!copy)
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    slash = strrchr(copy, '/');
    if (slash) {
        *slash = '\0';
        *leaf = strdup(slash + 1);
    } else {
        *leaf = strdup(copy);
        copy[0] = '\0';
    }
    if (!*leaf || (*leaf)[0] == '\0') {
        free(copy);
        free(*leaf);
        *leaf = NULL;
        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
    }

    current = pengrid_root_duplicate_fd(root_fd);
    if (current < 0) {
        free(copy);
        free(*leaf);
        *leaf = NULL;
        return PENGRID_ZIP_STATUS_IO_ERROR;
    }
    if (copy[0] != '\0') {
        char *cursor = copy;
        char built[PATH_MAX + 1];
        size_t built_length = 0;
        built[0] = '\0';
        while (cursor && *cursor) {
            char *end = strchr(cursor, '/');
            int next;
            if (end)
                *end = '\0';
            next = openat(current, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (next < 0 && errno == ENOENT) {
                if (mkdirat(current, cursor, S_IRWXU) != 0 && errno != EEXIST) {
                    int status = pengrid_root_status_from_errno(errno, 0);
                    close(current);
                    free(copy);
                    free(*leaf);
                    *leaf = NULL;
                    return status;
                }
                next = openat(current, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (next >= 0) {
                    if (built_length > 0) built[built_length++] = '/';
                    size_t component_length = strlen(cursor);
                    if (built_length + component_length >= sizeof(built)) {
                        close(next);
                        close(current);
                        free(copy);
                        free(*leaf);
                        *leaf = NULL;
                        return PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
                    }
                    memcpy(built + built_length, cursor, component_length);
                    built_length += component_length;
                    built[built_length] = '\0';
                    int32_t record_status = pengrid_root_append_created(created, built, 1);
                    if (record_status != PENGRID_ZIP_STATUS_OK) {
                        close(next);
                        close(current);
                        free(copy);
                        free(*leaf);
                        *leaf = NULL;
                        return record_status;
                    }
                }
            }
            if (next < 0) {
                int status = pengrid_root_status_from_errno(errno, 1);
                close(current);
                free(copy);
                free(*leaf);
                *leaf = NULL;
                return status;
            }
            close(current);
            current = next;
            cursor = end ? end + 1 : NULL;
        }
    }
    free(copy);
    *parent_fd = current;
    return PENGRID_ZIP_STATUS_OK;
}

int32_t pengrid_root_probe_path(
    int root_fd,
    const char *normalized_path,
    uint8_t is_directory,
    pengrid_root_created_list *created) {
    int parent = -1;
    char *leaf = NULL;
    int32_t status;

    status = pengrid_root_open_or_create_parent(root_fd, normalized_path, &parent, &leaf, created);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    if (is_directory) {
        if (mkdirat(parent, leaf, S_IRWXU) != 0) {
            status = pengrid_root_status_from_errno(errno, 1);
            goto cleanup;
        } else {
            status = pengrid_root_append_created(created, normalized_path, 1);
            if (status != PENGRID_ZIP_STATUS_OK)
                goto cleanup;
        }
    } else {
        int descriptor = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                S_IRUSR | S_IWUSR);
        if (descriptor < 0) {
            status = pengrid_root_status_from_errno(errno, 1);
            goto cleanup;
        }
        close(descriptor);
        status = pengrid_root_append_created(created, normalized_path, 0);
    }
cleanup:
    close(parent);
    free(leaf);
    return status;
}

int32_t pengrid_root_create_file(
    int root_fd,
    const char *normalized_path,
    pengrid_root_created_list *created,
    int *descriptor) {
    int parent = -1;
    char *leaf = NULL;
    int32_t status = pengrid_root_open_or_create_parent(root_fd, normalized_path, &parent, &leaf, created);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    *descriptor = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                         S_IRUSR | S_IWUSR);
    if (*descriptor < 0) {
        status = pengrid_root_status_from_errno(errno, 1);
        close(parent);
        free(leaf);
        return status;
    }
    status = pengrid_root_append_created(created, normalized_path, 0);
    if (status != PENGRID_ZIP_STATUS_OK) {
        close(*descriptor);
        *descriptor = -1;
    }
    close(parent);
    free(leaf);
    return status;
}

int32_t pengrid_root_create_directory(
    int root_fd,
    const char *normalized_path,
    pengrid_root_created_list *created) {
    int parent = -1;
    char *leaf = NULL;
    int32_t status = pengrid_root_open_or_create_parent(root_fd, normalized_path, &parent, &leaf, created);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    if (mkdirat(parent, leaf, S_IRWXU) != 0) {
        if (errno != EEXIST) {
            status = pengrid_root_status_from_errno(errno, 1);
        } else if (!pengrid_root_created_contains(created, normalized_path, 1)) {
            /* A directory may already exist only when this extraction call
               created it as an implicit parent for another entry. */
            status = PENGRID_ZIP_STATUS_UNSUPPORTED_ENTRY;
        }
    } else {
        status = pengrid_root_append_created(created, normalized_path, 1);
    }
    close(parent);
    free(leaf);
    return status;
}

int32_t pengrid_root_create_symlink(
    int root_fd,
    const char *normalized_path,
    const char *target,
    size_t target_length,
    pengrid_root_created_list *created) {
    int parent = -1;
    char *leaf = NULL;
    char *target_copy;
    int32_t status = pengrid_root_open_or_create_parent(root_fd, normalized_path, &parent, &leaf, created);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    target_copy = (char *)malloc(target_length + 1);
    if (!target_copy) {
        close(parent);
        free(leaf);
        return PENGRID_ZIP_STATUS_INTERNAL_ERROR;
    }
    memcpy(target_copy, target, target_length);
    target_copy[target_length] = '\0';
    if (symlinkat(target_copy, parent, leaf) != 0) {
        status = pengrid_root_status_from_errno(errno, 1);
    } else {
        status = pengrid_root_append_created(created, normalized_path, 0);
    }
    free(target_copy);
    close(parent);
    free(leaf);
    return status;
}

void pengrid_root_created_list_destroy(pengrid_root_created_list *created) {
    if (!created)
        return;
    for (size_t index = 0; index < created->count; index++)
        free(created->entries[index].path);
    free(created->entries);
    memset(created, 0, sizeof(*created));
}

static int32_t pengrid_root_remove_path(int root_fd, const char *path, uint8_t is_directory) {
    int parent = -1;
    char *leaf = NULL;
    int32_t status = pengrid_root_open_parent(root_fd, path, &parent, &leaf);
    if (status != PENGRID_ZIP_STATUS_OK)
        return status;
    int flags = is_directory ? AT_REMOVEDIR : 0;
    if (unlinkat(parent, leaf, flags) != 0 && errno != ENOENT)
        status = PENGRID_ZIP_STATUS_RECOVERY_REQUIRED;
    close(parent);
    free(leaf);
    return status;
}

int32_t pengrid_root_cleanup(int root_fd, pengrid_root_created_list *created) {
    int32_t status = PENGRID_ZIP_STATUS_OK;
    if (root_fd < 0 || !created)
        return PENGRID_ZIP_STATUS_INVALID_ARGUMENT;
    for (size_t index = created->count; index > 0; index--) {
        int32_t remove_status = pengrid_root_remove_path(
            root_fd,
            created->entries[index - 1].path,
            created->entries[index - 1].is_directory
        );
        if (remove_status != PENGRID_ZIP_STATUS_OK)
            status = PENGRID_ZIP_STATUS_RECOVERY_REQUIRED;
    }
    pengrid_root_created_list_destroy(created);
    return status;
}
