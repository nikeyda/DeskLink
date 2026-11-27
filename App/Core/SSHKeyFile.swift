import CryptoKit
import Foundation
import NIOSSH
import OpenSSHKeyImport
import Security

enum SSHKeyFile {
    /// Returns a key ready for the session, or for the device Keychain when
    /// the user explicitly chose to remember it. The passphrase is never saved.
    static func opened(_ text: String, passphrase: String? = nil) throws -> String {
        if SSHKeyPKCS8.isEncrypted(text) {
            let key = try SSHKeyPKCS8.unlock(text, passphrase: passphrase)
            guard (try? identity(key)) != nil else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
            }
            return key
        }
        guard text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            _ = try identity(text)
            return text
        }
        var container = try reader(for: text)
        let cipher = try container.field(), kdf = try container.field(), options = try container.field()
        if cipher == Data("none".utf8) {
            _ = try identity(text)
            return text
        }
        let keyLength: Int
        let mode: DLOpenSSHAESMode
        switch String(decoding: cipher, as: UTF8.self) {
        case "aes128-ctr": (keyLength, mode) = (16, DLOpenSSHAESModeCTR)
        case "aes192-ctr": (keyLength, mode) = (24, DLOpenSSHAESModeCTR)
        case "aes256-ctr": (keyLength, mode) = (32, DLOpenSSHAESModeCTR)
        case "aes128-cbc": (keyLength, mode) = (16, DLOpenSSHAESModeCBC)
        case "aes192-cbc": (keyLength, mode) = (24, DLOpenSSHAESModeCBC)
        case "aes256-cbc": (keyLength, mode) = (32, DLOpenSSHAESModeCBC)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard kdf == Data("bcrypt".utf8), try container.integer() == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        var parameters = Reader(data: options)
        let salt = try parameters.field(), rounds = try parameters.integer()
        let publicKey = try container.field(), encrypted = try container.field()
        guard parameters.data.isEmpty, container.data.isEmpty, !salt.isEmpty, salt.count <= 1024,
              !encrypted.isEmpty, encrypted.count.isMultiple(of: 16), encrypted.count <= 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard (1...4096).contains(rounds) else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let passphrase, !passphrase.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecPassphraseRequired))
        }
        var plain = [UInt8](repeating: 0, count: encrypted.count)
        let status = DLDecryptOpenSSHKey(Array(passphrase.utf8), passphrase.utf8.count, Array(salt), salt.count,
                                         UInt32(rounds), mode, keyLength, Array(encrypted), encrypted.count, &plain)
        guard status == 0 else { throw CocoaError(.fileReadUnknown) }
        var checks = Reader(data: Data(plain))
        guard try checks.integer() == checks.integer() else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
        }
        var envelope = prefix
        func field(_ bytes: Data) {
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { envelope.append(contentsOf: $0) }
            envelope.append(bytes)
        }
        field(Data("none".utf8))
        field(Data("none".utf8))
        field(Data())
        withUnsafeBytes(of: UInt32(1).bigEndian) { envelope.append(contentsOf: $0) }
        field(publicKey)
        field(Data(plain))
        let encoded = envelope.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let result = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + encoded + "\n-----END OPENSSH PRIVATE KEY-----"
        _ = try identity(result)
        return result
    }

    static func identity(_ text: String) throws -> NIOSSHPrivateKey {
        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return try openSSH(text) }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return .init(p256Key: key) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return .init(p384Key: key) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return .init(p521Key: key) }
        if let key = try? SSHKeyPKCS8.ed25519Key(text) { return .init(ed25519Key: key) }
        return try NIOSSHPrivateKey(rsaPEM: text)
    }

    private static let prefix = Data("openssh-key-v1\0".utf8)

    private static func reader(for text: String) throws -> Reader {
        let encoded = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: encoded), data.starts(with: prefix) else { throw CocoaError(.fileReadCorruptFile) }
        return Reader(data: data.dropFirst(prefix.count))
    }

    private static func openSSH(_ text: String) throws -> NIOSSHPrivateKey {
        var container = try reader(for: text)
        let cipher = try container.field(), kdf = try container.field(), options = try container.field()
        guard cipher == Data("none".utf8), kdf == cipher, options.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecPassphraseRequired))
        }
        guard try container.integer() == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
        let publicBlob = try container.field()
        var secret = Reader(data: try container.field())
        guard container.data.isEmpty, try secret.integer() == secret.integer() else { throw CocoaError(.fileReadCorruptFile) }
        let type = String(decoding: try secret.field(), as: UTF8.self)
        let result: NIOSSHPrivateKey
        if type == "ssh-ed25519" {
            let publicBytes = try secret.field(), pair = try secret.field()
            guard publicBytes.count == 32, pair.count == 64, pair.suffix(32) == publicBytes else { throw CocoaError(.fileReadCorruptFile) }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: pair.prefix(32))
            guard key.publicKey.rawRepresentation == publicBytes else { throw CocoaError(.fileReadCorruptFile) }
            result = NIOSSHPrivateKey(ed25519Key: key)
        } else if type == "ssh-rsa" {
            let modulus = try secret.positiveInteger(maximumBytes: 2_048)
            let exponent = try secret.positiveInteger(maximumBytes: 8)
            let privateExponent = try secret.positiveInteger(maximumBytes: modulus.count)
            _ = try secret.positiveInteger(maximumBytes: modulus.count) // CRT coefficient, recomputed by CryptoExtras.
            let prime1 = try secret.positiveInteger(maximumBytes: modulus.count)
            let prime2 = try secret.positiveInteger(maximumBytes: modulus.count)
            result = try NIOSSHPrivateKey(rsaModulus: modulus, publicExponent: exponent,
                                        privateExponent: privateExponent, prime1: prime1, prime2: prime2)
        } else {
            let curve = String(decoding: try secret.field(), as: UTF8.self)
            guard type == "ecdsa-sha2-" + curve else { throw CocoaError(.fileReadUnsupportedScheme) }
            let publicBytes = try secret.field(), scalar = try secret.field()
            guard let first = scalar.first, first < 128 else { throw CocoaError(.fileReadCorruptFile) }
            let unsigned = scalar.drop(while: { $0 == 0 })
            func bytes(_ width: Int) throws -> Data {
                guard !unsigned.isEmpty, unsigned.count <= width else { throw CocoaError(.fileReadCorruptFile) }
                return Data(repeating: 0, count: width - unsigned.count) + unsigned
            }
            let derived: Data
            switch curve {
            case "nistp256":
                let key = try P256.Signing.PrivateKey(rawRepresentation: bytes(32))
                derived = key.publicKey.x963Representation; result = .init(p256Key: key)
            case "nistp384":
                let key = try P384.Signing.PrivateKey(rawRepresentation: bytes(48))
                derived = key.publicKey.x963Representation; result = .init(p384Key: key)
            case "nistp521":
                let key = try P521.Signing.PrivateKey(rawRepresentation: bytes(66))
                derived = key.publicKey.x963Representation; result = .init(p521Key: key)
            default: throw CocoaError(.fileReadUnsupportedScheme)
            }
            guard derived == publicBytes else { throw CocoaError(.fileReadCorruptFile) }
        }
        _ = try secret.field() // OpenSSH comment.
        guard secret.data.enumerated().allSatisfy({ $0.offset < 255 && $0.element == UInt8($0.offset + 1) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let advertised = String(openSSHPublicKey: result.publicKey).split(separator: " ")
        guard advertised.count >= 2, Data(base64Encoded: String(advertised[1])) == publicBlob else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }

    private struct Reader {
        var data: Data
        mutating func integer() throws -> Int {
            guard data.count >= 4 else { throw CocoaError(.fileReadCorruptFile) }
            let value = data.prefix(4).reduce(0) { $0 * 256 + Int($1) }
            data = data.dropFirst(4)
            return value
        }
        mutating func positiveInteger(maximumBytes: Int) throws -> Data {
            let bytes = try field()
            let magnitude = bytes.first == 0 ? bytes.dropFirst() : bytes[...]
            guard let leading = bytes.first, leading < 128,
                  let first = magnitude.first, first != 0,
                  (leading != 0 || first >= 128), magnitude.count <= maximumBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Data(magnitude)
        }
        mutating func field() throws -> Data {
            let length = try integer()
            guard length <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            let value = Data(data.prefix(length))
            data = data.dropFirst(length)
            return value
        }
    }
}
