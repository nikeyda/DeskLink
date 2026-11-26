#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class PointerModeUITests: XCTestCase {
    func testDefaultAndSessionPointerChoicesReachTheRemoteDesktop() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()

        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["设置"].firstMatch.tap()
        let preference = app.descendants(matching: .any).matching(identifier: "preferences.pointerMode").firstMatch
        for _ in 0..<6 where !preference.isHittable { app.swipeUp() }
        XCTAssertTrue(preference.isHittable)
        preference.tap()
        app.buttons["触控板"].firstMatch.tap()
        app.buttons["关闭"].firstMatch.tap()

        let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        let mode = app.buttons["session.mode"].firstMatch
        let fixture = try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)"))
        func connect() async throws {
            let previous = desktop.frameCount
            app.open(fixture)
            let submit = app.buttons["connection.submit"].firstMatch
            XCTAssertTrue(submit.waitForExistence(timeout: 8))
            submit.tap()
            try await waitUntil { desktop.frameCount > previous && input.isHittable && mode.exists }
        }
        func tapSeparation() async throws -> Int {
            let prior = desktop.primaryPresses.count
            for x in [0.26, 0.73] {
                input.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
                let expected = prior + (x < 0.5 ? 1 : 2)
                try await waitUntil { desktop.primaryPresses.count >= expected }
            }
            return abs(desktop.primaryPresses[prior + 1] - desktop.primaryPresses[prior])
        }
        func openPointerMenu() {
            app.buttons["远程桌面控制"].firstMatch.tap()
            app.buttons["指针"].firstMatch.tap()
        }

        try await connect()
        let initial = try await tapSeparation()
        XCTAssertLessThanOrEqual(initial, 2)
        openPointerMenu()
        app.buttons["触摸"].firstMatch.tap()
        let changed = try await tapSeparation()
        XCTAssertGreaterThan(changed, 35)
        mode.tap()
        try await waitUntil { mode.label == "仅观察" && !input.isHittable }
        mode.tap()
        try await waitUntil { input.isHittable }
        let restored = try await tapSeparation()
        XCTAssertGreaterThan(restored, 35)
        XCTAssertEqual(desktop.acceptedConnections, 1)

        openPointerMenu()
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Touch mode retained after observation"
        screen.lifetime = .keepAlways
        add(screen)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45)).tap()
        app.buttons["session.close"].firstMatch.tap()
        try await waitUntil { desktop.closedConnections == 1 }

        try await connect()
        let subsequent = try await tapSeparation()
        XCTAssertLessThanOrEqual(subsequent, 2)
        XCTAssertEqual(desktop.acceptedConnections, 2)
        let receipt = XCTAttachment(string: "Default: \(initial) px\nTouch: \(changed) px\nAfter observing: \(restored) px\nNext session: \(subsequent) px")
        receipt.name = "Pointer mode distances"
        receipt.lifetime = .keepAlways
        add(receipt)
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
