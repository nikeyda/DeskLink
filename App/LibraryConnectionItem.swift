import SwiftUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

struct LibraryConnectionItem<Label: View>: View {
    let id: String
    @Binding var selection: String?
    let cornerRadius: CGFloat
    let connect: () -> Void
    let label: Label

    init(id: String, selection: Binding<String?>, cornerRadius: CGFloat = 8,
         connect: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.id = id
        _selection = selection
        self.cornerRadius = cornerRadius
        self.connect = connect
        self.label = label()
    }

    var body: some View {
        Button(action: connect) { label }
            #if targetEnvironment(macCatalyst)
            .buttonStyle(ConnectionSelectionStyle(selected: selection == id, cornerRadius: cornerRadius) {
                selection = id
            })
            #endif
            .accessibilityIdentifier(id)
    }
}

#if targetEnvironment(macCatalyst)
private struct ConnectionSelectionStyle: PrimitiveButtonStyle {
    let selected: Bool
    let cornerRadius: CGFloat
    let select: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        ConnectionSelectionControl(label: configuration.label, selected: selected, cornerRadius: cornerRadius,
                                   select: select, connect: configuration.trigger)
    }
}

private struct ConnectionSelectionControl<Label: View>: View {
    let label: Label
    let selected: Bool
    let cornerRadius: CGFloat
    let select: () -> Void
    let connect: () -> Void
    @FocusState private var focused: Bool
    @State private var keyboard = ConnectionRowKeyboard()
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .overlay {
                if selected {
                    shape.fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            shape.strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 2 : 1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .background {
                ConnectionRowWindowAnchor(keyboard: keyboard)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .focusable()
            .focused($focused)
            .onChange(of: focused) { _, focused in
                if focused {
                    select()
                    keyboard.arm(connect: connect)
                }
            }
            .onChange(of: selected) { _, selected in
                if !selected { keyboard.disarm() }
            }
            .onDisappear { keyboard.disarm() }
            .onTapGesture(count: 2) {
                select()
                openConnection()
            }
            .simultaneousGesture(TapGesture().onEnded {
                select()
                focused = true
                keyboard.arm(connect: connect)
            })
            .onKeyPress(keys: [.return, .space], phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.shift, .control, .option, .command]) else {
                    return .ignored
                }
                openConnection()
                return .handled
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction {
                select()
                openConnection()
            }
    }

    private func openConnection() {
        keyboard.disarm()
        connect()
    }
}

private struct ConnectionRowWindowAnchor: UIViewRepresentable {
    let keyboard: ConnectionRowKeyboard

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        keyboard.view = view
    }
}

@MainActor
private final class ConnectionRowKeyboard {
    weak var view: UIView?
    private var monitor: MacConnectionKeyMonitor?

    func arm(connect: @escaping () -> Void) {
        guard monitor == nil, let window = view?.window, window.isKeyWindow else { return }
        // Catalyst may restore its hosting view as first responder after a row click.
        // Keep the selected row's activation available until the next focus-changing input.
        window.endEditing(false)
        monitor = MacConnectionKeyMonitor(
            activate: { [weak self, weak window] in
                guard let self, let window, self.view?.window === window, window.isKeyWindow else { return false }
                self.disarm()
                connect()
                return true
            },
            cancel: { [weak self] in self?.disarm() }
        )
    }

    func disarm() { monitor = nil }
}

/// Bridges the public AppKit event API that Catalyst cannot import.
@MainActor
private final class MacConnectionKeyMonitor {
    private typealias Handler = @MainActor @convention(block) (NSObject) -> NSObject?
    private typealias Install = @convention(c) (AnyClass, Selector, UInt64, Handler) -> Unmanaged<AnyObject>?
    private typealias Remove = @convention(c) (AnyClass, Selector, AnyObject) -> Void

    // NSEvent.h event masks and modifier flags.
    private static let keyDownType = 10
    private static let inputMask: UInt64 = (1 << keyDownType) | (1 << 1) | (1 << 3) | (1 << 25)
    private static let commandModifiers: UInt = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    // Return, Space, keypad Enter, Tab and Escape from HIToolbox/Events.h.
    private static let activationKeys: Set<UInt16> = [0x24, 0x31, 0x4C]
    private static let focusNavigationKeys: Set<UInt16> = [0x30, 0x35]
    private static let activationCharacters: Set<String> = ["\r", "\n", "\u{3}", " "]

    private let remove: () -> Void

    init?(activate: @escaping () -> Bool, cancel: @escaping () -> Void) {
        let addSelector = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        let removeSelector = NSSelectorFromString("removeMonitor:")
        guard let eventClass = NSClassFromString("NSEvent"),
              let addMethod = class_getClassMethod(eventClass, addSelector),
              let removeMethod = class_getClassMethod(eventClass, removeSelector),
              let window = MacApplication.shared?.value(forKey: "keyWindow") as? NSObject else { return nil }
        let install = unsafeBitCast(method_getImplementation(addMethod), to: Install.self)
        let uninstall = unsafeBitCast(method_getImplementation(removeMethod), to: Remove.self)
        let handler: Handler = { [weak window] event in
            guard let window,
                  (event.value(forKey: "type") as? NSNumber)?.intValue == Self.keyDownType,
                  window === event.value(forKey: "window") as? NSObject,
                  window === MacApplication.shared?.value(forKey: "keyWindow") as? NSObject else {
                cancel()
                return event
            }
            let keyCode = (event.value(forKey: "keyCode") as? NSNumber)?.uint16Value
            let characters = event.value(forKey: "charactersIgnoringModifiers") as? String
            let isActivation = keyCode.map(Self.activationKeys.contains) == true
                || characters.map(Self.activationCharacters.contains) == true
            let modifiers = (event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0
            if keyCode.map(Self.focusNavigationKeys.contains) == true
                || (!isActivation && modifiers & Self.commandModifiers != 0) {
                cancel()
            }
            guard isActivation, modifiers & Self.commandModifiers == 0 else { return event }
            return activate() ? nil : event
        }
        guard let token = install(eventClass, addSelector, Self.inputMask, handler)?.takeUnretainedValue() else { return nil }
        remove = { uninstall(eventClass, removeSelector, token) }
    }

    isolated deinit { remove() }
}
#endif
