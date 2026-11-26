#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class CursorTrackingUITests: XCTestCase {
    func testChangingSavedTrackingSpeedMovesTheLiveCursorAndPersists() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.empty.new"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("127.0.0.1:\(port)")

        let editor = app.collectionViews["connection.form"].firstMatch
        let display = editor.buttons["显示器"].firstMatch
        reveal(display, in: editor)
        display.tap()
        let mode = editor.descendants(matching: .any).matching(identifier: "connection.pointerMode").firstMatch
        reveal(mode, in: editor)
        mode.tap()
        app.buttons["触控板"].firstMatch.tap()
        let speed = editor.descendants(matching: .any).matching(identifier: "connection.cursorTrackingSpeed").firstMatch
        reveal(speed, in: editor)
        speed.tap()
        let slowOption = app.buttons["0.5×"].firstMatch
        XCTAssertTrue(slowOption.waitForExistence(timeout: 4))
        slowOption.tap()
        app.buttons["connection.submit"].tap()

        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        saved.tap()
        let connect = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 6))
        connect.tap()
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        try await waitUntil { desktop.frameCount > 0 && surface.isHittable }

        let finger = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.4))
        let end = finger.withOffset(CGVector(dx: 62, dy: 0))
        func stroke() async throws -> CGFloat {
            let clicks = desktop.clicks
            finger.tap()
            try await waitUntil { desktop.clicks > clicks }
            let before = try XCTUnwrap(desktop.latestPointer)
            finger.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            try await waitUntil { desktop.latestPointer != before }
            try await Task.sleep(for: .milliseconds(200))
            return try XCTUnwrap(desktop.latestPointer).x - before.x
        }

        let slow = try await stroke()
        app.buttons["远程桌面控制"].firstMatch.tap()
        app.buttons["显示器"].firstMatch.tap()
        app.buttons["光标跟踪速度"].firstMatch.tap()
        let fastOption = app.buttons["2×"].firstMatch
        XCTAssertTrue(fastOption.waitForExistence(timeout: 4))
        fastOption.tap()
        let fast = try await stroke()
        XCTAssertGreaterThan(slow, 0)
        XCTAssertGreaterThan(fast, 2 * slow, "Received horizontal movement of \(slow) and \(fast) remote pixels.")
        XCTAssertEqual(desktop.acceptedConnections, 1)
        let motion = XCTAttachment(string: "0.5×: \(slow) px\n2×: \(fast) px\nRFB connections: \(desktop.acceptedConnections)")
        motion.name = "Remote pointer movement"
        motion.lifetime = .keepAlways
        add(motion)

        app.buttons["session.close"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 7))
        app.terminate()
        app.launch()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        saved.press(forDuration: 0.8)
        app.buttons["编辑连接"].firstMatch.tap()
        reveal(display, in: editor)
        display.tap()
        reveal(speed, in: editor)
        XCTAssertTrue(speed.label.contains("2×") || (speed.value as? String)?.contains("2×") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cursor speed saved from live session"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSavedInitialFramingChangesPictureAndRemotePresses() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()

        let create = app.buttons["library.empty.new"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("127.0.0.1:\(port)")
        let editor = app.collectionViews["connection.form"].firstMatch
        let display = editor.buttons["显示器"].firstMatch
        let sizing = editor.descendants(matching: .any).matching(identifier: "connection.initialViewportSizing").firstMatch
        func saveFraming(_ name: String) {
            reveal(display, in: editor)
            display.tap()
            reveal(sizing, in: editor)
            sizing.tap()
            let choice = app.buttons[name].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            app.buttons["connection.submit"].firstMatch.tap()
        }
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        func connect() async throws {
            XCTAssertTrue(saved.waitForExistence(timeout: 8))
            let frames = desktop.frameCount
            saved.tap()
            let submit = app.buttons["connection.submit"].firstMatch
            XCTAssertTrue(submit.waitForExistence(timeout: 6))
            submit.tap()
            try await waitUntil { desktop.frameCount > frames && input.isHittable }
        }
        func pressSeparation() async throws -> Int {
            let center = input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let prior = desktop.primaryPresses.count
            center.withOffset(CGVector(dx: -14, dy: 0)).tap()
            try await waitUntil { desktop.primaryPresses.count >= prior + 1 }
            center.withOffset(CGVector(dx: 14, dy: 0)).tap()
            try await waitUntil { desktop.primaryPresses.count >= prior + 2 }
            return desktop.primaryPresses[prior + 1] - desktop.primaryPresses[prior]
        }
        func capture(_ name: String) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        saveFraming("实际大小")
        try await connect()
        let actual = try await pressSeparation()
        XCTAssertEqual(Double(actual), 28 * UIScreen.main.scale, accuracy: 2)
        capture("Actual size with a 160×96 remote picture")
        app.buttons["session.close"].firstMatch.tap()
        try await waitUntil { desktop.closedConnections == 1 }

        saved.press(forDuration: 0.8)
        app.buttons["编辑连接"].firstMatch.tap()
        saveFraming("填满屏幕")
        app.terminate()
        app.launch()
        try await connect()
        let fill = try await pressSeparation()
        XCTAssertGreaterThan(fill, 0)
        XCTAssertLessThan(fill, actual / 2)
        capture("Fill with the same remote picture")
        let receipt = XCTAttachment(string: "Actual size: \(actual) px\nFill: \(fill) px")
        receipt.name = "Remote pointer distances for initial framing"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    private func reveal(_ element: XCUIElement, in form: XCUIElement) {
        for _ in 0..<8 {
            if element.isHittable, form.frame.insetBy(dx: 0, dy: 15).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                return
            }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.36)))
        }
        XCTFail("Could not reveal \(element)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(60))
        }
    }
}
#endif
