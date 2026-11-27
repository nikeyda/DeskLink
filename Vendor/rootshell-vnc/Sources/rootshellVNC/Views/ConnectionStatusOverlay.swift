import SwiftUI

/// Floating glass status card shown while a connection is being established
/// or re-established. Reads the session's connection state and live phase
/// text, and always offers a way out of a stuck attempt.
public struct ConnectionStatusOverlay: View {
    @Bindable var session: VNCSession
    private let onCancel: (@MainActor () -> Void)?

    public init(session: VNCSession, onCancel: (@MainActor () -> Void)? = nil) {
        self.session = session
        self.onCancel = onCancel
    }

    public var body: some View {
        switch session.connectionState {
        case .connecting:
            ConnectionStatusCard(
                title: connectingTitle,
                detail: session.connectionPhaseDescription,
                actionLabel: String(localized: "Cancel", bundle: .module),
                actionRole: .cancel
            ) { cancelInitialConnection() }

        case .reconnecting(let attempt, let delay):
            let phase = session.connectionPhaseDescription
            let waitingToRetry = delay > 0 && phase == nil
            ConnectionStatusCard(
                title: waitingToRetry
                    ? String(localized: "Connection interrupted", bundle: .module)
                    : reconnectingTitle,
                detail: waitingToRetry
                    ? String(localized: "Retry \(attempt) starts in about \(Int(ceil(delay))) seconds.", bundle: .module)
                    : phase,
                actionLabel: String(localized: "Stop Reconnecting", bundle: .module),
                actionRole: .destructive
            ) { session.disconnect() }
            .accessibilityIdentifier("session.reconnecting")

        case .connected where !session.hasPresentedCurrentPicture:
            let reconnecting = session.desktopPictureState == .waitingAfterReconnect
            let waiting = String(localized: "Waiting for first screen update…", bundle: .module)
            ConnectionStatusCard(
                title: reconnecting ? reconnectingTitle : waiting,
                detail: reconnecting ? waiting : nil,
                actionLabel: reconnecting ? String(localized: "Stop Reconnecting", bundle: .module)
                    : String(localized: "Cancel", bundle: .module),
                actionRole: reconnecting ? .destructive : .cancel
            ) {
                if reconnecting { session.disconnect() }
                else { cancelInitialConnection() }
            }
            .accessibilityIdentifier("session.waitingForScreen")

        default:
            EmptyView()
        }
    }

    private var reconnectingTitle: String {
        String(localized: "Reconnecting now…", bundle: .module)
    }

    private func cancelInitialConnection() {
        if let onCancel { onCancel() }
        else { session.disconnect() }
    }

    private var connectingTitle: String {
        if let host = session.connectingHostLabel, !host.isEmpty {
            return String(localized: "Connecting to \(host)", bundle: .module)
        }
        return String(localized: "Connecting", bundle: .module)
    }
}

/// The shared status card for connecting and waiting for the desktop.
struct ConnectionStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var detail: String?
    var actionLabel: String?
    var actionRole: ButtonRole?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.82) : Color.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionLabel, let action {
                Button(actionLabel, role: actionRole, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                    .accessibilityIdentifier("session.statusAction")
            }
        }
        .padding(28)
        .frame(minWidth: 220, maxWidth: 320)
        .background {
            if colorScheme == .dark {
                // A changing desktop can have any color under the glass.
                RoundedRectangle(cornerRadius: 28).fill(.black.opacity(0.7))
            }
        }
        .glassStatusCard()
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct GlassStatusCardModifier: ViewModifier {
    @Environment(\.vncChromeGlassTint) private var glassTint

    func body(content: Content) -> some View {
        #if os(visionOS)
        // No glass API here; material matches the pre-26 fallback and drops
        // the host tint along with it.
        content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        #else
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            // A host tint switches to clear glass: the tint restores the
            // contrast floor that regular's frost otherwise provides, and
            // the card takes on the host's theme instead of neutral gray.
            content.glassEffect(
                glassTint.map { Glass.clear.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: 28))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
        #endif
    }
}

extension View {
    func glassStatusCard() -> some View {
        modifier(GlassStatusCardModifier())
    }
}

/// Optional glass tint a host app injects so the chrome the package still
/// owns (status cards, the HUD menu button) matches the host's theme.
/// `nil` keeps the package's standalone appearance.
private struct VNCChromeGlassTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

public extension EnvironmentValues {
    var vncChromeGlassTint: Color? {
        get { self[VNCChromeGlassTintKey.self] }
        set { self[VNCChromeGlassTintKey.self] = newValue }
    }
}
