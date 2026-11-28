import Foundation
import RFBProtocol

struct SupportDiagnostics: Encodable {
    struct Failure: Identifiable, Codable, Equatable {
        enum Reason: String, Codable {
            case authentication, unsupportedVersion, unsupportedEncoding, protocolError, closed, timeout, transport, unknown

            init(_ error: VNCProtocolError?) {
                switch error {
                case .authenticationFailed, .sshAuthenticationFailed: self = .authentication
                case .unsupportedVersion: self = .unsupportedVersion
                case .unsupportedEncoding: self = .unsupportedEncoding
                case .unexpectedMessage, .protocolViolation: self = .protocolError
                case .connectionClosed: self = .closed
                case .timeout: self = .timeout
                case .ioError, .sshHostIdentityRejected, .localNetworkAccessDenied: self = .transport
                case nil: self = .unknown
                }
            }
        }

        var id = UUID()
        let date: Date
        let reason: Reason
        let usesSSH: Bool
        let requestsHighPerformance: Bool
        let version: String?
        let securityType: UInt8?
    }

    static let recordLimit = 30
    let formatVersion = 1
    let exportedAt: Date
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let connections: [ConnectionReport]
    let failures: [Failure]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
