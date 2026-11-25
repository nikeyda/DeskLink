#include "includes.h"
#include "include/OpenSSHKeyImport.h"
#include <CommonCrypto/CommonCryptor.h>

int desklink_bcrypt_pbkdf(const char *, size_t, const uint8_t *, size_t, uint8_t *, size_t, unsigned int);

int DLDecryptOpenSSHKey(const uint8_t *passphrase, size_t passphraseLength,
                        const uint8_t *salt, size_t saltLength, uint32_t rounds,
                        size_t aesKeyBytes, const uint8_t *ciphertext, size_t length,
                        uint8_t *plaintext) {
    if (!passphrase || !salt || !ciphertext || !plaintext || !length ||
        length % kCCBlockSizeAES128 || (aesKeyBytes != 16 && aesKeyBytes != 32)) return -1;
    uint8_t keyAndIV[32 + kCCBlockSizeAES128] = {0};
    if (desklink_bcrypt_pbkdf((const char *)passphrase, passphraseLength, salt, saltLength,
                              keyAndIV, aesKeyBytes + kCCBlockSizeAES128, rounds) != 0) {
        explicit_bzero(keyAndIV, sizeof(keyAndIV));
        return -1;
    }
    CCCryptorRef aes = NULL;
    CCCryptorStatus status = CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES,
        ccNoPadding, keyAndIV + aesKeyBytes, keyAndIV, aesKeyBytes, NULL, 0, 0, kCCModeOptionCTR_BE, &aes);
    size_t produced = 0;
    if (status == kCCSuccess)
        status = CCCryptorUpdate(aes, ciphertext, length, plaintext, length, &produced);
    if (aes) CCCryptorRelease(aes);
    explicit_bzero(keyAndIV, sizeof(keyAndIV));
    return status == kCCSuccess && produced == length ? 0 : -1;
}
