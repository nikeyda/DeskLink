#pragma once
#define __STDC_WANT_LIB_EXT1__ 1
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define HAVE_STDLIB_H 1
#define bcrypt_pbkdf desklink_bcrypt_pbkdf
static inline void explicit_bzero(void *buffer, size_t size) {
    memset_s(buffer, size, 0, size);
}
static inline void freezero(void *buffer, size_t size) {
    explicit_bzero(buffer, size);
    free(buffer);
}
#include "blf.h"
