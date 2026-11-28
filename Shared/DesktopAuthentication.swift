enum DesktopAuthentication: Int, Codable, CaseIterable, Sendable {
    case automatic = 0
    case macUser = 1
    case vncPassword = 2
    case unauthenticated = 3
    case raspberryPiRSA = 5

    var usesPassword: Bool { self != .unauthenticated }
    var usesUsername: Bool { self == .automatic || self == .macUser || self == .raspberryPiRSA }

    var connectionLinkValue: String {
        switch self {
        case .automatic: "auto"
        case .macUser: "mac-user"
        case .vncPassword: "vnc-password"
        case .unauthenticated: "none"
        case .raspberryPiRSA: "raspberry-pi"
        }
    }

    init?(connectionLinkValue: String) {
        guard let method = Self.allCases.first(where: { $0.connectionLinkValue == connectionLinkValue }) else { return nil }
        self = method
    }
}
