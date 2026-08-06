#ifndef PENGRID_ZIP_WRITER_H
#define PENGRID_ZIP_WRITER_H

#include <stdint.h>
#include "pengrid_encrypted_zip.h"

/* Internal deterministic seam used by overflow tests. */
void pengrid_zip_test_override_next_regular_size(uint64_t size);

#endif
