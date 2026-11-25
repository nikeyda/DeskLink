import Darwin
import Foundation

struct Endpoint: Codable, Hashable, Sendable {
    let host: String
    let port: UInt16

    enum ParseError: Error, Equatable {
        case invalidAddress, invalidPort
    }

    init(address: String, defaultPort: UInt16 = 5900) throws {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, defaultPort != 0,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ParseError.invalidAddress
        }
        if let separator = text.range(of: "://") {
            guard ["vnc", "desklink"].contains(text[..<separator.lowerBound].lowercased()) else {
                throw ParseError.invalidAddress
            }
            text = String(text[separator.upperBound...])
            if text.hasSuffix("/") { text.removeLast() }
        }
        guard !text.isEmpty, text.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@\\")) == nil else {
            throw ParseError.invalidAddress
        }

        var hostText = text
        var portText: Substring?
        if text.first == "[" {
            guard let close = text.firstIndex(of: "]") else { throw ParseError.invalidAddress }
            hostText = String(text[text.index(after: text.startIndex)..<close])
            guard Self.isIPv6(hostText) else { throw ParseError.invalidAddress }
            let remainder = text[text.index(after: close)...]
            if !remainder.isEmpty {
                guard remainder.first == ":" else { throw ParseError.invalidAddress }
                portText = remainder.dropFirst()
            }
        } else if text.filter({ $0 == ":" }).count == 1, let separator = text.firstIndex(of: ":") {
            hostText = String(text[..<separator])
            portText = text[text.index(after: separator)...]
        }
        if hostText.contains(":") {
            guard Self.isIPv6(hostText) else { throw ParseError.invalidAddress }
        } else {
            guard Self.isHostname(hostText) else { throw ParseError.invalidAddress }
        }
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = UInt16(portText), value != 0 else { throw ParseError.invalidPort }
            port = value
        } else {
            port = defaultPort
        }
        host = hostText.lowercased()
    }

    var address: String {
        let printableHost = host.contains(":") ? "[\(host)]" : host
        return port == 5900 ? printableHost : "\(printableHost):\(port)"
    }

    static func hostOnly(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = try Endpoint(address: text).host
        guard text == host || text == "[\(host)]" else { throw ParseError.invalidAddress }
        return host
    }

    private static func isHostname(_ text: String) -> Bool {
        let value = text.hasSuffix(".") ? String(text.dropLast()) : text
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            var result = in_addr()
            return inet_pton(AF_INET, value, &result) == 1
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }
    }

    private static func isIPv6(_ text: String) -> Bool {
        let components = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = components.first else { return false }
        if components.count == 2 {
            let zone = components[1]
            guard !zone.isEmpty, zone.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        }
        var result = in6_addr()
        return inet_pton(AF_INET6, String(address), &result) == 1
    }

    enum CodingKeys: CodingKey { case host, port }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hostname = try container.decode(String.self, forKey: .host)
        let number = try container.decode(UInt16.self, forKey: .port)
        let parsed = try Self(address: hostname, defaultPort: number)
        guard hostname.lowercased() == parsed.host, number == parsed.port else {
            throw ParseError.invalidAddress
        }
        self = parsed
    }
}
