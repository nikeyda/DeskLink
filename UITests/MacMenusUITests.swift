#if targetEnvironment(macCatalyst)
import XCTest

@MainActor final class MacMenusUITests: XCTestCase {
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
