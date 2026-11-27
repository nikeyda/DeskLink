import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class SharedConnectionUITests: XCTestCase {
    func testDesktopLinkStartsInObservationWithTheSharedQuality() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = launchLibrary()
        app.open(try XCTUnwrap(URL(string: "desklink://127.0.0.1:\(port)?observe=true&quality=lossless")))
        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["connection.host"].value as? String, "127.0.0.1")
        XCTAssertEqual(app.textFields["connection.port"].value as? String, String(port))

        let observe = app.switches["connection.observe"].firstMatch
        reveal(observe, in: app)
        XCTAssertEqual(observe.value as? String, "1")
        let displays = app.buttons["显示器"].firstMatch
        reveal(displays, in: app)
        displays.tap()
        let quality = app.descendants(matching: .any)["connection.quality"].firstMatch
        reveal(quality, in: app)
        let selection = [quality.label, quality.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(selection.contains("完整质量"), selection)
        let form = XCTAttachment(screenshot: app.screenshot())
        form.name = "Shared observation and quality in the receiving form"
        form.lifetime = .keepAlways
        add(form)

        XCTAssertEqual(desktop.acceptedConnections, 0)
        submit.tap()
        let mode = app.buttons["session.mode"].firstMatch
        let deadline = ContinuousClock.now + .seconds(12)
        while (desktop.frameCount == 0 || !mode.exists || mode.label != "仅观察") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(desktop.frameCount, 0)
        XCTAssertEqual(mode.label, "仅观察")
    }

    func testSecureLinkKeepsSeparateDesktopAndGatewayEndpoints() throws {
        continueAfterFailure = false
        let app = launchLibrary()
        let link = "desklink://[2001:db8::12]:5907?ssh=2243&server=gateway.fixture.invalid&observe=1"
        app.open(try XCTUnwrap(URL(string: link)))
        let host = app.textFields["connection.host"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        XCTAssertEqual(host.value as? String, "2001:db8::12")
        XCTAssertEqual(app.textFields["connection.port"].firstMatch.value as? String, "5907")
        let gateway = app.textFields["connection.sshServer"].firstMatch
        reveal(gateway, in: app)
        XCTAssertEqual(gateway.value as? String, "gateway.fixture.invalid")
        XCTAssertEqual(app.textFields["connection.sshPort"].firstMatch.value as? String, "2243")
        let observe = app.switches["connection.observe"].firstMatch
        reveal(observe, in: app)
        XCTAssertEqual(observe.value as? String, "1")
        XCTAssertFalse(app.buttons["connection.submit"].firstMatch.isEnabled)
    }

    private func launchLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
}
#endif
