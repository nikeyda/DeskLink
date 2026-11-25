import XCTest

@MainActor
final class LibraryUITests: XCTestCase {
    #if targetEnvironment(simulator)
    func testOpenArchiveDocumentTwiceUsingTheSystemFileRoute() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))
        let data: Data
        if let encoded = ProcessInfo.processInfo.environment["DESKLINK_ARCHIVE_BASE64"] {
            data = try XCTUnwrap(Data(base64Encoded: encoded))
        } else {
            data = Data(#"{"version":1,"folders":["文稿往返"],"computers":[]}"#.utf8)
        }
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let computers = try XCTUnwrap(envelope["computers"] as? [[String: Any]])
        let folders = try XCTUnwrap(envelope["folders"] as? [String])
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".desklink")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        for expected in ["新增连接 \(computers.count) 个，新增文件夹 \(folders.count) 个，跳过重复连接 0 个。",
                         "新增连接 0 个，新增文件夹 0 个，跳过重复连接 \(computers.count) 个。"] {
            app.open(file)
            let alert = app.alerts["导入完成"]
            XCTAssertTrue(alert.waitForExistence(timeout: 12))
            XCTAssertTrue(alert.staticTexts[expected].exists)
            alert.buttons["完成"].tap()
        }
    }
    #endif

    func testManualDragAndNameSortSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        func add(_ name: String, host: String) {
            create.tap()
            app.textFields["connection.name"].tap()
            app.textFields["connection.name"].typeText(name)
            app.textFields["connection.host"].tap()
            app.textFields["connection.host"].typeText(host)
            app.buttons["connection.submit"].tap()
            XCTAssertTrue(app.buttons["connection.submit"].waitForNonExistence(timeout: 5))
        }
        func layout(_ action: String) {
            app.buttons["library.more"].tap()
            app.buttons[action].firstMatch.tap()
        }
        func order(_ name: String) {
            layout("排序")
            app.buttons[name].firstMatch.tap()
        }
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer."))
        add("Desktop 2", host: "two.fixture.invalid")
        add("Desktop 10", host: "ten.fixture.invalid")
        func tile(_ name: String) -> XCUIElement {
            tiles.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        }
        let two = tile("Desktop 2"), ten = tile("Desktop 10")
        XCTAssertTrue(two.waitForExistence(timeout: 5))
        XCTAssertTrue(ten.waitForExistence(timeout: 5))
        XCTAssertLessThan(two.frame.midX, ten.frame.midX)
        two.press(forDuration: 0.5, thenDragTo: ten, withVelocity: .slow, thenHoldForDuration: 0.4)
        func waitForOrder(_ check: @escaping () -> Bool) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 6), .completed)
        }
        waitForOrder { ten.frame.midX < two.frame.midX }
        order("名称")
        waitForOrder { two.frame.midX < ten.frame.midX }
        app.terminate()
        app.launch()
        XCTAssertTrue(ten.waitForExistence(timeout: 8))
        XCTAssertLessThan(two.frame.midX, ten.frame.midX)
        order("自定顺序")
        waitForOrder { ten.frame.midX < two.frame.midX }
        layout("列表")
        waitForOrder { ten.frame.midY < two.frame.midY }
        ten.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: two.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        waitForOrder { two.frame.midY < ten.frame.midY }
    }

    func testDuplicateCanBeCancelledThenSavedWithoutChangingTheSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        create.tap()
        let name = app.textFields["connection.name"]
        name.tap()
        name.typeText("Studio")
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText("127.0.0.1:5917")
        app.buttons["connection.submit"].tap()
        let items = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer."))
        let original = items.firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let originalID = original.identifier
        func duplicate() {
            app.buttons[originalID].press(forDuration: 0.8)
            app.buttons["复制连接"].firstMatch.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, "Studio 副本")
        }
        duplicate()
        app.buttons["取消"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertEqual(items.count, 1)
        duplicate()
        app.buttons["connection.submit"].tap()
        let copy = items.matching(NSPredicate(format: "label CONTAINS %@", "Studio 副本")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertNotEqual(copy.identifier, originalID)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons[originalID].waitForExistence(timeout: 10))
        XCTAssertTrue(copy.exists)
        XCTAssertEqual(items.count, 2)
    }

    func testCreateRelaunchAndDeleteSavedDesktop() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        create.tap()
        let name = app.textFields["connection.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("DeskLink QA")
        app.textFields["connection.host"].tap()
        app.textFields["connection.host"].typeText("127.0.0.1:5917")
        app.buttons["connection.submit"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                     "library.computer.", "DeskLink QA")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 6))
        app.terminate()
        app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 12))
        entry.press(forDuration: 1)
        app.buttons["删除"].firstMatch.tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
        app.buttons["library.more"].tap()
        app.buttons["设置"].firstMatch.tap()
        let backups = app.buttons["preferences.backups"]
        for _ in 0..<4 where !backups.isHittable { app.swipeUp() }
        XCTAssertTrue(backups.isHittable)
        backups.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                    "backup.", "1 个连接")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        app.alerts.buttons["取消"].tap()
        saved.tap()
        app.alerts.buttons["恢复备份"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "backup.restored").firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
    }

    func testTransferLibraryAndPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let transfers = app.buttons["library.transfers"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 12))
        transfers.tap()
        XCTAssertTrue(app.staticTexts["没有传输"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        func openPreferences() {
            app.buttons["library.more"].tap()
            app.buttons["设置"].firstMatch.tap()
        }
        openPreferences()
        let setting = app.switches["preferences.transfers"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(setting.value as? String)
        // The Form exposes the full labeled row as a switch on iPad. Its
        // thumb is at the trailing edge of the row.
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let didChange = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", original), object: setting)
        if XCTWaiter.wait(for: [didChange], timeout: 5) != .completed {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Transfer permission switch"
            shot.lifetime = .keepAlways
            add(shot)
            XCTFail("The transfer switch did not change after tapping its thumb")
            return
        }
        let changed = try XCTUnwrap(setting.value as? String)
        XCTAssertNotEqual(original, changed)
        app.terminate()
        app.launch()
        openPreferences()
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        XCTAssertEqual(setting.value as? String, changed)
    }
}
