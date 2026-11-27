import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class RemoteAppSwitcherUITests: XCTestCase {
    func testRemoteAppSwitcherDefaultsToOffAndRemembersTheSetting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()

        let toggle = revealAppSwitcherSetting(in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")

        app.terminate()
        app.launch()
        XCTAssertEqual(revealAppSwitcherSetting(in: app).value as? String, "1")
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Remote Mac app-switcher setting"
        screen.lifetime = .keepAlways
        add(screen)
    }

    private func revealAppSwitcherSetting(in app: XCUIApplication) -> XCUIElement {
        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["设置"].firstMatch.tap()

        let toggle = app.switches["preferences.remoteAppSwitcher"].firstMatch
        let form = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
            ?? app.collectionViews.firstMatch
        for _ in 0..<7 where !toggle.isHittable { form.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        return toggle
    }
}
#endif
