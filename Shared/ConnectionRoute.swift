import Foundation

enum ConnectionRoute: Equatable {
    case quick
    case saved(UUID)
    case address(Endpoint)
    case secureAddress(Endpoint, sshPort: UInt16, server: String? = nil)
    case desktopLink(DesktopLink)

    init(url: URL) throws {
        if let scheme = url.scheme?.lowercased(), DesktopLink.supportedSchemes.contains(scheme) {
            self = .desktopLink(try DesktopLink(text: url.absoluteString))
            return
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw URLError(.badURL)
        }
        if parts.query != nil {
            guard parts.scheme?.lowercased() == "desklink", parts.host?.isEmpty == false,
                  let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
                  items.allSatisfy({ ["ssh", "server"].contains($0.name) && $0.value != nil }),
                  let value = items.first(where: { $0.name == "ssh" })?.value,
                  !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = UInt16(value), port > 0 else { throw URLError(.badURL) }
            let server = try items.first(where: { $0.name == "server" }).flatMap(\.value).map(Endpoint.hostOnly)
            parts.query = nil
            guard let address = parts.url else { throw URLError(.badURL) }
            self = .secureAddress(try Endpoint(address: address.absoluteString), sshPort: port, server: server)
            return
        }
        if parts.scheme == "desklink", parts.host?.isEmpty != false {
            let path = parts.path.split(separator: "/")
            if path == ["connect"] { self = .quick; return }
            if path.count == 2, path[0] == "connect", let id = UUID(uuidString: String(path[1])) { self = .saved(id); return }
            throw URLError(.badURL)
        }
        self = .address(try Endpoint(address: url.absoluteString))
    }

    static func savedURL(_ id: UUID) -> URL {
        URL(string: "desklink:///connect/\(id.uuidString)")!
    }

    static func sharing(_ endpoint: Endpoint, sshPort: UInt16?, server: String? = nil) -> URL? {
        var components = URLComponents(string: "desklink://" + endpoint.address)
        if let sshPort {
            var items = [URLQueryItem(name: "ssh", value: String(sshPort))]
            if let server {
                guard let normalized = try? Endpoint.hostOnly(server) else { return nil }
                items.append(URLQueryItem(name: "server", value: normalized))
            }
            components?.queryItems = items
        }
        return components?.url
    }

    static let quickURL = URL(string: "desklink:///connect")!
}
