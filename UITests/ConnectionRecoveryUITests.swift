import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class ConnectionRecoveryUITests: XCTestCase {
    func testChangingThePortInTheLoginFormRecordsTheDesktopActuallyReached() async throws {
        continueAfterFailure = false
        let savedDesktop = LocalTestDisplay()
        let otherDesktop = LocalTestDisplay()
        let savedPort = try await savedDesktop.start()
        let otherPort = try await otherDesktop.start()
        defer { savedDesktop.stop(); otherDesktop.stop() }

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let create = app.buttons["library.empty.new"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        create.tap()
        let name = app.textFields["connection.name"].firstMatch
        let host = app.textFields["connection.host"].firstMatch
        let port = app.textFields["connection.port"].firstMatch
        let submit = app.buttons["connection.submit"].firstMatch
        name.tap()
        name.typeText("Saved test desktop")
        host.tap()
        host.typeText("127.0.0.1:\(savedPort)")
        submit.tap()

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer."))
        let saved = rows.matching(NSPredicate(format: "label CONTAINS %@", "Saved test desktop")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        let savedID = saved.identifier
        saved.tap()
        XCTAssertTrue(port.waitForExistence(timeout: 8))
        let initialPort = try XCTUnwrap(port.value as? String)
        XCTAssertEqual(initialPort, String(savedPort))
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: initialPort.count) + String(otherPort))
        XCTAssertEqual(port.value as? String, String(otherPort))
        submit.tap()

        let deadline = ContinuousClock.now + .seconds(14)
        while otherDesktop.frameCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(otherDesktop.frameCount, 0)
        XCTAssertEqual(savedDesktop.acceptedConnections, 0)
        XCTAssertEqual(otherDesktop.acceptedConnections, 1)
        XCTAssertTrue(app.buttons["session.mode"].firstMatch.waitForExistence(timeout: 8))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[savedID].firstMatch.waitForExistence(timeout: 8))
        let recentSection = app.staticTexts["最近连接"].firstMatch
        if !recentSection.isHittable, app.buttons["ToggleSideBar"].firstMatch.isHittable {
            app.buttons["ToggleSideBar"].firstMatch.tap()
        }
        XCTAssertTrue(recentSection.waitForExistence(timeout: 8))
        recentSection.tap()

        let recent = rows.firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotEqual(recent.identifier, savedID)
        recent.tap()
        XCTAssertTrue(port.waitForExistence(timeout: 8))
        XCTAssertEqual(port.value as? String, String(otherPort))
    }

    func testRejectedSSHLoginReopensTheFormAndConnectsWithTheCorrectedPassword() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires the loopback SSH chart.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        app.open(try XCTUnwrap(URL(string: "ssh://fixture:rejected-fixture@127.0.0.1:\(port)")))
        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 12))
        submit.tap()
        let fingerprint = app.alerts["主机指纹"].firstMatch
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 10))
        XCTAssertTrue(fingerprint.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", pin)).firstMatch.exists)
        fingerprint.buttons["确认"].tap()

        let failure = app.descendants(matching: .any).matching(identifier: "session.failureTitle").firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 12))
        XCTAssertEqual(failure.label, "SSH 登录失败")
        XCTAssertFalse(app.buttons["session.reconnect"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "SSH login failure opens credential editing"
        capture.lifetime = .keepAlways
        add(capture)

        app.buttons["session.editConnection"].firstMatch.tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        let form = app.collectionViews["connection.form"].firstMatch
        let password = form.secureTextFields["connection.sshPassword"].firstMatch
        for _ in 0..<5 where !password.isHittable { form.swipeUp() }
        XCTAssertTrue(password.isHittable, form.debugDescription)
        XCTAssertEqual(form.textFields["connection.sshUsername"].value as? String, "fixture")
        XCTAssertFalse((password.value as? String)?.contains("•") == true)
        password.tap()
        password.typeText("chart-test-only")
        submit.tap()
        let info = app.buttons["session.info"].firstMatch
        XCTAssertTrue(info.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        info.tap()
        let route = app.descendants(matching: .any)["details.route"].firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 8))
        XCTAssertEqual(route.value as? String, "SSH 隧道")
    }

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
