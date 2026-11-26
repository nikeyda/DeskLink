#if targetEnvironment(macCatalyst)
import XCTest

@MainActor final class MacMenusUITests: XCTestCase {
    func testMacLocalOptionSettingsAndRemoteKeyboardEvents() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        func chooseOption(_ side: String) {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()
            let menuItem = app.menuItems["设置"].firstMatch
            if menuItem.exists { menuItem.tap() } else { app.buttons["设置"].firstMatch.tap() }
            let picker = app.descendants(matching: .any).matching(identifier: "preferences.localOptionKey").firstMatch
            for _ in 0..<6 where !picker.isHittable {
                app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -230)
            }
            XCTAssertTrue(picker.isHittable)
            picker.tap()
            let option = app.menuItems[side].firstMatch
            if option.exists { option.tap() } else { app.buttons[side].firstMatch.tap() }
            let picture = XCTAttachment(screenshot: app.screenshot())
            picture.name = "Mac settings – " + side
            picture.lifetime = .keepAlways
            add(picture)
            app.buttons["关闭"].firstMatch.tap()
        }

        func waitForWire(_ test: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !test() {
                if ContinuousClock.now >= deadline {
                    XCTFail("Timed out waiting for the remote keys: \(desktop.keyDowns)", file: file, line: line)
                    return
                }
                try await Task.sleep(for: .milliseconds(70))
            }
        }

        func connect() {
            app.typeKey("k", modifierFlags: .command)
            let address = app.textFields["connection.host"]
            XCTAssertTrue(address.waitForExistence(timeout: 8))
            address.tap()
            address.typeText("127.0.0.1:\(port)")
            app.buttons["connection.submit"].firstMatch.tap()
            let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            input.tap()
        }

        chooseOption("Left Option")
        connect()
        var wire: [String] = []
        desktop.onWireKey = { down, symbol in wire.append((down ? "down " : "up ") + String(symbol, radix: 16)) }
        app.typeKey("a", modifierFlags: .option)
        app.typeKey("e", modifierFlags: .option)
        app.typeKey("e", modifierFlags: [])
        app.typeKey("2", modifierFlags: [.shift, .option])
        app.typeKey("n", modifierFlags: .option)
        app.typeKey("n", modifierFlags: [])
        app.typeKey("z", modifierFlags: [])
        try await waitForWire { wire.contains("up 7a") }
        XCTAssertEqual(desktop.keyDowns.filter { $0 != 0xFFE1 && $0 != 0xFFE2 }, [0xE5, 0xE9, 0x010020AC, 0xF1, 0x7A])
        XCTAssertFalse(wire.contains("down ffe9"))
        let textEvents = wire
        app.buttons["session.close"].firstMatch.tap()
        try await waitForWire { desktop.closedConnections == 1 }

        chooseOption("Right Option")
        connect()
        wire.removeAll()
        app.typeKey("a", modifierFlags: .option)
        try await waitForWire { wire.contains("up ffe9") }
        XCTAssertEqual(wire, ["down ffe9", "down 61", "up 61", "up ffe9"])
        let receipt = XCTAttachment(string: (["Left Option"] + textEvents + ["Right Option"] + wire).joined(separator: "\n"))
        receipt.name = "Mac Option RFB events"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testLibraryAndLiveSessionMenusFollowTheActiveWindow() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let connection = app.menuBars.menuBarItems["连接"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.tap()
        XCTAssertFalse(app.menuItems["断开连接"].firstMatch.isEnabled)
        XCTAssertTrue(app.menuItems["文件传输"].firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("k", modifierFlags: .command)
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        host.tap()
        host.typeText("127.0.0.1:\(port)")
        app.buttons["connection.submit"].tap()
        let mode = app.buttons["session.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        connection.tap()
        let observe = app.menuItems["仅观察"].firstMatch
        XCTAssertTrue(observe.isEnabled)
        observe.tap()
        XCTAssertEqual(mode.label, "仅观察")
        let remoteInput = app.menuBars.menuBarItems["远程输入"].firstMatch
        remoteInput.tap()
        XCTAssertFalse(app.menuItems["输入用户密码…"].firstMatch.isEnabled)
        XCTAssertFalse(app.menuItems["Insert"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        connection.tap()
        app.menuItems["控制远程电脑"].firstMatch.tap()
        remoteInput.tap()
        app.menuItems["Insert"].firstMatch.tap()
        let deadline = Date().addingTimeInterval(6)
        while desktop.keyDowns.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(desktop.keyDowns, [0xFF63])
        connection.tap()
        app.menuItems["断开连接"].firstMatch.tap()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 6))
    }
}
#endif
