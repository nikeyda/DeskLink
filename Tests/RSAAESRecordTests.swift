import Foundation
import RFBProtocol
@testable import RFBTransport
import XCTest

final class RSAAESRecordTests: XCTestCase {
    func testEAXRecordsMatchNettleAndRejectAlterationOrReuse() throws {
        // Independently generated with Nettle AES-EAX. The nonce is a 16-byte
        // little-endian record index and the 2-byte length is associated data.
        let reference = [
            ["000c2ada047fa3e35f6f42bec3b24d893b70ea57f9d06c1e80e9707fea6e",
             "000cb242d2c1e4b7b5fdcd24a44e37472ff3aef6e4765d8d39592ca95afe"],
            ["000c871ba785cfccae52e1d1255df859f8af291b457ede65f009cff40eba",
             "000c7302f6339c3a5183fae7631e6c963523077cba98ceb622347201b531"]
        ]
        let payload = Data("RFB keyboard".utf8)
        for (keySize, records) in zip([16, 32], reference) {
            let key = Data((0..<keySize).map(UInt8.init))
            var sender = RFBEAXCipher(key: key)
            var receiver = RFBEAXCipher(key: key)
            for expected in records {
                let record = try sender.seal(payload)
                XCTAssertEqual(record.map { String(format: "%02x", $0) }.joined(), expected)
                let header = record.prefix(2), ciphertext = record.dropFirst(2).dropLast(16), tag = record.suffix(16)
                var altered = Data(tag)
                altered[0] ^= 1
                XCTAssertThrowsError(try receiver.open(header: header, ciphertext: ciphertext, tag: altered))
                XCTAssertThrowsError(try receiver.open(header: Data([0, 13]), ciphertext: ciphertext, tag: tag))
                XCTAssertEqual(try receiver.open(header: header, ciphertext: ciphertext, tag: tag), payload)
                XCTAssertThrowsError(try receiver.open(header: header, ciphertext: ciphertext, tag: tag))
            }
        }
    }

    func testAutomaticUsesThePreferredEncryptedFamilyAndExplicitRSAUsesTheStrongestRSA() {
        let cases: [([SecurityType], VNCSecurityPolicy, SecurityType)] = [
            ([.vencrypt, .rsaAES256, .rsaAES], .automatic, .vencrypt),
            ([.none, .rsaAES, .vencrypt, .rsaAES256], .automatic, .rsaAES256),
            ([.vncAuthentication, .rsaAES], .automatic, .rsaAES),
            ([.vencrypt, .rsaAES256, .rsaAES], .rsaAES, .rsaAES256)
        ]
        for (offer, policy, expected) in cases {
            var machine = ConnectionStateMachine(securityPolicy: policy)
            _ = machine.handle(event: .connected)
            _ = machine.handle(event: .receivedProtocolVersion(.v3_8))
            _ = machine.handle(event: .receivedSecurityTypes(offer))
            XCTAssertEqual(machine.selectedSecurityType, expected)
        }
    }

    func testEncryptedPoliciesKeepTheirGuaranteesForOfferedAndServerSelectedTypes() {
        for policy in [VNCSecurityPolicy.rsaAES, .requireEncryption] {
            for version in [ProtocolVersion.v3_3, .v3_8] {
                for type in [SecurityType.none, .vncAuthentication, .unknown(6), .unknown(130), .vencrypt, .rsaAES, .rsaAES256] {
                    var machine = ConnectionStateMachine(securityPolicy: policy)
                    _ = machine.handle(event: .connected)
                    _ = machine.handle(event: .receivedProtocolVersion(version))
                    _ = machine.handle(event: version == .v3_3 ? .receivedServerSelectedSecurityType(type) : .receivedSecurityTypes([type]))
                    let allowed = [.rsaAES, .rsaAES256].contains(type) || (type == .vencrypt && policy == .requireEncryption)
                    XCTAssertEqual(machine.selectedSecurityType, allowed ? type : nil)
                }
            }
        }
    }
}
