import Foundation

/// A link can carry a password for one connection. Its original text and password have no archive representation.
struct DesktopLink: Equatable {
    enum Target: Equatable {
        case address(Endpoint)
        case savedName(String)
    }

    let target: Target
    let sshPort: UInt16?
    let username: String?
    let password: String?
    let observe: Bool?
    let requestsGuest: Bool
    let keyName: String?

    init(text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 8192, !text.contains("#"), let separator = text.range(of: "://") else {
            throw URLError(.badURL)
        }
        let scheme = text[..<separator.lowerBound].lowercased()
        guard ["vnc", "screens", "ssh"].contains(scheme) else { throw URLError(.badURL) }
        let parts = text[separator.upperBound...].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard var authority = parts.first else { throw URLError(.badURL) }
        if authority.hasSuffix("/") { authority = authority.dropLast() }
        guard !authority.isEmpty, !authority.contains("/"), !authority.contains("\\") else { throw URLError(.badURL) }
        let login = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard login.count <= 2, let encodedHost = login.last, !encodedHost.isEmpty else { throw URLError(.badURL) }
        if login.count == 2 {
            let fields = login[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard !login[0].isEmpty else { throw URLError(.badURL) }
            username = try Self.decode(fields[0])
            password = fields.count == 2 ? try Self.decode(fields[1]) : nil
        } else {
            username = nil
            password = nil
        }
        let host = try Self.decode(encodedHost)
        guard !host.isEmpty else { throw URLError(.badURL) }
        if scheme != "screens", host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@\\")) != nil {
            throw URLError(.badURL)
        }
        switch scheme {
        case "screens":
            target = .savedName(host)
            sshPort = nil
        case "ssh":
            let tunnel = try Endpoint(address: host, defaultPort: 22)
            target = .address(try Endpoint(address: tunnel.host))
            sshPort = tunnel.port
        default:
            target = .address(try Endpoint(address: host))
            sshPort = nil
        }

        var options: [String: String] = [:]
        if parts.count == 2 {
            for parameter in parts[1].split(separator: "&", omittingEmptySubsequences: false) {
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw URLError(.badURL) }
                let key = String(pair[0])
                guard ["guest", "observe", "ssh-key"].contains(key), options[key] == nil else { throw URLError(.badURL) }
                let value = try Self.decode(pair[1])
                if key == "ssh-key" {
                    guard scheme == "ssh", !value.trimmingCharacters(in: .whitespaces).isEmpty else { throw URLError(.badURL) }
                    options[key] = value
                } else {
                    switch value {
                    case "true", "1": options[key] = "true"
                    case "false", "0": options[key] = "false"
                    default: throw URLError(.badURL)
                    }
                }
            }
        }
        keyName = options["ssh-key"]
        observe = options["observe"].map { $0 == "true" }
        requestsGuest = options["guest"] == "true"
    }

    private static func decode(_ value: Substring) throws -> String {
        guard let text = String(value).removingPercentEncoding,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { throw URLError(.badURL) }
        return text
    }
}
