import SwiftUI

struct DiscoveredConnectionItem<Content: View, Actions: View>: View {
    let id: String
    @Binding var selection: String?
    let cornerRadius: CGFloat
    let endpoint: Endpoint?
    let connect: () -> Void
    let label: Content
    let actions: Actions

    @State private var request: UUID?
    @State private var outcome: ScreenSharingCheck.Outcome?

    init(id: String, selection: Binding<String?>, cornerRadius: CGFloat, endpoint: Endpoint?,
         connect: @escaping () -> Void, @ViewBuilder label: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.id = id
        _selection = selection
        self.cornerRadius = cornerRadius
        self.endpoint = endpoint
        self.connect = connect
        self.label = label()
        self.actions = actions()
    }

    var body: some View {
        LibraryConnectionItem(id: id, selection: $selection, cornerRadius: cornerRadius, connect: connect) {
            VStack(alignment: .leading, spacing: 6) {
                label
                if let outcome {
                    status(outcome)
                } else if request != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在检查屏幕共享…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if endpoint != nil {
                Button("检查屏幕共享直连", systemImage: "stethoscope") {
                    outcome = nil
                    request = UUID()
                }
                .accessibilityIdentifier("discovery.checkScreenSharing")
            }
            actions
        }
        .task(id: request) {
            guard let request, let endpoint else { return }
            let result = await ScreenSharingCheck.check(endpoint)
            guard !Task.isCancelled, self.request == request else { return }
            outcome = result
            self.request = nil
        }
        .onChange(of: endpoint) {
            outcome = nil
            request = nil
        }
    }

    private func status(_ outcome: ScreenSharingCheck.Outcome) -> some View {
        let text: LocalizedStringKey
        let symbol: String
        switch outcome {
        case .responding: (text, symbol) = ("屏幕共享已响应", "checkmark.circle")
        case .unexpectedResponse: (text, symbol) = ("未识别到屏幕共享响应", "exclamationmark.circle")
        case .unavailable: (text, symbol) = ("无法直连屏幕共享", "network.slash")
        case .timedOut: (text, symbol) = ("屏幕共享未在时限内响应", "clock")
        }
        return Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("discovery.screenSharingResult")
    }
}
