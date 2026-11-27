#if targetEnvironment(macCatalyst)
import UIKit

@MainActor
enum MacDockShortcuts {
    private static let recentPrefix = "local.nikey.desklink.dock.recent."

    static func items(in archive: LibraryArchive, locked: Bool, showsRecents: Bool) -> [UIApplicationShortcutItem] {
        guard !locked, showsRecents else { return [] }
        return ComputerOrder.lastConnected.arrange(archive.computers.filter { $0.lastConnected != nil })
            .prefix(10).map { computer in
                UIApplicationShortcutItem(type: recentPrefix + computer.id.uuidString, localizedTitle: computer.displayName)
            }
    }

    static func request(for shortcut: UIApplicationShortcutItem) -> LibraryWindowRequest? {
        guard shortcut.type.hasPrefix(recentPrefix),
              let id = UUID(uuidString: String(shortcut.type.dropFirst(recentPrefix.count))) else { return nil }
        return .connection(id)
    }

    static func url(for shortcut: UIApplicationShortcutItem) -> URL? {
        request(for: shortcut).flatMap(MacStatusMenu.url)
    }
}

final class MacDockSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let shortcut = options.shortcutItem, let url = MacDockShortcuts.url(for: shortcut) else { return }
        UIApplication.shared.open(url)
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let url = MacDockShortcuts.url(for: shortcutItem) else { completionHandler(false); return }
        Task { completionHandler(await UIApplication.shared.open(url)) }
    }
}
#endif
