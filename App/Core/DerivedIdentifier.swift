import CryptoKit
import Foundation

extension UUID {
    /// Version 8 UUID for a namespaced local identifier, stable across exports and devices.
    static func derived(from identity: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
