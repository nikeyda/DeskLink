import Foundation
import RFBProtocol

enum SessionConnectionFailure: Equatable {
    case authentication, sshAuthentication, sshHostIdentity, incompatible, timeout, closed, unavailable, other
    case localNetworkAccessDenied

    init(_ error: VNCProtocolError?, setupRequiresEditing: Bool) {
        if setupRequiresEditing {
            self = .incompatible
            return
        }
        switch error {
        case .authenticationFailed: self = .authentication
        case .sshAuthenticationFailed: self = .sshAuthentication
        case .sshHostIdentityRejected: self = .sshHostIdentity
        case .unsupportedVersion, .unsupportedEncoding, .unexpectedMessage, .protocolViolation: self = .incompatible
        case .timeout: self = .timeout
        case .connectionClosed: self = .closed
        case .ioError: self = .unavailable
        case .localNetworkAccessDenied: self = .localNetworkAccessDenied
        case nil: self = .other
        }
    }

    var needsEditing: Bool {
        self == .authentication || self == .sshAuthentication || self == .sshHostIdentity || self == .incompatible
    }

    var title: String {
        switch self {
        case .authentication: String(localized: "身份验证失败")
        case .sshAuthentication: String(localized: "SSH 登录失败")
        case .sshHostIdentity: String(localized: "无法确认 SSH 主机身份")
        case .incompatible: String(localized: "无法使用当前连接设置")
        case .timeout: String(localized: "连接超时")
        case .closed: String(localized: "远端关闭了连接")
        case .unavailable: String(localized: "无法连接到远端")
        case .other: String(localized: "连接失败")
        case .localNetworkAccessDenied: String(localized: "Local Network Access Is Off", table: "ConnectionPermission")
        }
    }

    var advice: String {
        switch self {
        case .authentication: String(localized: "请核对远程电脑的账户、密码和认证方式。")
        case .sshAuthentication: String(localized: "请核对 SSH 用户名、密码或密钥。")
        case .sshHostIdentity: String(localized: "请核对 SSH 服务器及其主机指纹。确认指纹变更后，可在设置的「已信任的主机」中更新。")
        case .incompatible: String(localized: "请核对地址、端口和屏幕共享方式。")
        case .timeout, .unavailable: String(localized: "请确认远程电脑在线，并已开启屏幕共享或 VNC。")
        case .closed: String(localized: "请检查远端的屏幕共享权限，或重新连接。")
        case .other: String(localized: "可以重新连接，或检查当前连接设置。")
        case .localNetworkAccessDenied:
            #if targetEnvironment(macCatalyst)
            String(localized: "In System Settings, go to Privacy & Security → Local Network, allow Telescope, then retry.",
                   table: "ConnectionPermission")
            #else
            String(localized: "In Settings, go to Privacy & Security → Local Network, allow Telescope, then retry.",
                   table: "ConnectionPermission")
            #endif
        }
    }
}
