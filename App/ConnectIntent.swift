import AppIntents
import CoreSpotlight
import UIKit

extension ComputerEntity: IndexedEntity {}

struct ConnectToComputer: OpenIntent {
    static let title: LocalizedStringResource = "连接到电脑"
    static let openAppWhenRun = true
    @Parameter(title: "已存储的电脑") var target: ComputerEntity

    static var parameterSummary: some ParameterSummary { Summary("使用「屏幕连线」连接到\(\.$target)") }

    @MainActor func perform() async throws -> some IntentResult {
        let opened = await UIApplication.shared.open(ConnectionRoute.savedURL(target.id))
        guard opened else { throw URLError(.unsupportedURL) }
        return .result()
    }
}

struct DeskLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectToComputer(),
                    phrases: ["使用「\(.applicationName)」连接到\(\.$target)"],
                    shortTitle: "连接到电脑", systemImageName: "desktopcomputer")
    }
}
