#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import Observation

enum MacConnectionTabs: String {
    static let preference = "mac.connectionTabs"
    case system, never

    func collectionBehavior(systemPreference: MacApplication.TabPreference?, fullScreen: Bool) -> UISceneCollectionJoinBehavior {
        guard self == .system else { return .disallowed }
        switch systemPreference {
        case .always: return .preferred
        case .inFullScreen: return fullScreen ? .preferred : .disallowed
        case .manual: return .disallowed
        case nil: return .automatic
        }
    }
}

@MainActor
final class MacConnectionWindows {
    static let activityType = "local.nikey.desklink.connection-window"

    enum Content {
        case session(SessionRequest)
        case route(ConnectionRoute)
    }

    private var pending: [String: Content] = [:]

    func open(_ content: Content, from source: UIWindowScene, tabs: MacConnectionTabs, onFailure: @escaping () -> Void) {
        let token = UUID().uuidString
        pending[token] = content

        // Scene activation carries only a one-time identifier. Credentials stay in memory.
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.targetContentIdentifier = Self.activityType
        activity.userInfo = ["token": token]

        let options = UIScene.ActivationRequestOptions()
        options.requestingScene = source
        // SwiftUI-created Catalyst scenes can stay separate with .automatic even when macOS prefers tabs.
        options.collectionJoinBehavior = tabs.collectionBehavior(systemPreference: MacApplication.tabPreference, fullScreen: source.isFullScreen)
        var request = UISceneSessionActivationRequest()
        request.options = options
        request.userActivity = activity
        UIApplication.shared.activateSceneSession(for: request) { [weak self] _ in
            Task { @MainActor in
                guard self?.pending.removeValue(forKey: token) != nil else { return }
                onFailure()
            }
        }
    }

    func take(_ activity: NSUserActivity) -> Content? {
        guard activity.activityType == Self.activityType, let token = activity.userInfo?["token"] as? String else { return nil }
        return pending.removeValue(forKey: token)
    }
}

@MainActor @Observable
final class MacWindowSceneSource {
    @ObservationIgnored weak var window: UIWindow?
    var scene: UIWindowScene? { window?.windowScene }
    private(set) var isFullScreen = false

    func refreshFullScreen() {
        let fullScreen = scene?.isFullScreen == true
        if isFullScreen != fullScreen { isFullScreen = fullScreen }
    }

    @discardableResult
    func toggleFullScreen(send: @MainActor (UIWindow) -> Bool = MacApplication.toggleKeyWindowFullScreen(from:)) -> Bool {
        guard let window, SessionWindowFocus.Tracker.isFocused(window),
              let scene, scene.isFullScreen || scene.sizeRestrictions?.allowsFullScreen != false else { return false }
        return send(window)
    }
}

struct MacWindowSceneCapture: UIViewRepresentable {
    let source: MacWindowSceneSource
    let title: String

    func makeUIView(context: Context) -> CaptureView {
        CaptureView(source: source, title: title)
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.title = title
    }

    final class CaptureView: UIView {
        let source: MacWindowSceneSource
        var title: String { didSet { if title != oldValue { window?.windowScene?.title = title } } }

        init(source: MacWindowSceneSource, title: String) {
            self.source = source
            self.title = title
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            for name in ["NSWindowDidEnterFullScreenNotification", "NSWindowDidExitFullScreenNotification"] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshFullScreen),
                                                       name: Notification.Name(name), object: nil)
            }
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            source.window = window
            source.scene?.title = title
            refreshFullScreen()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if source.isFullScreen != (source.scene?.isFullScreen == true) { refreshFullScreen() }
        }

        @objc private func refreshFullScreen() {
            DispatchQueue.main.async { [weak source] in source?.refreshFullScreen() }
        }
    }
}
#endif
