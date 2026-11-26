import Crypto
import CryptoExtras
import Foundation
import RFBProtocol

/// Receives the SHA-256 fingerprint of the server's DER SubjectPublicKeyInfo.
public typealias VNCRSAHostValidationHandler = @Sendable (_ host: String, _ port: UInt16, _ fingerprint: String) async -> Bool

struct RSAAESAuthenticator {
    let use256: Bool
    let host: String
    let port: UInt16
    let validate: VNCRSAHostValidationHandler?
    let username: String?
    let password: String

    private var secretLength: Int { use256 ? 32 : 16 }
    private func digest(_ data: Data) -> Data {
        use256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
    }

    func authenticate(connection: any RFBConnection) async throws -> RSAAESConnection {
        let keyHeader = try await connection.read(exactly: 4)
        let bits = keyHeader.reduce(0) { ($0 << 8) | Int($1) }
        guard (2048...8192).contains(bits) else {
            throw VNCProtocolError.authenticationFailed("RSA host key must be between 2048 and 8192 bits")
        }
        let size = (bits + 7) / 8
        let modulus = try await connection.read(exactly: size)
        let exponent = try await connection.read(exactly: size)
        let peer = try _RSA.Encryption.PublicKey(n: modulus, e: Data(exponent.drop(while: { $0 == 0 })))
        guard peer.keySizeInBits == bits else { throw VNCProtocolError.protocolViolation("Invalid RSA modulus length") }
        let fingerprint = Data(SHA256.hash(data: peer.derRepresentation)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard await validate?(host, port, "SHA256:" + fingerprint) == true else {
            throw VNCProtocolError.authenticationFailed("The RSA host key was not trusted")
        }
        try Task.checkCancellation()
        let peerWire = keyHeader + modulus + exponent
        let local = try _RSA.Encryption.PrivateKey(keySize: .bits2048)
        let parts = try local.publicKey.getKeyPrimitives()
        guard parts.modulus.count == 256, parts.publicExponent.count <= 256 else {
            throw VNCProtocolError.protocolViolation("Invalid local RSA key")
        }
        let localWire = Data([0,0,8,0]) + parts.modulus + Data(repeating: 0, count: 256 - parts.publicExponent.count) + parts.publicExponent
        try await connection.send(localWire)

        let localRandom = SymmetricKey(size: use256 ? .bits256 : .bits128).withUnsafeBytes { Data($0) }
        // Both peers write their encrypted random before waiting for the peer's random.
        let encrypted = try peer.encrypt(localRandom, padding: ._WEAK_AND_INSECURE_PKCS_V1_5)
        let count = encrypted.count
        try await connection.send(Data([UInt8(count >> 8), UInt8(truncatingIfNeeded: count)]) + encrypted)
        let replyLength = try await connection.read(exactly: 2).reduce(0) { ($0 << 8) | Int($1) }
        guard replyLength == 256 else { throw VNCProtocolError.protocolViolation("Invalid RSA random length") }
        let reply = try await connection.read(exactly: replyLength)
        let peerRandom = try local.decrypt(reply, padding: ._WEAK_AND_INSECURE_PKCS_V1_5)
        guard peerRandom.count == secretLength else { throw VNCProtocolError.protocolViolation("Invalid RSA exchange") }
        let secure = RSAAESConnection(base: connection, sendKey: digest(peerRandom + localRandom).prefix(secretLength),
                                      receiveKey: digest(localRandom + peerRandom).prefix(secretLength))
        try await secure.send(digest(localWire + peerWire))
        let expected = digest(peerWire + localWire)
        guard try await secure.read(exactly: expected.count) == expected else {
            throw VNCProtocolError.authenticationFailed("RSA host key confirmation failed")
        }
        let subtype = try await secure.read(exactly: 1).first
        guard subtype == 1 || subtype == 2 else { throw VNCProtocolError.authenticationFailed("Unknown RSA-AES credential type") }
        let user = Data((subtype == 1 ? username ?? "" : "").utf8)
        let pass = Data(password.utf8)
        guard let userLength = UInt8(exactly: user.count), let passLength = UInt8(exactly: pass.count) else {
            throw VNCProtocolError.authenticationFailed("RSA-AES credentials exceed 255 UTF-8 bytes")
        }
        try await secure.send(Data([userLength]) + user + [passLength] + pass)
        return secure
    }
}
