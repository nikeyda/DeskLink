import RFBProtocol
import SwiftUI

enum SessionConnectionFailure: Equatable {
    case authentication, sshAuthentication, sshHostIdentity, incompatible, timeout, closed, unavailable, other

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
        case nil: self = .other
        }
    }

    var needsEditing: Bool {
        self == .authentication || self == .sshAuthentication || self == .sshHostIdentity || self == .incompatible
    }

    var title: LocalizedStringKey {
        switch self {
        case .authentication: "身份验证失败"
        case .sshAuthentication: "SSH 登录失败"
        case .sshHostIdentity: "无法确认 SSH 主机身份"
        case .incompatible: "无法使用当前连接设置"
        case .timeout: "连接超时"
        case .closed: "远端关闭了连接"
        case .unavailable: "无法连接到远端"
        case .other: "连接失败"
        }
    }

    var advice: LocalizedStringKey {
        switch self {
        case .authentication: "请核对远程电脑的账户、密码和认证方式。"
        case .sshAuthentication: "请核对 SSH 用户名、密码或密钥。"
        case .sshHostIdentity: "请核对 SSH 服务器及其主机指纹。确认指纹变更后，可在设置的「已信任的主机」中更新。"
        case .incompatible: "请核对地址、端口和屏幕共享方式。"
        case .timeout, .unavailable: "请确认远程电脑在线，并已开启屏幕共享或 VNC。"
        case .closed: "请检查远端的屏幕共享权限，或重新连接。"
        case .other: "可以重新连接，或检查当前连接设置。"
        }
    }
}
