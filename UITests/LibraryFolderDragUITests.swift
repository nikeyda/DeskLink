import XCTest

@MainActor
final class LibraryFolderDragUITests: XCTestCase {
    func testGridReorderAndFolderMovesFromBothLayouts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].firstMatch.waitForExistence(timeout: 10))

        let all = app.descendants(matching: .any).matching(identifier: "library.all").firstMatch
        let folderName = "QA-Workspace"
        #if targetEnvironment(macCatalyst)
        let enteredName = try seedMacLibrary(in: app, folderName: folderName)
        press(all)
        let first = computer("alpha.fixture.invalid", in: app)
        let second = computer("beta.fixture.invalid", in: app)
        #else
        let firstID = UUID()
        let secondID = UUID()
        try importLibrary(in: app, firstID: firstID, secondID: secondID, folderName: folderName)
        let enteredName = folderName
        let first = app.buttons["library.computer." + firstID.uuidString].firstMatch
        let second = app.buttons["library.computer." + secondID.uuidString].firstMatch
        #endif
        let folder = app.descendants(matching: .any).matching(identifier: "library.folder." + enteredName).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertTrue(folder.waitForExistence(timeout: 8))

        func precedes(_ lhs: XCUIElement, _ rhs: XCUIElement) -> Bool {
            let rowDifference = lhs.frame.minY - rhs.frame.minY
            return abs(rowDifference) < 10 ? lhs.frame.minX < rhs.frame.minX : rowDifference < 0
        }
        XCTAssertTrue(precedes(first, second))
        drag(second, onto: first)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in precedes(second, first) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 7), .completed)

        drag(first, onto: folder)
        press(folder)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertFalse(second.exists)
        XCTAssertFalse(app.textFields["connection.host"].exists)

        let attachment: XCTAttachment
        #if targetEnvironment(macCatalyst)
        attachment = XCTAttachment(screenshot: app.windows.containing(.button, identifier: "library.more").firstMatch.screenshot())
        #else
        attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = "Connection moved into a sidebar folder"
        attachment.lifetime = .keepAlways
        add(attachment)

        #if targetEnvironment(macCatalyst)
        press(app.buttons["library.presentation"].firstMatch)
        #else
        press(app.buttons["library.more"].firstMatch)
        #endif
        let list = app.menuItems["列表"].firstMatch
        press(list.exists ? list : app.buttons["列表"].firstMatch)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        drag(first, onto: all)
        XCTAssertTrue(first.waitForNonExistence(timeout: 8))
        press(all)
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(second.exists)
        XCTAssertLessThan(second.frame.minY, first.frame.minY)
        drag(first, onto: second, destinationY: 0.25)
        let listReordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            first.frame.minY < second.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [listReordered], timeout: 7), .completed)

        app.terminate()
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        press(folder)
        XCTAssertTrue(first.waitForNonExistence(timeout: 8))
        XCTAssertFalse(second.exists)
    }

    #if targetEnvironment(macCatalyst)
    private func seedMacLibrary(in app: XCUIApplication, folderName: String) throws -> String {
        for name in ["alpha.fixture.invalid", "beta.fixture.invalid"] {
            press(app.buttons["library.new"].firstMatch)
            let host = app.textFields["connection.host"].firstMatch
            XCTAssertTrue(host.waitForExistence(timeout: 6))
            press(host)
            host.typeText(name)
            press(app.buttons["connection.submit"].firstMatch)
            XCTAssertTrue(host.waitForNonExistence(timeout: 6))
        }
        press(app.buttons["library.more"].firstMatch)
        let newFolder = app.menuItems["新建文件夹"].firstMatch
        press(newFolder.exists ? newFolder : app.buttons["新建文件夹"].firstMatch)
        let form = app.sheets["新建文件夹"].firstMatch
        let name = form.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 6))
        press(name)
        name.typeText(folderName)
        let enteredName = try XCTUnwrap(name.value as? String)
        press(form.buttons["保存"].firstMatch)
        XCTAssertTrue(form.waitForNonExistence(timeout: 6))
        return enteredName
    }

    private func computer(_ host: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                         "library.computer.", host)).firstMatch
    }
    #else
    private func importLibrary(in app: XCUIApplication, firstID: UUID, secondID: UUID, folderName: String) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        func screen(id: UUID, name: String, host: String) -> [String: Any] {
            ["id": id.uuidString, "name": name, "hostname": host, "version": 6, "type": ["saved": [:]],
             "port": 5900, "clientProtocol": "vnc", "users": [], "authenticationMethod": 2, "operatingSystem": 6,
             "startInObserveMode": false, "onDisconnectAction": 0, "useSharedClipboard": true, "useSecureConnection": false]
        }
        let fixture: [String: Any] = [
            "filename": "Folder drag fixture", "folders": [["name": folderName, "items": [], "contentType": 8]],
            "screens": [screen(id: firstID, name: "Alpha", host: "alpha.fixture.invalid"),
                        screen(id: secondID, name: "Beta", host: "beta.fixture.invalid")]
        ]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        app.open(file)
        let imported = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "导入完成"))
        XCTAssertTrue(imported.firstMatch.waitForExistence(timeout: 12))
        press(app.buttons["完成"].firstMatch)
    }
    #endif

    private func press(_ element: XCUIElement) {
        #if targetEnvironment(macCatalyst)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func drag(_ source: XCUIElement, onto target: XCUIElement, destinationY: Double = 0.5) {
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: destinationY))
        #if targetEnvironment(macCatalyst)
        start.click(forDuration: 0.45, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        #else
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        #endif
    }
}
