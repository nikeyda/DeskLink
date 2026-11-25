import Foundation

/// An action chosen for a saved desktop and delivered before the user closes
/// an established control session.
public enum VNCDisconnectAction: String, Codable, CaseIterable, Sendable {
    case lockScreen, logOutUser, controlAltDelete
    case topLeft, topRight, bottomLeft, bottomRight

    @MainActor
    public func send(to session: VNCSession) {
        guard session.connectionState.isConnected else { return }
        let mac = session.serverUsesAppleModifierConvention
        let command: RemoteCommand
        switch self {
        case .lockScreen: command = .lockScreen
        case .logOutUser:
            guard mac else { return }
            command = .logOutUser
        case .controlAltDelete: command = .controlAltDelete
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            guard session.framebufferWidth > 0, session.framebufferHeight > 0 else { return }
            let right = self == .topRight || self == .bottomRight
            let bottom = self == .bottomLeft || self == .bottomRight
            session.sendPointerEvent(buttonMask: 0,
                                     x: UInt16(clamping: right ? session.framebufferWidth - 1 : 0),
                                     y: UInt16(clamping: bottom ? session.framebufferHeight - 1 : 0))
            return
        }
        let chord = command.remoteChord(appleModifierConvention: mac, platform: mac ? .mac : .other)
        for key in chord.modifiers { session.sendKeyEvent(downFlag: true, key: key) }
        session.sendKeyEvent(downFlag: true, key: chord.key)
        session.sendKeyEvent(downFlag: false, key: chord.key)
        for key in chord.modifiers.reversed() { session.sendKeyEvent(downFlag: false, key: key) }
    }
}
