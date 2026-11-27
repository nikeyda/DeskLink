#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

@MainActor
final class MacStatusMenu: NSObject {
    static let preference = "mac.showStatusMenu"
    private let defaults: UserDefaults
    private weak var library: ConnectionLibrary?
    private weak var privacy: AppLock?
    private var statusItem: NSObject?
    var restoreDock: (() -> Void)?

    init(defaults: UserDefaults) { self.defaults = defaults }

    func attach(library: ConnectionLibrary, privacy: AppLock) {
        self.library = library
        self.privacy = privacy
    }

    @discardableResult
    func setVisible(_ visible: Bool) -> Bool {
        guard visible != (statusItem != nil) else { return true }
        guard let bar = Self.systemBar else { return false }
        if let statusItem {
            bar.perform(NSSelectorFromString("removeStatusItem:"), with: statusItem)
            self.statusItem = nil
            return true
        }
        let selector = NSSelectorFromString("statusItemWithLength:")
        guard bar.responds(to: selector), let method = bar.method(for: selector),
              let menu = Self.make("NSMenu") else { return false }
        // AppKit is unavailable to import in Catalyst. The method takes a CGFloat.
        typealias CreateStatusItem = @convention(c) (AnyObject, Selector, CGFloat) -> Unmanaged<AnyObject>
        let createStatusItem = unsafeBitCast(method, to: CreateStatusItem.self)
        guard let item = createStatusItem(bar, selector, -1).takeUnretainedValue() as? NSObject else { return false }
        guard let button = item.value(forKey: "button") as? NSObject else {
            bar.perform(NSSelectorFromString("removeStatusItem:"), with: item)
            return false
        }
        let image = (NSClassFromString("NSImage") as? NSObject.Type)?
            .perform(NSSelectorFromString("imageWithSystemSymbolName:accessibilityDescription:"),
                     with: "binoculars", with: AppName.display)?.takeUnretainedValue()
        if let image { button.setValue(image, forKey: "image") }
        else { button.setValue(AppName.display, forKey: "title") }
        button.perform(NSSelectorFromString("setAccessibilityLabel:"), with: AppName.display)
        button.setValue(AppName.display, forKey: "toolTip")
        menu.setValue(self, forKey: "delegate")
        menuNeedsUpdate(menu)
        item.setValue(menu, forKey: "menu")
        statusItem = item
        return true
    }

    @objc private func menuNeedsUpdate(_ menu: NSObject) {
        menu.perform(NSSelectorFromString("removeAllItems"))
        append(String(localized: "打开连接库"), request: .collection(.all), to: menu)
        append(String(localized: "快速连接…"), request: .quickConnect, to: menu)
        defer {
            if restoreDock != nil {
                appendSeparator(to: menu)
                append(String(localized: "显示程序坞图标"), action: #selector(showDock), to: menu)
                append(String(localized: "退出远程随航"), action: #selector(quit), to: menu)
            }
        }
        guard let library, privacy?.locked == false else { return }
        let archive = library.archive
        let hidden = HiddenSidebarItems(rawValue: defaults.integer(forKey: HiddenSidebarItems.preferenceKey))

        appendSeparator(to: menu)
        if !hidden.contains(.nearby) { append(String(localized: "附近"), request: .collection(.nearby), to: menu) }
        if !hidden.contains(.tailscale) { append("Tailscale", request: .collection(.tailscale), to: menu) }
        appendCollection(String(localized: "所有连接"), page: .all, entries: archive.computers.filter(\.saved),
                         folders: archive.folders, to: menu)
        if !hidden.contains(.favorites) {
            appendCollection(String(localized: "收藏"), page: .favorites,
                             entries: archive.computers.filter { $0.saved && $0.favorite }, to: menu)
        }
        if !hidden.contains(.recent) {
            let recent = ComputerOrder.lastConnected.arrange(archive.computers.filter { $0.lastConnected != nil })
            appendCollection(String(localized: "最近连接"), page: .recent, entries: Array(recent.prefix(10)), to: menu)
        }
        if !hidden.contains(.links) {
            appendCollection(String(localized: "所有链接"), page: .links, entries: archive.computers.filter(\.isLink),
                             folders: archive.folders(in: .links), to: menu)
        }
    }

    private func appendCollection(_ title: String, page: CollectionPage, entries: [Computer],
                                  folders: [String] = [], to menu: NSObject) {
        guard !entries.isEmpty, let submenu = Self.make("NSMenu"), let item = Self.make("NSMenuItem") else {
            append(title, request: .collection(page), to: menu)
            return
        }
        item.setValue(title, forKey: "title")
        item.setValue(submenu, forKey: "submenu")
        append(String(localized: "在连接库中查看"), request: .collection(page), to: submenu)
        appendSeparator(to: submenu)
        let byFolder = Dictionary(grouping: entries) { $0.folder(in: page.folderScope) }
        for entry in entries where !folders.contains(entry.folder(in: page.folderScope) ?? "") {
            append(entry.displayName, request: .connection(entry.id), to: submenu)
        }
        for folder in folders {
            guard let entries = byFolder[folder], let folderMenu = Self.make("NSMenu"),
                  let folderItem = Self.make("NSMenuItem") else { continue }
            folderItem.setValue(folder, forKey: "title")
            folderItem.setValue(folderMenu, forKey: "submenu")
            for entry in entries { append(entry.displayName, request: .connection(entry.id), to: folderMenu) }
            submenu.perform(NSSelectorFromString("addItem:"), with: folderItem)
        }
        menu.perform(NSSelectorFromString("addItem:"), with: item)
    }

    private func append(_ title: String, request: LibraryWindowRequest, to menu: NSObject) {
        guard let url = Self.url(for: request) else { return }
        append(title, action: #selector(selectItem), url: url, to: menu)
    }

    private func append(_ title: String, action: Selector, url: URL? = nil, to menu: NSObject) {
        let selector = NSSelectorFromString("setAction:")
        guard let item = Self.make("NSMenuItem"), let method = item.method(for: selector) else { return }
        item.setValue(title, forKey: "title")
        item.setValue(self, forKey: "target")
        item.setValue(url, forKey: "representedObject")
        typealias SetAction = @convention(c) (AnyObject, Selector, Selector) -> Void
        unsafeBitCast(method, to: SetAction.self)(item, selector, action)
        menu.perform(NSSelectorFromString("addItem:"), with: item)
    }

    private func appendSeparator(to menu: NSObject) {
        guard let item = (NSClassFromString("NSMenuItem") as? NSObject.Type)?
            .perform(NSSelectorFromString("separatorItem"))?.takeUnretainedValue() else { return }
        menu.perform(NSSelectorFromString("addItem:"), with: item)
    }

    @objc private func selectItem(_ sender: NSObject) {
        guard let url = sender.value(forKey: "representedObject") as? URL else { return }
        Task { await UIApplication.shared.open(url) }
    }

    @objc private func showDock() { restoreDock?() }

    @objc private func quit() {
        MacApplication.shared?.perform(NSSelectorFromString("terminate:"), with: nil)
    }

    static func url(for request: LibraryWindowRequest) -> URL? {
        let path: String
        switch request {
        case .quickConnect: path = "quick"
        case .connection(let id): path = "connect/" + id.uuidString
        case .collection(let page):
            guard let name = pageNames.first(where: { $0.value == page })?.key else { return nil }
            path = name
        }
        return URL(string: "desklink:///menu/" + path)
    }

    static func request(for url: URL) -> LibraryWindowRequest? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "desklink", parts.host?.isEmpty != false,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/")
        guard path.first == "menu" else { return nil }
        if path.count == 3, path[1] == "connect", let id = UUID(uuidString: String(path[2])) { return .connection(id) }
        guard path.count == 2 else { return nil }
        if path[1] == "quick" { return .quickConnect }
        return pageNames[String(path[1])].map(LibraryWindowRequest.collection)
    }

    private static let pageNames: [String: CollectionPage] = [
        "library": .all, "nearby": .nearby, "tailscale": .tailscale,
        "favorites": .favorites, "recent": .recent, "links": .links
    ]

    private static var systemBar: NSObject? {
        (NSClassFromString("NSStatusBar") as? NSObject.Type)?
            .perform(NSSelectorFromString("systemStatusBar"))?.takeUnretainedValue() as? NSObject
    }

    private static func make(_ className: String) -> NSObject? {
        (NSClassFromString(className) as? NSObject.Type)?.init()
    }
}
#endif
