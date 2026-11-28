import SwiftUI
import rootshellVNC

/// The keyboard strip and system menus share the same remote command mapping.
struct RemoteCommandsMenu: View {
    let session: VNCSession
    var willSend: () -> Void = {}
    var allowsInput: () -> Bool = { true }

    var body: some View {
        if session.serverUsesAppleModifierConvention {
            commands(RemoteCommand.macSpecific)
            Divider()
        }
        commands(RemoteCommand.systemCommands(for: session.serverUsesAppleModifierConvention ? .mac : .other))
        Divider()
        commands(RemoteCommand.keys)
    }

    private func commands(_ entries: [RemoteCommand]) -> some View {
        ForEach(entries) { command in
            Button(command.title) {
                guard session.isReadyForDesktopInput, allowsInput() else { return }
                willSend()
                let keyboard = KeyboardInputHandler(
                    sendKeyEvent: { session.sendKeyEvent(downFlag: $0, key: $1) },
                    usesAppleModifierConvention: { session.serverUsesAppleModifierConvention }
                )
                keyboard.handleRemoteCommand(command)
            }
            .accessibilityIdentifier("remoteCommand." + command.rawValue)
            .disabled(!session.isReadyForDesktopInput)
        }
    }
}
