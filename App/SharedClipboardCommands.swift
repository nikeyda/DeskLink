import SwiftUI

private struct SharedClipboardKey: FocusedValueKey { typealias Value = Binding<Bool> }

extension FocusedValues {
    var deskLinkClipboardSharing: Binding<Bool>? {
        get { self[SharedClipboardKey.self] }
        set { self[SharedClipboardKey.self] = newValue }
    }
}

struct SharedClipboardCommands: Commands {
    @FocusedBinding(\.deskLinkClipboardSharing) private var sharesClipboard: Bool?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Toggle("自动共享剪贴板", isOn: Binding(get: { sharesClipboard ?? false }, set: { sharesClipboard = $0 }))
                .disabled(sharesClipboard == nil)
        }
    }
}
