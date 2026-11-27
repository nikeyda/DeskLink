import Foundation

enum PictureQuality: String, Codable, CaseIterable, Sendable { case standard, adaptive, lossless }

enum ConnectionRoute: Equatable {
    struct SharedOptions: Equatable {
        var observe: Bool?
        var quality: PictureQuality?
    }

    case quick
    case saved(UUID)
    case address(Endpoint)
    case secureAddress(Endpoint, sshPort: UInt16, server: String? = nil)
    case sharedAddress(Endpoint, sshPort: UInt16?, server: String?, options: SharedOptions)
    case desktopLink(DesktopLink)

    init(url: URL) throws {
        if let scheme = url.scheme?.lowercased(), DesktopLink.supportedSchemes.contains(scheme) {
            self = .desktopLink(try DesktopLink(text: url.absoluteString))
            return
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw URLError(.badURL)
        }
        if parts.query != nil {
            guard parts.scheme?.lowercased() == "desklink", parts.host?.isEmpty == false,
                  let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
                  !items.isEmpty else { throw URLError(.badURL) }
            var sshPort: UInt16?
            var server: String?
            var options = SharedOptions()
            for item in items {
                guard let value = item.value, !value.isEmpty else { throw URLError(.badURL) }
                switch item.name {
                case "ssh":
                    guard value.utf8.allSatisfy({ (48...57).contains($0) }),
                          let port = UInt16(value), port > 0 else { throw URLError(.badURL) }
                    sshPort = port
                case "server": server = try Endpoint.hostOnly(value)
                case "observe":
                    switch value {
                    case "true", "1": options.observe = true
                    case "false", "0": options.observe = false
                    default: throw URLError(.badURL)
                    }
                case "quality":
                    guard let quality = PictureQuality(rawValue: value) else { throw URLError(.badURL) }
                    options.quality = quality
                default: throw URLError(.badURL)
                }
            }
            guard server == nil || sshPort != nil else { throw URLError(.badURL) }
            let endpoint = try Self.endpoint(from: parts)
            if options.observe != nil || options.quality != nil {
                self = .sharedAddress(endpoint, sshPort: sshPort, server: server, options: options)
            } else if let sshPort {
                self = .secureAddress(endpoint, sshPort: sshPort, server: server)
            } else {
                self = .address(endpoint)
            }
            return
        }
        if parts.scheme == "desklink", parts.host?.isEmpty != false {
            let path = parts.path.split(separator: "/")
            if path == ["connect"] { self = .quick; return }
            if path.count == 2, path[0] == "connect", let id = UUID(uuidString: String(path[1])) { self = .saved(id); return }
            throw URLError(.badURL)
        }
        self = .address(try Self.endpoint(from: parts))
    }

    private static func endpoint(from parts: URLComponents) throws -> Endpoint {
        var address = parts
        address.query = nil
        guard let url = address.url else { throw URLError(.badURL) }
        let endpoint = try Endpoint(address: url.absoluteString)
        // Foundation percent-encodes the IPv6 zone on the wire. Recover the
        // decoded interface name without treating it as part of the port.
        if let host = address.host, host.hasPrefix("["), host.contains("%") {
            return try Endpoint(address: host, defaultPort: endpoint.port)
        }
        return endpoint
    }

    static func savedURL(_ id: UUID) -> URL {
        URL(string: "desklink:///connect/\(id.uuidString)")!
    }

    static func sharing(_ endpoint: Endpoint, sshPort: UInt16?, server: String? = nil,
                        options: SharedOptions = .init()) -> URL? {
        guard sshPort != 0, server == nil || sshPort != nil else { return nil }
        var components = URLComponents()
        components.scheme = "desklink"
        components.host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        if endpoint.port != 5900 { components.port = Int(endpoint.port) }
        var items: [URLQueryItem] = []
        if let sshPort {
            items.append(URLQueryItem(name: "ssh", value: String(sshPort)))
            if let server {
                guard let normalized = try? Endpoint.hostOnly(server) else { return nil }
                items.append(URLQueryItem(name: "server", value: normalized))
            }
        }
        if let observe = options.observe { items.append(URLQueryItem(name: "observe", value: String(observe))) }
        if let quality = options.quality { items.append(URLQueryItem(name: "quality", value: quality.rawValue)) }
        if !items.isEmpty { components.queryItems = items }
        return components.url
    }

    static let quickURL = URL(string: "desklink:///connect")!
}
