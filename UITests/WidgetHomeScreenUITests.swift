#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest

@MainActor final class WidgetHomeScreenUITests: XCTestCase {
    func testHomeScreenWidgetOpensQuickConnection() throws {
        #if !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKLINK_SYSTEM_WIDGET_ON_DEVICE"] == "1",
                          "Run explicitly on the acceptance iPad with the app icon or widget on its Home Screen.")
        #endif
        let app = XCUIApplication()
        app.launch()
        let host = app.textFields["connection.host"]
        if host.isHittable { app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch.tap() }
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        XCTAssertFalse(host.exists)
        XCUIDevice.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let names = ["远程随航", "Telescope"]
        let named = home.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", names))
        let widget = named.matching(NSPredicate(format: "value IN %@", ["小组件", "Widget"])).firstMatch
        let icon = home.icons.matching(NSPredicate(format: "label IN %@", names)).firstMatch
        if !widget.isHittable && !icon.isHittable {
            // A second Home press returns to the first page. Swipe on the wallpaper so
            // a horizontal scroll inside a widget cannot consume the gesture.
            XCUIDevice.shared.press(.home)
            let from = home.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.74))
            let to = home.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.74))
            for _ in 0..<8 {
                if widget.isHittable || icon.isHittable { break }
                if home.searchFields.firstMatch.isHittable { break }
                from.press(forDuration: 0.05, thenDragTo: to)
            }
        }
        var convertedIcon = false
        let restore = {
            XCUIDevice.shared.press(.home)
            guard convertedIcon, widget.waitForExistence(timeout: 5) else { return }
            widget.press(forDuration: 0.8)
            let iconMode = home.buttons.matching(NSPredicate(format: "label IN %@", ["App图标", "App Icon"])).firstMatch
            XCTAssertTrue(iconMode.waitForExistence(timeout: 4))
            if iconMode.isHittable { iconMode.tap() }
            XCTAssertTrue(widget.waitForNonExistence(timeout: 7))
        }
        defer { restore() }
        if !widget.isHittable {
            guard icon.isHittable else { return XCTFail("No Home Screen page displayed the app icon or widget.") }
            icon.press(forDuration: 0.8)
            let small = home.buttons.matching(NSPredicate(format: "label IN %@", ["小型小组件", "Small Widget"])).firstMatch
            XCTAssertTrue(small.waitForExistence(timeout: 4))
            small.tap()
            convertedIcon = true
        }
        XCTAssertTrue(widget.waitForExistence(timeout: 8))
        widget.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["connection.port"].value as? String, "5900")
        XCTAssertFalse(app.buttons["connection.submit"].isEnabled)
    }
}
#endif
