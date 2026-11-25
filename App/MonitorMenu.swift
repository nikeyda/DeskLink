import SwiftUI
import rootshellVNC

struct MonitorMenu: View {
    let session: VNCSession
    var shortcuts = false
    let select: (VNCMonitorSelection) -> Void
    var split: (() -> Void)?
    var isSplit = false

    var body: some View {
        let ids = session.selectableMonitorIDs
        if ids.count > 1 {
            Menu {
                option("所有显示器", choice: .all, number: 0)
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    option("显示器 \(index + 1)", choice: .display(id), number: index + 1)
                }
                if let split {
                    Divider()
                    Button(action: split) {
                        if isSplit { Label("在独立窗口中显示", systemImage: "checkmark") }
                        else { Text("在独立窗口中显示") }
                    }.accessibilityIdentifier("session.monitorWindows")
                }
            } label: {
                Label("选择显示器", systemImage: "display.2")
            }
            .disabled(session.isSwitchingMonitor)
            .accessibilityIdentifier("session.monitors")
        }
    }

    @ViewBuilder private func option(_ title: String, choice: VNCMonitorSelection, number: Int) -> some View {
        let item = Button {
            select(choice)
        } label: {
            if !isSplit, session.selectedMonitor == choice { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
        if shortcuts, number < 10 {
            item.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.control, .shift])
        } else { item }
    }
}
