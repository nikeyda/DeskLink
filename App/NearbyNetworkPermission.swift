import SwiftUI
import UIKit

struct NearbyNetworkPermissionActions: View {
    @Environment(\.openURL) private var openURL
    let retry: () -> Void

    static var instructions: LocalizedStringKey {
        #if targetEnvironment(macCatalyst)
        "请在「系统设置 → 隐私与安全 → 本地网络」中允许远程随航查找附近的电脑。"
        #else
        "请在「设置 → 隐私与安全 → 本地网络」中允许远程随航查找附近的电脑。"
        #endif
    }

    private static let settingsURL: URL = {
        #if targetEnvironment(macCatalyst)
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")!
        #else
        URL(string: UIApplication.openSettingsURLString)!
        #endif
    }()

    var body: some View {
        Button("打开系统设置") { openURL(Self.settingsURL) }
            .accessibilityIdentifier("nearby.open-settings")
        Button("重新查找", action: retry)
            .accessibilityIdentifier("nearby.retry")
    }
}
