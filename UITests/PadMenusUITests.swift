#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor final class PadMenusUITests: XCTestCase {
    func testQuickConnectObserveAndDisconnectFromTheSystemMenu() async throws {
        guard #available(iOS 26, *), UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Requires the iPad system menu bar")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let display = LocalTestDisplay()
        let port = try await display.start()
        defer { display.stop() }

        let app = XCUIApplication()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 12))

        func command(_ titles: String...) -> XCUIElement {
            let query = NSPredicate(format: "label IN %@", titles)
            let item = system.descendants(matching: .any).matching(query).firstMatch
            return item.exists ? item : app.descendants(matching: .any).matching(query).firstMatch
        }

        func revealMenu() {
            if #available(iOS 27, *) {
                for x in [0.29, 0.23] {
                    app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.013)).tap()
                    if command("文件", "File").exists { break }
                }
            } else {
                let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.002))
                top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 90)))
            }
        }

        func attachMenu(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func waitForDisplay(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(condition(), display.failure ?? "The test display did not receive the expected update")
        }

        revealMenu()
        attachMenu("iPad app menu")
        let file = command("文件", "File")
        guard file.waitForExistence(timeout: 3) else {
            let hierarchy = XCTAttachment(string: system.debugDescription + "\n" + app.debugDescription)
            hierarchy.name = "iPad menu accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            throw XCTSkip("The automation host does not expose the iPad system menu. Use Windowed Apps.")
        }
        file.tap()
        let quick = command("快速连接…")
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        quick.tap()
        let address = app.textFields["connection.host"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("127.0.0.1:\(port)")
        app.buttons["connection.submit"].tap()
        try await waitForDisplay { display.frameCount > 0 }
        let mode = app.buttons["session.mode"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 12))
        XCTAssertEqual(mode.label, "控制")

        revealMenu()
        let remoteInput = command("远程输入")
        XCTAssertTrue(remoteInput.waitForExistence(timeout: 5))
        remoteInput.tap()
        let insert = command("Insert")
        XCTAssertTrue(insert.waitForExistence(timeout: 5))
        insert.tap()
        try await waitForDisplay { display.keyDowns.contains(0xff63) }

        revealMenu()
        let connection = command("连接")
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        connection.tap()
        attachMenu("iPad connection menu")
        command("仅观察").tap()
        XCTAssertEqual(mode.label, "仅观察")

        revealMenu()
        let observingInputMenu = command("远程输入")
        if observingInputMenu.exists, observingInputMenu.isHittable, observingInputMenu.isEnabled {
            observingInputMenu.tap()
            let observingInsert = command("Insert")
            XCTAssertFalse(observingInsert.exists && observingInsert.isEnabled)
        }
        command("连接").tap()
        XCTAssertTrue(command("控制远程电脑").exists)
        attachMenu("iPad observing menu")
        display.expectsClientDisconnect = true
        command("断开连接").tap()
        try await waitForDisplay { display.closedConnections == 1 }
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
    }
}
#endif
