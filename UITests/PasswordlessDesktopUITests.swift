#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor final class PasswordlessDesktopUITests: XCTestCase {
    func testAnEmptyPasswordCanBeRememberedAfterAConnectionAndUsedAfterRelaunch() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let quick = app.buttons["library.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 10))
        let username = "fixture-" + UUID().uuidString.lowercased()
        app.open(try XCTUnwrap(URL(string: "vnc://\(username)@127.0.0.1:\(port)")))
        let remember = app.switches["connection.remember"].firstMatch
        XCTAssertTrue(remember.waitForExistence(timeout: 8))
        XCTAssertEqual(remember.value as? String, "0")
        remember.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(remember.value as? String, "1")
        app.buttons["connection.submit"].firstMatch.tap()

        func waitForDisplay(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        try await waitForDisplay { desktop.frameCount >= 1 }
        let session = app.buttons["session.mode"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 8))
        app.terminate()
        try await waitForDisplay { desktop.closedConnections == 1 }
        let framesBeforeReconnect = desktop.frameCount
        app.launch()
        let recent = app.staticTexts["最近连接"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        recent.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        try await waitForDisplay { desktop.frameCount > framesBeforeReconnect }
        XCTAssertTrue(session.waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["connection.host"].exists)
        XCTAssertEqual(desktop.acceptedConnections, 2)
        let receipt = XCTAttachment(string: "Successful loopback connections: \(desktop.acceptedConnections)\nReceived frames after relaunch: \(desktop.frameCount - framesBeforeReconnect)")
        receipt.name = "Remembered empty password reconnect"
        receipt.lifetime = .keepAlways
        add(receipt)
    }
}
#endif
