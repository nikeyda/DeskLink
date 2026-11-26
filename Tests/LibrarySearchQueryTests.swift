import XCTest
@testable import DeskLink

final class LibrarySearchQueryTests: XCTestCase {
    func testSearchComposesTermsAcrossFieldsWithCaseAndAccentFolding() throws {
        var item = Computer(name: "Café Studio", endpoint: try Endpoint(address: "office.invalid:5910"))
        item.folder = "Production"
        item.username = "private-account"
        let results = LibrarySearchQuery("  CAFE\t5910 production ").storedMatches(in: [item])
        XCTAssertEqual(results.saved, [item])
        XCTAssertTrue(LibrarySearchQuery("private-account").storedMatches(in: [item]).isEmpty)
        XCTAssertTrue(LibrarySearchQuery("  \t\n").isEmpty)
    }

    func testSavedLinksAndRecentConnectionsAppearOnceInTheirMostSpecificSection() throws {
        func computer(_ title: String) throws -> Computer {
            Computer(name: title, endpoint: try Endpoint(address: "test.invalid"))
        }
        var saved = try computer("Fixture Saved")
        saved.openedFromLink = true
        saved.lastConnected = .now
        var link = try computer("Fixture Link")
        link.saved = false
        link.openedFromLink = true
        link.lastConnected = .now
        var recent = try computer("Fixture Recent")
        recent.saved = false
        recent.lastConnected = .now
        var unused = try computer("Fixture Unused")
        unused.saved = false

        let results = LibrarySearchQuery("fixture").storedMatches(in: [recent, link, unused, saved])
        XCTAssertEqual(results.saved, [saved])
        XCTAssertEqual(results.links, [link])
        XCTAssertEqual(results.recent, [recent])
    }
}
