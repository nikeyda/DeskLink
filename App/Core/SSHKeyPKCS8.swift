import CommonCrypto
import CryptoKit
import Foundation
import Security

enum SSHKeyPKCS8 {
    private static let encryptedLabel = "ENCRYPTED PRIVATE KEY"
    private static let privateLabel = "PRIVATE KEY"
    private static let pbes2 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D])
    private static let pbkdf2 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C])
    private static let ed25519 = Data([0x2B, 0x65, 0x70])

    static func isEncrypted(_ text: String) -> Bool {
        text.contains("-----BEGIN \(encryptedLabel)-----")
    }

    static func unlock(_ text: String, passphrase: String?) throws -> String {
        var document = DER(bytes: try contents(text, label: encryptedLabel))
        var envelope = try document.sequence()
        var algorithm = try envelope.sequence()
        guard try algorithm.oid() == pbes2 else { throw CocoaError(.fileReadUnsupportedScheme) }
        var parameters = try algorithm.sequence()
        var derivation = try parameters.sequence()
        guard try derivation.oid() == pbkdf2 else { throw CocoaError(.fileReadUnsupportedScheme) }
        var derivationParameters = try derivation.sequence()
        let salt = try derivationParameters.value(0x04)
        let rounds = try derivationParameters.integer()
        let requestedKeyLength = derivationParameters.tag == 0x02 ? try derivationParameters.integer() : nil
        let hash = try readPRF(from: &derivationParameters)

        var cipher = try parameters.sequence()
        let keyLength = try readKeyLength(from: cipher.oid())
        let iv = try cipher.value(0x04)
        let ciphertext = try envelope.value(0x04)
        guard document.isEmpty, envelope.isEmpty, algorithm.isEmpty, parameters.isEmpty, derivation.isEmpty,
              derivationParameters.isEmpty, cipher.isEmpty,
              !salt.isEmpty, salt.count <= 1024, iv.count == kCCBlockSizeAES128,
              !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeAES128),
              requestedKeyLength == nil || requestedKeyLength == keyLength else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard (1...10_000_000).contains(rounds) else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let passphrase, !passphrase.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecPassphraseRequired))
        }

        var key = try deriveKey(passphrase: passphrase, salt: salt, rounds: UInt32(rounds),
                                hash: hash, keyLength: keyLength)
        defer { key.resetBytes(in: 0..<keyLength) }
        let plaintext = try decrypt(ciphertext, key: key, iv: iv)
        let encoded = plaintext.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(privateLabel)-----\n" + encoded + "\n-----END \(privateLabel)-----"
    }

    static func ed25519Key(_ text: String) throws -> Curve25519.Signing.PrivateKey? {
        guard text.contains("-----BEGIN \(privateLabel)-----") else { return nil }
        var document = DER(bytes: try contents(text, label: privateLabel))
        var key = try document.sequence()
        let version = try key.integer()
        var algorithm = try key.sequence()
        guard try algorithm.oid() == ed25519 else { return nil }
        guard (0...1).contains(version), document.isEmpty, algorithm.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var secret = DER(bytes: try key.value(0x04))
        let seed = try secret.value(0x04)
        if key.tag == 0xA0 { _ = try key.value(0xA0) } // Optional attributes.
        let encodedPublicKey = version == 1 && key.tag == 0x81 ? try key.value(0x81) : nil
        guard key.isEmpty, secret.isEmpty, seed.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        let identity = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        if let encodedPublicKey {
            guard encodedPublicKey.first == 0,
                  encodedPublicKey.dropFirst() == identity.publicKey.rawRepresentation else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return identity
    }

    private static func contents(_ text: String, label: String) throws -> Data {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count > 2, lines.first == "-----BEGIN \(label)-----",
              lines.last == "-----END \(label)-----",
              let decoded = Data(base64Encoded: lines.dropFirst().dropLast().joined()),
              !decoded.isEmpty, decoded.count <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        return decoded
    }

    private static func readPRF(from parameters: inout DER) throws -> CCPseudoRandomAlgorithm {
        guard !parameters.isEmpty else { return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1) }
        var prf = try parameters.sequence()
        let oid = try prf.oid()
        if !prf.isEmpty {
            guard try prf.value(0x05).isEmpty, prf.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard oid.count == 8, oid.starts(with: [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02]) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        switch oid.last {
        case 7: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case 8: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
        case 9: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case 10: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case 11: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    private static func readKeyLength(from oid: Data) throws -> Int {
        guard oid.count == 9, oid.starts(with: [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01]) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        switch oid.last {
        case 2: return kCCKeySizeAES128
        case 22: return kCCKeySizeAES192
        case 42: return kCCKeySizeAES256
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    private static func deriveKey(passphrase: String, salt: Data, rounds: UInt32,
                                  hash: CCPseudoRandomAlgorithm, keyLength: Int) throws -> Data {
        let password = passphrase.utf8CString
        var key = Data(count: keyLength)
        let result = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBufferPointer { characters in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), characters.baseAddress, password.count - 1,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, hash, rounds,
                                         output.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        guard result == kCCSuccess else { throw CocoaError(.fileReadUnknown) }
        return key
    }

    private static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var length = 0
        let result = output.withUnsafeMutableBytes { destination in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    ciphertext.withUnsafeBytes { source in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, ciphertext.count,
                                destination.baseAddress, capacity, &length)
                    }
                }
            }
        }
        guard result == kCCSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed))
        }
        return output.prefix(length)
    }

    private struct DER {
        var bytes: Data
        var tag: UInt8? { bytes.first }
        var isEmpty: Bool { bytes.isEmpty }

        mutating func sequence() throws -> Self { Self(bytes: try value(0x30)) }
        mutating func oid() throws -> Data { try value(0x06) }

        mutating func value(_ expectedTag: UInt8) throws -> Data {
            guard tag == expectedTag, let firstLength = bytes.dropFirst().first else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bytes = bytes.dropFirst(2)
            let length: Int
            if firstLength < 128 {
                length = Int(firstLength)
            } else {
                let width = Int(firstLength & 0x7F)
                guard (1...4).contains(width), bytes.count >= width, bytes.first != 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                length = bytes.prefix(width).reduce(0) { $0 * 256 + Int($1) }
                guard length >= 128 else { throw CocoaError(.fileReadCorruptFile) }
                bytes = bytes.dropFirst(width)
            }
            guard length <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            let result = bytes.prefix(length)
            bytes = bytes.dropFirst(length)
            return result
        }

        mutating func integer() throws -> Int {
            let amount = try value(0x02)
            guard let first = amount.first, first < 128, amount.count <= 4,
                  amount.count < 2 || first != 0 || (amount.dropFirst().first ?? 0) >= 128 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return amount.reduce(0) { $0 * 256 + Int($1) }
        }
    }
}
