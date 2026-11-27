#pragma once
#include <stddef.h>
#include <stdint.h>

typedef enum {
    DLOpenSSHAESModeCTR,
    DLOpenSSHAESModeCBC,
} DLOpenSSHAESMode;

/// Opens one encrypted OpenSSH key payload using the passphrase supplied by
/// its owner. The surrounding SSH container and public key are verified in Swift.
int DLDecryptOpenSSHKey(const uint8_t *passphrase, size_t passphraseLength,
                        const uint8_t *salt, size_t saltLength, uint32_t rounds,
                        DLOpenSSHAESMode mode, size_t aesKeyBytes,
                        const uint8_t *ciphertext, size_t length, uint8_t *plaintext);
