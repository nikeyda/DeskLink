# OpenSSH key import

The three OpenBSD files come from the portable OpenSSH 10.2p1 release. Their copyright and license notices remain in the source and are included in the application's acknowledgements. [Upstream release](https://github.com/openssh/openssh-portable/tree/d01efaa1c9ed84fd9011201dbc3c7cb0a82bcee3/openbsd-compat)

The Apple-platform adapter uses CommonCrypto for SHA-512 and AES-CTR. The client imports a private key selected by the user and asks for its passphrase when required. [OpenSSH private key format](https://github.com/openssh/openssh-portable/blob/d01efaa1c9ed84fd9011201dbc3c7cb0a82bcee3/PROTOCOL.key)
