# SwiftNIO SSH in Telescope

This directory contains the package manifest, sources, tests and license from
[SwiftNIO SSH 0.15.2](https://github.com/apple/swift-nio-ssh/tree/e8de09a26d3d0a6ecf509fe0554bd27a6f9ee3d0).

Telescope adds RSA-SHA2 user authentication according to RFC 8332, using
Swift Crypto for PKCS#1 v1.5 signatures with SHA-512 and SHA-256.
It reads `server-sig-algs` (RFC 8308) to select the algorithm before authenticating.
RSA host keys support the same SHA-2 algorithms. The client checks that the
server signature matches the algorithm negotiated during key exchange and
uses the standard SSH public-key encoding for the existing fingerprint
check. The vendored package does not advertise SHA-1 signatures.

When updating the dependency, run `script/test_ssh.sh` from the project root.
Use `DESKLINK_FIXTURE_RSA_ALGORITHM=rsa-sha2-256` to exercise algorithm selection with
a peer that accepts only RSA-SHA2-256. Set `DESKLINK_FIXTURE_HOST_ALGORITHM`
to `rsa-sha2-256` or `rsa-sha2-512` to use an RSA-only gateway.
