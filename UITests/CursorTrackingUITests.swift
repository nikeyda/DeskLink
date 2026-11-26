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
        let trackpad = editor.switches["connection.trackpad"].firstMatch
        reveal(trackpad, in: editor)
        trackpad.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(trackpad.value as? String, "1")
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
