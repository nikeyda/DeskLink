#pragma once
#include <CommonCrypto/CommonDigest.h>
#define crypto_hash_sha512_BYTES CC_SHA512_DIGEST_LENGTH
#define crypto_hash_sha512(out, in, len) CC_SHA512((in), (CC_LONG)(len), (out))
