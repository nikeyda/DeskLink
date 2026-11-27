import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class ConnectionRecoveryUITests: XCTestCase {
    func testRetryAfterTheFirstHandshakeClosesOpensTheSameConnection() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        desktop.connectionsToCloseBeforeHandshake = 1
        let port = try await desktop.start()
        defer { desktop.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let connect = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 12))
        connect.tap()

        let retry = app.buttons["session.reconnect"].firstMatch
        let failureDeadline = ContinuousClock.now + .seconds(18)
        while !retry.exists && ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(retry.exists)
        XCTAssertTrue(app.buttons["session.editConnection"].exists)
        XCTAssertEqual(desktop.acceptedConnections, 1)
        let failureScreen = XCTAttachment(screenshot: app.screenshot())
        failureScreen.name = "Initial connection failure recovery actions"
        failureScreen.lifetime = .keepAlways
        add(failureScreen)
        retry.tap()

        let deadline = ContinuousClock.now + .seconds(12)
        while desktop.frameCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(desktop.frameCount, 0)
        XCTAssertEqual(desktop.acceptedConnections, 2)
        XCTAssertFalse(connect.exists)
        XCTAssertTrue(app.buttons["session.mode"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(retry.exists)

        app.buttons["session.info"].firstMatch.tap()
        let route = app.descendants(matching: .any)["details.route"].firstMatch
        let encryption = app.descendants(matching: .any)["details.encryption"].firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 8))
        XCTAssertEqual(route.value as? String, "直接连接")
        XCTAssertEqual(encryption.value as? String, "未加密")
        let connectionInfo = XCTAttachment(screenshot: app.screenshot())
        connectionInfo.name = "Direct transport and encryption details"
        connectionInfo.lifetime = .keepAlways
        add(connectionInfo)
    }

    func testCancelWhileWaitingForTheHandshakeClosesTheConnection() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        desktop.waitsForCancellationBeforeHandshake = true
        desktop.expectsClientDisconnect = true
        let port = try await desktop.start()
        defer { desktop.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let connect = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 12))
        connect.tap()

        let cancel = app.buttons["session.cancelConnection"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let connectionDeadline = ContinuousClock.now + .seconds(4)
        while desktop.acceptedConnections == 0 && ContinuousClock.now < connectionDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(desktop.acceptedConnections, 1)
        cancel.tap()

        let closeDeadline = ContinuousClock.now + .seconds(5)
        while desktop.closedConnections == 0 && ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(desktop.closedConnections, 1)
        XCTAssertFalse(cancel.exists)
        XCTAssertFalse(app.buttons["session.reconnect"].exists)
        XCTAssertTrue(app.buttons["library.quick"].firstMatch.waitForExistence(timeout: 5))
    }
}
#endif
