import XCTest

@MainActor
final class LibraryClickUITests: XCTestCase {
    #if targetEnvironment(macCatalyst)
    func testGridClickSelectsAndDoubleClickOpensTheConnection() {
        let app = libraryWithComputer()
        let item = computer(in: app)
        item.click()
        XCTAssertTrue(item.wait(for: \.isSelected, toEqual: true, timeout: 4))
        XCTAssertFalse(app.textFields["connection.host"].exists)

        item.doubleClick()
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        XCTAssertEqual(host.value as? String, "selection.fixture.invalid")
    }
    func testListClickSelectsAndDoubleClickOpensTheConnection() {
        let app = libraryWithComputer()
        showList(in: app)
        let item = computer(in: app)
        item.click()
        XCTAssertTrue(item.wait(for: \.isSelected, toEqual: true, timeout: 4))
        XCTAssertFalse(app.textFields["connection.host"].exists)
        item.doubleClick()
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        XCTAssertEqual(host.value as? String, "selection.fixture.invalid")
    }

    func testFocusedGridTileOpensWithSpace() {
        let app = libraryWithComputer()
        let item = computer(in: app)
        item.click()
        XCTAssertTrue(item.wait(for: \.isSelected, toEqual: true, timeout: 4))
        XCTAssertFalse(app.textFields["connection.host"].exists)

        app.typeKey(" ", modifierFlags: [])
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        XCTAssertEqual(host.value as? String, "selection.fixture.invalid")
    }

    func testFocusedListRowOpensWithReturnWithoutCapturingSearchInput() {
        let app = libraryWithComputer()
        showList(in: app)
        let item = computer(in: app)
        item.click()
        XCTAssertTrue(item.wait(for: \.isSelected, toEqual: true, timeout: 4))
        XCTAssertFalse(app.textFields["connection.host"].exists)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 6))
        search.click()
        search.typeText("selection")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.textFields["connection.host"].exists)

        item.click()
        app.typeKey(.return, modifierFlags: [])
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        XCTAssertEqual(host.value as? String, "selection.fixture.invalid")
        let window = app.windows.containing(.textField, identifier: "connection.host").firstMatch
        if window.exists {
            let capture = XCTAttachment(screenshot: window.screenshot())
            capture.name = "Connection opened with Return"
            capture.lifetime = .keepAlways
            add(capture)
        }
    }

    private func showList(in app: XCUIApplication) {
        app.buttons["library.more"].firstMatch.click()
        let list = app.menuItems["列表"].firstMatch
        if list.exists { list.click() } else { app.buttons["列表"].firstMatch.click() }
    }
    #else
    func testTouchOpensSavedConnectionOnTheFirstTap() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].firstMatch.waitForExistence(timeout: 10))

        let id = UUID()
        let file = FileManager.default.temporaryDirectory.appending(path: id.uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = """
            {"filename":"Selection test","folders":[],"screens":[{
            "version":6,"id":"\(id.uuidString)","type":{"saved":{}},
            "hostname":"selection.fixture.invalid","port":5900,"clientProtocol":"vnc",
            "users":[],"authenticationMethod":2,"operatingSystem":6,"startInObserveMode":false,
            "onDisconnectAction":0,"useSharedClipboard":true,"useSecureConnection":false}]}
            """
        try Data(fixture.utf8).write(to: file)
        app.open(file)
        let imported = app.alerts["导入完成"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        imported.buttons["完成"].tap()

        computer(in: app).tap()
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        XCTAssertEqual(host.value as? String, "selection.fixture.invalid")
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private func libraryWithComputer() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let add = app.buttons["library.new"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        host.click()
        host.typeText("selection.fixture.invalid")
        app.buttons["connection.submit"].click()
        XCTAssertTrue(host.waitForNonExistence(timeout: 6))
        return app
    }

    #endif

    private func computer(in app: XCUIApplication) -> XCUIElement {
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 6))
        return item
    }
}
