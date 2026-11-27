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
    }

    private func showList(in app: XCUIApplication) {
        app.buttons["library.more"].firstMatch.click()
        let list = app.menuItems["列表"].firstMatch
        if list.exists { list.click() } else { app.buttons["列表"].firstMatch.click() }
    }
    #else
    func testTouchOpensSavedConnectionOnTheFirstTap() {
        let app = libraryWithComputer()
        computer(in: app).tap()
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        XCTAssertEqual(host.value as? String, "selection.fixture.invalid")
    }
    #endif

    private func libraryWithComputer() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let add = app.buttons["library.new"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        press(add)
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 6))
        press(host)
        host.typeText("selection.fixture.invalid")
        press(app.buttons["connection.submit"])
        XCTAssertTrue(host.waitForNonExistence(timeout: 6))
        return app
    }

    private func press(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func computer(in app: XCUIApplication) -> XCUIElement {
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 6))
        return item
    }
}
