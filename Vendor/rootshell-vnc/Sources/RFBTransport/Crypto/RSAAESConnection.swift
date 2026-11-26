import Crypto
import CryptoExtras
import Darwin
import Foundation
import RFBProtocol

/// The RSA-AES record layer used by RFB security types 5 and 129.
/// Each direction has its own key and little-endian 128-bit record counter.
struct RFBEAXCipher {
    let key: SymmetricKey
    private var counter = Data(repeating: 0, count: 16)

    init(key: Data) { self.key = SymmetricKey(data: key) }

    private func mac(domain: UInt8, data: Data) throws -> Data {
        var mac = try AES.CMAC(key: key)
        mac.update(data: Data(repeating: 0, count: 15) + [domain])
        mac.update(data: data)
        return mac.finalize().withUnsafeBytes { Data($0) }
    }

    private func tag(nonceMAC: Data, header: Data, ciphertext: Data) throws -> Data {
        var result = nonceMAC
        let headerMAC = try mac(domain: 1, data: header)
        let payloadMAC = try mac(domain: 2, data: ciphertext)
        for i in 0..<16 { result[i] ^= headerMAC[i] ^ payloadMAC[i] }
        return result
    }

    private mutating func advance() throws {
        for i in counter.indices {
            counter[i] &+= 1
            if counter[i] != 0 { return }
        }
        throw VNCProtocolError.protocolViolation("RSA-AES record limit reached")
    }

    mutating func seal(_ plaintext: Data) throws -> Data {
        guard let length = UInt16(exactly: plaintext.count) else {
            throw VNCProtocolError.protocolViolation("Oversized RSA-AES record")
        }
        let header = Data([UInt8(length >> 8), UInt8(truncatingIfNeeded: length)])
        let nonceMAC = try mac(domain: 0, data: counter)
        let nonce = try AES._CTR.Nonce(nonceBytes: nonceMAC)
        let ciphertext = try AES._CTR.encrypt(plaintext, using: key, nonce: nonce)
        let result = try header + ciphertext + tag(nonceMAC: nonceMAC, header: header, ciphertext: ciphertext)
        try advance()
        return result
    }

    mutating func open(header: Data, ciphertext: Data, tag received: Data) throws -> Data {
        let nonceMAC = try mac(domain: 0, data: counter)
        let expected = try tag(nonceMAC: nonceMAC, header: header, ciphertext: ciphertext)
        guard received.count == 16, expected.withUnsafeBytes({ left in
            received.withUnsafeBytes { right in timingsafe_bcmp(left.baseAddress!, right.baseAddress!, 16) == 0 }
        }) else { throw VNCProtocolError.protocolViolation("Invalid RSA-AES record tag") }
        let nonce = try AES._CTR.Nonce(nonceBytes: nonceMAC)
        let plaintext = try AES._CTR.decrypt(ciphertext, using: key, nonce: nonce)
        try advance()
        return plaintext
    }
}

actor RSAAESConnection: RFBConnection {
    private let base: any RFBConnection
    private var sender: RFBEAXCipher
    private var receiver: RFBEAXCipher
    private var buffered = Data()
    private var closed = false

    init(base: any RFBConnection, sendKey: Data, receiveKey: Data) {
        self.base = base
        self.sender = RFBEAXCipher(key: sendKey)
        self.receiver = RFBEAXCipher(key: receiveKey)
    }

    func connect() async throws { throw VNCProtocolError.protocolViolation("RSA-AES channel already connected") }
    func close() async {
        guard !closed else { return }
        closed = true
        buffered = Data()
        await base.close()
    }
    func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {
        await base.setDisconnectHandler(handler)
    }
    func pathCharacteristics() async -> NetworkPathCharacteristics? { await base.pathCharacteristics() }
    func remoteEndpointHost() async -> String? { await base.remoteEndpointHost() }
    func isOnLocalNetwork() async -> Bool { await base.isOnLocalNetwork() }

    func send(_ data: Data) async throws {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        var records = Data()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = offset + min(data.endIndex - offset, Int(UInt16.max))
            records.append(try sender.seal(data[offset..<end]))
            offset = end
        }
        guard !records.isEmpty else { return }
        do { try await base.send(records) }
        catch { await close(); throw error }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        guard maxCount > 0 else { return Data() }
        while buffered.isEmpty {
            let header = try await base.read(exactly: 2)
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            let body = try await base.read(exactly: length + 16)
            guard !closed else { throw VNCProtocolError.connectionClosed }
            do { buffered = try receiver.open(header: header, ciphertext: body.prefix(length), tag: body.suffix(16)) }
            catch { await close(); throw error }
        }
        let count = min(buffered.count, maxCount)
        let bytes = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        return bytes
    }

    func read(exactly count: Int) async throws -> Data {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        guard (0...TCPConnection.maxExactReadBytes).contains(count) else {
            throw VNCProtocolError.protocolViolation("Invalid RSA-AES stream read length")
        }
        var result = Data()
        while result.count < count { result.append(try await read(upTo: count - result.count)) }
        return result
    }
}
