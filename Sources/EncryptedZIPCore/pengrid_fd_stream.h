#ifndef PENGRID_FD_STREAM_H
#define PENGRID_FD_STREAM_H

#include "mz.h"
#include "mz_strm.h"

#ifdef __cplusplus
extern "C" {
#endif

void *pengrid_fd_stream_create(int archive_fd);

#ifdef __cplusplus
}
#endif

#endif
