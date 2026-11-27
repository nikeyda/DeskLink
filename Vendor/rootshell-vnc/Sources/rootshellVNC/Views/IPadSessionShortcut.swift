#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Shortcuts used while an iPad is showing a remote desktop. A binding
/// represents a local viewer action or an existing remote menu command.
@MainActor enum IPadSessionShortcut: Equatable {
    case screenshot, disconnect, password
    case remote(RemoteCommand)
    case menu(RemoteMenuShortcut)

    struct Binding {
        let input: String
        let action: IPadSessionShortcut
        let modifiers: UIKeyModifierFlags

        init(_ input: String, _ action: IPadSessionShortcut, option: Bool = false) {
            self.input = input
            self.action = action
            modifiers = option ? [.shift, .control, .command, .alternate] : [.shift, .control, .command]
        }
    }

    static let bindings: [Binding] = [
        Binding("r", .screenshot), Binding("c", .disconnect), Binding("p", .password),
        Binding(UIKeyCommand.inputUpArrow, .remote(.missionControl)),
        Binding(UIKeyCommand.inputDownArrow, .remote(.applicationWindows)),
        Binding(UIKeyCommand.inputLeftArrow, .remote(.moveLeftASpace)),
        Binding(UIKeyCommand.inputRightArrow, .remote(.moveRightASpace)),
        Binding("m", .menu(.minimize)), Binding("h", .menu(.hide)),
        Binding("h", .menu(.hideOthers), option: true),
        Binding("w", .menu(.closeWindow)), Binding("q", .menu(.quit)),
        Binding(UIKeyCommand.inputEscape, .remote(.forceQuit)),
        Binding("s", .remote(.lockScreen)), Binding("u", .remote(.logOutUser)),
        Binding("\u{8}", .remote(.controlAltDelete)), Binding(" ", .menu(.spotlight)),
        Binding("\\", .remote(.backslash)), Binding("|", .remote(.insert))
    ]

    static func matching(_ input: String?, flags: UIKeyModifierFlags) -> Self? {
        guard let input else { return nil }
        let modifiers = flags.intersection([.shift, .control, .command, .alternate])
        let key = input.count == 1 ? input.lowercased() : input
        return bindings.first { $0.input == key && $0.modifiers == modifiers }?.action
    }

    static func appSwitcherTabUsage(for usage: UInt32, flags: UIKeyModifierFlags,
                                    swapsCommandAndControl: Bool) -> UInt32? {
        guard usage == 0x28 else { return nil } // Return
        let command: UIKeyModifierFlags = swapsCommandAndControl ? .control : .command
        let modifiers = flags.intersection([.shift, .control, .command, .alternate])
        return modifiers == command || modifiers == command.union(.shift) ? 0x2B : nil // Tab
    }

    var title: String {
        switch self {
        case .screenshot: String(localized: "Save Screenshot", bundle: .module)
        case .disconnect: String(localized: "Close Connection", bundle: .module)
        case .password: String(localized: "Type Password", bundle: .module)
        case .remote(let command): command.title
        case .menu(let command): command.title
        }
    }
}
#endif
