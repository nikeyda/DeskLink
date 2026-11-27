#if targetEnvironment(simulator)
import XCTest

@MainActor final class ClipboardNotificationUITests: XCTestCase {
    func testClipboardNotificationPreferencePersistsIndependentlyOfSharing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        func openSettings() {
            let more = app.buttons["library.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
        }

        openSettings()
        let notice = app.switches["preferences.clipboardNotifications"]
        let sharing = app.switches["preferences.sharedClipboard"]
        XCTAssertTrue(notice.waitForExistence(timeout: 6))
        XCTAssertEqual(notice.value as? String, "1")
        XCTAssertEqual(sharing.value as? String, "1")
        notice.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
        XCTAssertEqual(sharing.value as? String, "1")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Clipboard notification disabled"
        image.lifetime = .keepAlways
        add(image)

        app.terminate()
        app.launch()
        openSettings()
        XCTAssertTrue(notice.waitForExistence(timeout: 6))
        XCTAssertEqual(notice.value as? String, "0")
        XCTAssertEqual(sharing.value as? String, "1")
    }
}
#endif
