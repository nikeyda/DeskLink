# SwiftNIO SSH in Telescope

This directory contains the package manifest, sources, tests and license from
[SwiftNIO SSH 0.15.2](https://github.com/apple/swift-nio-ssh/tree/e8de09a26d3d0a6ecf509fe0554bd27a6f9ee3d0).

Telescope adds RSA-SHA2 user authentication according to RFC 8332, using
Swift Crypto for PKCS#1 v1.5 signatures with SHA-512 and SHA-256.
It reads `server-sig-algs` (RFC 8308) to select the algorithm before authenticating.
SSH host key negotiation and its application trust checks use the existing
algorithms. The vendored package does not advertise SHA-1 signatures.

When updating the dependency, run `script/test_ssh.sh` from the project root.
Use `DESKLINK_FIXTURE_RSA_ALGORITHM=rsa-sha2-256` to exercise algorithm selection with
a peer that accepts only RSA-SHA2-256.
