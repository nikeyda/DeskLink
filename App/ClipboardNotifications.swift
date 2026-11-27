import SwiftUI
import UIKit
import UserNotifications
import rootshellVNC

@MainActor
enum ClipboardNotifications {
    static let preference = "connection.showsClipboardNotifications"
    nonisolated static let requestPrefix = "telescope.clipboard."

    static func enabled(in preferences: UserDefaults) -> Bool {
        preferences.object(forKey: preference) as? Bool ?? true
    }

    static func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }

    static func post(
        _ result: VNCManualClipboardResult,
        computer: String,
        preferences: UserDefaults,
        canPresent: () -> Bool,
        authorization: () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        deliver: (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }
    ) async {
        guard enabled(in: preferences), canPresent(), isAuthorized(await authorization()),
              enabled(in: preferences), canPresent() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "剪贴板")
        switch result {
        case .sent: content.body = String(localized: "剪贴板已发送到“\(computer)”。")
        case .advertised: content.body = String(localized: "“\(computer)”可获取此剪贴板。")
        case .received: content.body = String(localized: "已从“\(computer)”接收剪贴板。")
        case .sendFailed: content.body = String(localized: "无法向“\(computer)”发送剪贴板。")
        case .receiveFailed: content.body = String(localized: "无法从“\(computer)”接收剪贴板。")
        }
        let request = UNNotificationRequest(identifier: requestPrefix + UUID().uuidString,
                                            content: content, trigger: nil)
        try? await deliver(request)
    }
}

final class TelescopeNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    #if targetEnvironment(macCatalyst)
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = session.configuration
        if session.role == .windowApplication { configuration.delegateClass = MacDockSceneDelegate.self }
        return configuration
    }
    #endif

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(ClipboardNotifications.requestPrefix) ? [.banner, .list] : []
    }
}

struct ClipboardNotificationPreferences: View {
    @AppStorage(ClipboardNotifications.preference) private var enabled = true
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Toggle("剪贴板通知", isOn: $enabled)
            .accessibilityIdentifier("preferences.clipboardNotifications")
            .task(id: phase) {
                if phase == .active { await refreshAuthorization() }
            }
        if enabled, authorization == .notDetermined {
            Button("允许系统通知") {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                    await refreshAuthorization()
                }
            }
            .accessibilityIdentifier("preferences.allowClipboardNotifications")
        } else if enabled, authorization == .denied,
                  let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            Button("打开系统通知设置") { openURL(url) }
                .accessibilityIdentifier("preferences.openClipboardNotificationSettings")
        }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
