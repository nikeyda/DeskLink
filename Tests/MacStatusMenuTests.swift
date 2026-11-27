#if targetEnvironment(macCatalyst)
import XCTest
@testable import DeskLink

final class MacStatusMenuTests: XCTestCase {
    @MainActor func testMenuRoutesUseTheExactSavedComputerAndKeepExternalLinksSeparate() throws {
        let id = UUID()
        let actions: [LibraryWindowRequest] = [
            .connection(id), .quickConnect, .collection(.all), .collection(.nearby),
            .collection(.tailscale), .collection(.favorites), .collection(.recent), .collection(.links)
        ]
        for action in actions {
            let link = try XCTUnwrap(MacStatusMenu.url(for: action))
            XCTAssertEqual(MacStatusMenu.request(for: link), action)
        }
        for text in ["desklink://host.invalid/menu/quick", "desklink:///menu/quick?host=x",
                     "desklink:///menu/connect/broken", "desklink:///menu/favorites/extra",
                     "https://example.invalid/menu/library"] {
            XCTAssertNil(MacStatusMenu.request(for: try XCTUnwrap(URL(string: text))))
        }
        XCTAssertNil(MacStatusMenu.request(for: ConnectionRoute.savedURL(id)))
        XCTAssertNil(MacStatusMenu.url(for: .collection(.folder("Studio"))))
    }

    @MainActor func testNativeMenuFollowsSidebarVisibilityAndOnlyShowsConnectionsAfterUnlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let name = "Telescope-status-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = ConnectionLibrary(file: directory.appending(path: "library.json"))
        var favorite = Computer(name: "Saved fixture", endpoint: try Endpoint(address: "saved.fixture.invalid"))
        favorite.favorite = true
        favorite.folder = "Studio"
        XCTAssertTrue(library.save(favorite))
        library.recordSuccess(favorite, now: Date(timeIntervalSince1970: 20))
        var link = Computer(name: "Temporary fixture", endpoint: try Endpoint(address: "temporary.fixture.invalid"))
        link.saved = false
        link.openedFromLink = true
        library.recordSuccess(link, now: Date(timeIntervalSince1970: 10))
        link.linkFolder = "Lab"
        XCTAssertTrue(library.save(link))

        let privacy = AppLock(defaults: defaults, authenticate: { _ in true })
        let status = MacStatusMenu(defaults: defaults)
        status.attach(library: library, privacy: privacy)
        status.setVisible(true)
        defer { status.setVisible(false) }
        let menu = try XCTUnwrap((NSClassFromString("NSMenu") as? NSObject.Type)?.init())
        func refresh() { _ = status.perform(NSSelectorFromString("menuNeedsUpdate:"), with: menu) }
        let all = String(localized: "所有连接")
        let favorites = String(localized: "收藏")
        let recent = String(localized: "最近连接")
        let links = String(localized: "所有链接")
        let nearby = String(localized: "附近")

        refresh()
        XCTAssertTrue([all, favorites, recent, links, nearby, "Tailscale"].allSatisfy(titles(in: menu).contains))
        let studio = try child("Studio", of: child(all, of: menu))
        let linkFolder = try child("Lab", of: child(links, of: menu))
        XCTAssertEqual(items(in: studio).compactMap(request), [.connection(favorite.id)])
        XCTAssertEqual(items(in: linkFolder).compactMap(request), [.connection(link.id)])
        let recents = try child(recent, of: menu)
        XCTAssertEqual(items(in: recents).compactMap(request), [.collection(.recent), .connection(favorite.id), .connection(link.id)])

        let hidden: HiddenSidebarItems = [.nearby, .tailscale, .links, .favorites, .recent]
        defaults.set(hidden.rawValue, forKey: HiddenSidebarItems.preferenceKey)
        refresh()
        XCTAssertTrue(titles(in: menu).contains(all))
        XCTAssertTrue([favorites, recent, links, nearby, "Tailscale"].allSatisfy { !titles(in: menu).contains($0) })

        await privacy.setEnabled(true)
        privacy.lock()
        refresh()
        XCTAssertEqual(items(in: menu).compactMap(request), [.collection(.all), .quickConnect])
        XCTAssertEqual(items(in: menu).count, 2)
        await privacy.unlock()
        XCTAssertTrue(library.removeFolder("Studio"))
        library.remove(favorite)
        refresh()
        XCTAssertEqual(items(in: menu).compactMap(request), [.collection(.all), .quickConnect, .collection(.all)])
    }

    @MainActor private func items(in menu: NSObject) -> [NSObject] {
        menu.value(forKey: "itemArray") as? [NSObject] ?? []
    }

    @MainActor private func titles(in menu: NSObject) -> [String] {
        items(in: menu).compactMap { $0.value(forKey: "title") as? String }
    }

    @MainActor private func child(_ title: String, of menu: NSObject) throws -> NSObject {
        let item = items(in: menu).first { $0.value(forKey: "title") as? String == title }
        return try XCTUnwrap(item?.value(forKey: "submenu") as? NSObject, "Missing submenu \(title) from \(titles(in: menu))")
    }

    @MainActor private func request(for item: NSObject) -> LibraryWindowRequest? {
        (item.value(forKey: "representedObject") as? URL).flatMap { MacStatusMenu.request(for: $0) }
    }
}
#endif
