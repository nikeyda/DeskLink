#if targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import DeskLink

@MainActor final class MacDockShortcutsTests: XCTestCase {
    func testRecentShortcutsTrackHistoryPrivacyAndSidebarVisibility() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ConnectionLibrary(file: directory.appending(path: "library.json"))
        let unused = Computer(name: "Unused", endpoint: try Endpoint(address: "unused.invalid"))
        XCTAssertTrue(library.save(unused))

        var entries: [Computer] = []
        for index in 0..<12 {
            var entry = Computer(name: "Dock fixture \(index)", endpoint: try Endpoint(address: "dock-\(index).invalid"))
            if index == 11 { entry.saved = false; entry.openedFromLink = true }
            library.recordSuccess(entry, now: Date(timeIntervalSince1970: Double(index + 1)))
            entries.append(entry)
        }
        let shortcuts = MacDockShortcuts.items(in: library.archive, locked: false, showsRecents: true)
        let expected = entries.suffix(10).reversed()
        XCTAssertEqual(shortcuts.map(\.localizedTitle), expected.map(\.displayName))
        XCTAssertEqual(shortcuts.compactMap(MacDockShortcuts.request), expected.map { .connection($0.id) })
        XCTAssertTrue(MacDockShortcuts.items(in: library.archive, locked: true, showsRecents: true).isEmpty)
        XCTAssertTrue(MacDockShortcuts.items(in: library.archive, locked: false, showsRecents: false).isEmpty)

        let removed = try XCTUnwrap(entries.last)
        library.remove(removed)
        let remaining = MacDockShortcuts.items(in: library.archive, locked: false, showsRecents: true)
        XCTAssertEqual(remaining.first.flatMap(MacDockShortcuts.request), .connection(entries[10].id))
        XCTAssertFalse(remaining.compactMap(MacDockShortcuts.request).contains(.connection(removed.id)))
    }

    func testOnlyExactRecentActionIdentifiersCanOpenAConnection() {
        for invalid in ["local.nikey.desklink.dock.recent.", "local.nikey.desklink.dock.recent.invalid", "desklink:///quick"] {
            let action = UIApplicationShortcutItem(type: invalid, localizedTitle: "Fixture")
            XCTAssertNil(MacDockShortcuts.request(for: action))
        }
    }
}
#endif
