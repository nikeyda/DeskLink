#if targetEnvironment(macCatalyst)
import XCTest

@MainActor final class MacDockMenuUITests: XCTestCase {
    func testDockRecentReconnectsToTheSelectedComputer() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        func requireFrame(after previousCount: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(12)
            while desktop.frameCount <= previousCount && desktop.failure == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(desktop.failure)
            XCTAssertGreaterThan(desktop.frameCount, previousCount, "Accepted connections: \(desktop.acceptedConnections)")
        }
        let address = "127.0.0.1"
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()

        let quick = app.buttons["library.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let host = app.textFields["connection.host"].firstMatch
        let portField = app.textFields["connection.port"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        host.click()
        host.typeText(address)
        portField.click()
        portField.typeKey("a", modifierFlags: .command)
        portField.typeText(String(port))
        XCTAssertEqual(host.value as? String, address)
        XCTAssertEqual(portField.value as? String, String(port))
        app.buttons["connection.submit"].firstMatch.click()
        let close = app.buttons["session.close"].firstMatch
        try await requireFrame(after: 0)
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        close.click()
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        let disconnected = ContinuousClock.now + .seconds(6)
        while desktop.closedConnections == 0 && ContinuousClock.now < disconnected {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(desktop.closedConnections, 1)

        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let tileQuery = dock.descendants(matching: .dockItem)
            .matching(NSPredicate(format: "title IN %@", ["Telescope", "远程随航"]))
        XCTAssertTrue(tileQuery.firstMatch.waitForExistence(timeout: 6))
        let tile = try XCTUnwrap(tileQuery.allElementsBoundByIndex.last)
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let entry = dock.menuItems.matching(NSPredicate(format: "title == %@ OR label == %@", address, address)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 6), "The system Dock menu should contain the loopback computer.")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Telescope recent connection in the macOS Dock"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let framesBeforeReopening = desktop.frameCount
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let dialogDeadline = ContinuousClock.now + .seconds(6)
        while !host.exists && desktop.acceptedConnections < 2 && ContinuousClock.now < dialogDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        if host.exists {
            XCTAssertEqual(host.value as? String, address)
            XCTAssertEqual(portField.value as? String, String(port))
            app.buttons["connection.submit"].firstMatch.click()
        }
        try await requireFrame(after: framesBeforeReopening)
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        XCTAssertEqual(desktop.acceptedConnections, 2)
    }
}
#endif
