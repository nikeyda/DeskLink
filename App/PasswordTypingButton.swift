import SwiftUI
import rootshellVNC

struct PasswordTypingButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let controls: VNCDesktopControls
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { controls.requestPasswordPrompt() } label: { label() }
            .highPriorityGesture(LongPressGesture().onEnded { _ in requestPasswordOnly() })
            .accessibilityAction(named: Text("仅输入用户密码"), requestPasswordOnly)
    }

    private func requestPasswordOnly() {
        guard isEnabled else { return }
        controls.requestPasswordOnlyPrompt()
    }
}
