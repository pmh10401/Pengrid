#ifndef PENGRID_ROOT_WRITER_H
#define PENGRID_ROOT_WRITER_H

#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pengrid_root_created_entry_s {
    char *path;
    uint8_t is_directory;
    mode_t object_type;
    dev_t device;
    ino_t inode;
    mode_t mode;
} pengrid_root_created_entry;

typedef struct pengrid_root_created_list_s {
    pengrid_root_created_entry *entries;
    size_t count;
    size_t capacity;
} pengrid_root_created_list;

int32_t pengrid_root_duplicate_fd(int fd);
int32_t pengrid_root_verify_identity(int root_fd, dev_t device, ino_t inode);
int32_t pengrid_root_is_empty(int root_fd);
int32_t pengrid_root_validate_path(
    int root_fd,
    const char *path,
    size_t path_length,
    char **normalized_path);
int32_t pengrid_root_validate_link_target(
    const char *parent_path,
    const char *target,
    size_t target_length);
int32_t pengrid_root_probe_path(
    int root_fd,
    const char *normalized_path,
    uint8_t is_directory,
    pengrid_root_created_list *created);
int32_t pengrid_root_create_file(
    int root_fd,
    const char *normalized_path,
    pengrid_root_created_list *created,
    int *descriptor);
int32_t pengrid_root_create_directory(
    int root_fd,
    const char *normalized_path,
    pengrid_root_created_list *created);
int32_t pengrid_root_create_symlink(
    int root_fd,
    const char *normalized_path,
    const char *target,
    size_t target_length,
    pengrid_root_created_list *created);
void pengrid_root_created_list_destroy(pengrid_root_created_list *created);
int32_t pengrid_root_cleanup(int root_fd, pengrid_root_created_list *created);
int32_t pengrid_root_apply_file_metadata(int descriptor, mode_t mode, time_t modified_date);
int32_t pengrid_root_apply_directory_metadata(
    int root_fd,
    const char *normalized_path,
    mode_t mode,
    time_t modified_date);

/* Internal deterministic seams used by the native reader tests. */
void pengrid_root_test_fail_next_tracking(void);
void pengrid_root_test_fail_next_cleanup(void);
void pengrid_root_test_substitute_next_cleanup_object(void);
void pengrid_root_test_fail_next_identity_stat(void);
void pengrid_root_test_fail_next_symlink_identity_stat(void);
void pengrid_root_test_fail_next_rollback(void);

#ifdef __cplusplus
}
#endif

#endif
