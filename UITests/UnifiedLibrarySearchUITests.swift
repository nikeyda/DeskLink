import UIKit
import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class UnifiedLibrarySearchUITests: XCTestCase {
    func testIPhoneSearchOpensSavedComputerAndQuickLinkAcrossCategories() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"].firstMatch
        let all = app.descendants(matching: .any).matching(identifier: "library.all").firstMatch
        if all.isHittable && !create.isHittable { all.tap() }
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let host = app.textFields["connection.host"].firstMatch
        let name = app.textFields["connection.name"].firstMatch
        let portField = app.textFields["connection.port"].firstMatch
        let connect = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        name.tap()
        name.typeText("Unified Studio")
        host.tap()
        host.typeText("unified-studio.fixture.invalid:5912")
        name.tap()
        XCTAssertEqual(host.value as? String, "unified-studio.fixture.invalid")
        XCTAssertEqual(portField.value as? String, "5912")
        XCTAssertTrue(connect.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        connect.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 8))

        let quickEndpoint = "127.0.0.1:\(port)"
        app.open(try XCTUnwrap(URL(string: "vnc://" + quickEndpoint)))
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let deadline = ContinuousClock.now + .seconds(20)
        while desktop.frameCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(120))
        }
        XCTAssertGreaterThan(desktop.frameCount, 0)
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 10))

        let favorites = app.descendants(matching: .any).matching(identifier: "library.favorites").firstMatch
        if !favorites.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(favorites.isHittable)
        favorites.tap()
        XCTAssertTrue(app.navigationBars["收藏"].waitForExistence(timeout: 8))

        func enter(_ query: String) {
            let field = app.searchFields.firstMatch
            if !field.isHittable {
                let search = app.buttons.matching(NSPredicate(format: "label IN %@", ["搜索", "Search", "搜索所有来源"])).firstMatch
                if search.isHittable { search.tap() }
                else { app.swipeDown() }
            }
            XCTAssertTrue(field.waitForExistence(timeout: 6))
            field.tap()
            field.typeText(query)
        }
        func result(_ source: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.search." + source + ".")).firstMatch
        }

        enter("Studio 5912")
        let saved = result("saved")
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(saved.label.contains("Unified Studio"))
        XCTAssertTrue(app.searchFields.firstMatch.isHittable)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Studio 5912")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Unified library search from Favorites"
        capture.lifetime = .keepAlways
        add(capture)
        saved.tap()
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(host.value as? String, "unified-studio.fixture.invalid")
        XCTAssertEqual(portField.value as? String, "5912")
        app.buttons["取消"].firstMatch.tap()

        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(all.waitForExistence(timeout: 8))
        enter(quickEndpoint)
        let link = result("link")
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        XCTAssertFalse(result("recent").exists)
        XCTAssertTrue(app.searchFields.firstMatch.isHittable)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, quickEndpoint)
        let sidebarCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sidebarCapture.name = "Unified library search from Sidebar"
        sidebarCapture.lifetime = .keepAlways
        add(sidebarCapture)
        link.tap()
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(host.value as? String, "127.0.0.1")
        XCTAssertEqual(portField.value as? String, String(port))
    }
}
#endif
