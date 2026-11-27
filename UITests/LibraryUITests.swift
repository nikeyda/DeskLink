import XCTest
#if !targetEnvironment(macCatalyst)
import UIKit
#endif

@MainActor
final class LibraryUITests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
    func testNearbyBadgeCanBeHiddenIndependentlyOfDeviceDiscovery() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The Nearby count is an iPhone sidebar feature.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let row = app.descendants(matching: .any).matching(identifier: "library.nearby").firstMatch

        func waitFor(_ test: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now + .seconds(12)
            while !test() {
                if ContinuousClock.now >= deadline {
                    XCTFail("Nearby sidebar did not reach the expected state. Value: \(String(describing: row.value))", file: file, line: line)
                    return
                }
                try await Task.sleep(for: .milliseconds(120))
            }
        }

        func acceptDiscoveryPermission() {
            let prompt = springboard.alerts.containing(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "local network", "本地网络")
            ).firstMatch
            if prompt.waitForExistence(timeout: 3) {
                let allow = prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
                if allow.exists { allow.tap() }
            }
        }

        func showSidebar() {
            if row.isHittable { return }
            let button = app.buttons["ToggleSideBar"].firstMatch
            if button.isHittable {
                button.tap()
            } else {
                app.buttons["BackButton"].firstMatch.tap()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            XCTAssertTrue(row.isHittable)
        }

        func setCountVisible(_ visible: Bool) {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
            let sidebar = app.buttons["preferences.sidebar"].firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
            sidebar.tap()
            let toggle = app.switches["preferences.sidebar.nearbyCount"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let target = visible ? "1" : "0"
            if toggle.value as? String != target {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, target)
            let close = app.buttons["关闭"].firstMatch
            if !close.isHittable { app.navigationBars.buttons["设置"].firstMatch.tap() }
            close.tap()
        }

        func capture(_ name: String) {
            let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            picture.name = name
            picture.lifetime = .keepAlways
            add(picture)
        }

        func displayedCount() -> Int {
            guard let value = row.value else { return 0 }
            return Int(String(describing: value)) ?? 0
        }

        app.launch()
        acceptDiscoveryPermission()
        showSidebar()
        row.tap()
        XCTAssertTrue(app.navigationBars["附近"].waitForExistence(timeout: 8))
        let discovered = app.scrollViews.firstMatch.buttons.firstMatch
        try XCTSkipUnless(discovered.waitForExistence(timeout: 10), "Advertise a Bonjour screen-sharing service to run this UI integration test.")
        let device = app.buttons[discovered.label].firstMatch
        showSidebar()
        try await waitFor { displayedCount() > 0 }
        let advertised = displayedCount()
        capture("Nearby device badge")

        row.tap()
        setCountVisible(false)
        showSidebar()
        XCTAssertEqual(displayedCount(), 0)
        capture("Nearby badge hidden")
        row.tap()
        XCTAssertTrue(device.waitForExistence(timeout: 8))

        app.terminate()
        app.launch()
        showSidebar()
        XCTAssertEqual(displayedCount(), 0)
        row.tap()
        XCTAssertTrue(device.waitForExistence(timeout: 8))
        setCountVisible(true)
        showSidebar()
        try await waitFor { displayedCount() > 0 }
        let receipt = XCTAttachment(string: "Before hiding: \(advertised)\nHidden after relaunch: 0\nAfter restoring: \(displayedCount())")
        receipt.name = "Nearby count observations"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testSidebarVisibilitySurvivesRelaunchAndCanBeRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let favorites = app.descendants(matching: .any).matching(identifier: "library.favorites").firstMatch
        let all = app.descendants(matching: .any).matching(identifier: "library.all").firstMatch
        let emptyLibrary = app.buttons["library.empty.new"].firstMatch

        func changeFavoritesVisibility() throws {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
            let sidebar = app.buttons["preferences.sidebar"].firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 8))
            sidebar.tap()
            let toggle = app.switches["preferences.sidebar.favorites"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            let previousValue = try XCTUnwrap(toggle.value as? String)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", previousValue),
                                                    object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Sidebar preferences"
            attachment.lifetime = .keepAlways
            add(attachment)
            let close = app.buttons["关闭"].firstMatch
            if close.isHittable {
                close.tap()
            } else {
                app.navigationBars.buttons["设置"].firstMatch.tap()
                close.tap()
            }
        }

        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        favorites.tap()
        XCTAssertTrue(app.buttons["library.empty.all"].firstMatch.waitForExistence(timeout: 5))
        try changeFavoritesVisibility()
        XCTAssertTrue(emptyLibrary.waitForExistence(timeout: 5))
        XCTAssertFalse(favorites.exists)
        XCTAssertTrue(all.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        XCTAssertFalse(favorites.exists)
        try changeFavoritesVisibility()
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        XCTAssertTrue(app.buttons["library.empty.all"].firstMatch.waitForExistence(timeout: 5))
    }
    #endif

    func testEmptyLibraryOpensTheSaveAndQuickConnectionEditors() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let save = app.buttons["library.empty.new"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["添加第一台电脑"].firstMatch.exists)
        let emptyLibrary = XCTAttachment(screenshot: app.screenshot())
        emptyLibrary.name = "Empty connection library"
        emptyLibrary.lifetime = .keepAlways
        add(emptyLibrary)
        save.tap()
        XCTAssertTrue(app.textFields["connection.name"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        let quick = app.buttons["library.empty.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        quick.tap()
        XCTAssertTrue(app.textFields["connection.host"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["connection.name"].firstMatch.exists)
        XCTAssertFalse(app.buttons["connection.submit"].firstMatch.isEnabled)
        app.buttons["取消"].firstMatch.tap()
        let favorites = app.staticTexts["收藏"].firstMatch
        if !favorites.isHittable, app.buttons["显示边栏"].firstMatch.isHittable {
            app.buttons["显示边栏"].firstMatch.tap()
        }
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        XCTAssertTrue(app.staticTexts["还没有收藏的电脑"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["library.empty.all"].firstMatch.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
    }

    func testListShowsTheFolderBesideTheSavedComputer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let more = app.buttons["library.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))

        func press(_ element: XCUIElement) {
            #if targetEnvironment(macCatalyst)
            element.click()
            #else
            element.tap()
            #endif
        }
        func choose(_ title: String) {
            press(more)
            let action = app.buttons[title].firstMatch
            if action.exists { press(action) } else { press(app.menuItems[title].firstMatch) }
        }
        choose("新建文件夹")
        #if targetEnvironment(macCatalyst)
        let folderPrompt = app.sheets["新建文件夹"].firstMatch
        #else
        let folderPrompt = app.alerts["新建文件夹"].firstMatch
        #endif
        let name = folderPrompt.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        press(name)
        name.typeText("QA114-Desk")
        let folder = try XCTUnwrap(name.value as? String)
        XCTAssertFalse(folder.isEmpty)
        let saveFolder = folderPrompt.buttons["保存"].firstMatch
        XCTAssertTrue(saveFolder.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        press(saveFolder)
        XCTAssertTrue(folderPrompt.waitForNonExistence(timeout: 5))
        press(app.buttons["library.new"])
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        press(host)
        host.typeText("group-test.invalid")
        press(app.buttons["connection.submit"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        choose("列表")
        let folderHeading = app.staticTexts["library.list.folderHeading"].firstMatch
        XCTAssertFalse(folderHeading.exists)
        XCTAssertFalse(row.label.contains(folder))
        press(app.descendants(matching: .any).matching(identifier: "library.all").firstMatch)
        #if targetEnvironment(macCatalyst)
        XCTAssertTrue(folderHeading.waitForExistence(timeout: 5))
        XCTAssertEqual(folderHeading.label, "文件夹")
        XCTAssertTrue(row.buttons["group-test.invalid"].firstMatch.exists)
        let grouped = row.buttons[folder].firstMatch
        XCTAssertTrue(grouped.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(abs(grouped.frame.minX - folderHeading.frame.minX), 2)
        let window = app.windows.containing(.button, identifier: "library.more").firstMatch
        let capture = XCTAttachment(screenshot: window.screenshot())
        #else
        let grouped = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "library.computer.", "group-test.invalid", folder)).firstMatch
        XCTAssertTrue(grouped.waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        XCTAssertFalse(folderHeading.exists)
        #endif
        capture.name = "Grouped connection list"
        capture.lifetime = .keepAlways
        add(capture)
    }

    #if targetEnvironment(simulator)
    func testOpeningScreensDirectoryArchiveReportsPreservedFolders() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))
        let data = Data(#"{"filename":"Fixture","screens":[],"folders":[],"tsFolders":[{"id":"EA5E2C8A-84E5-46F4-BF4C-331B2900677A","name":"Test","items":[],"rawItems":["fixture-node"],"contentType":16}]}"#.utf8)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        app.open(file)
        let alert = app.alerts["导入完成"]
        XCTAssertTrue(alert.waitForExistence(timeout: 12))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "另保留 1 个目录分组，可随归档导出。")).firstMatch.exists)
        XCTAssertFalse(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已迁移连接地址")).firstMatch.exists)
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = "Imported Screens directory groups"
        picture.lifetime = .keepAlways
        add(picture)
    }

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

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func testImportScreensArchiveUsingSystemPicker() throws {
        guard let raw = ProcessInfo.processInfo.environment["DESKLINK_SCREENS_DOCUMENT"],
              let id = UUID(uuidString: raw) else { throw XCTSkip("Requires the known synthetic .screens file on the iPad.") }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let more = app.buttons["library.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["导入"].tap()
        func named(_ labels: [String]) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
        }
        let grid = app.collectionViews["File View"].cells
        let document = grid.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", raw, raw)).firstMatch
        func choose(_ element: XCUIElement, _ name: String) throws {
            guard element.waitForExistence(timeout: 8), element.isHittable else {
                #if targetEnvironment(simulator)
                let snapshot = XCTAttachment(screenshot: app.screenshot())
                snapshot.name = "Archive picker at " + name
                snapshot.lifetime = .keepAlways
                add(snapshot)
                #endif
                throw NSError(domain: "TelescopeArchiveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Picker did not show " + name])
            }
            let icon = element.images.firstMatch
            if icon.exists { icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            else { element.tap() }
        }
        if !document.waitForExistence(timeout: 2) {
            let names = ["On My iPad", "在我的 iPad 上", "我的iPad", "我的 iPad"]
            let location = app.cells.containing(NSPredicate(format: "label IN %@", names)).firstMatch
            let sidebar = app.buttons["ToggleSideBar"]
            if !location.isHittable, sidebar.isHittable { sidebar.tap() }
            try choose(location.isHittable ? location : named(names), "On My iPad")
            let buttons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Search", "搜索"]))
            if let searchButton = buttons.allElementsBoundByIndex.last(where: { $0.isHittable }) {
                searchButton.tap()
                // Files owns the focused field in a separate process. The app's
                // search field behind the sheet remains visible to XCTest.
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                app.typeText(raw + "\n")
                let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", raw)).firstMatch
                if suggestion.waitForExistence(timeout: 2), suggestion.isHittable { suggestion.tap() }
            } else {
                let container = grid.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", "远程随航,", "Telescope,")).firstMatch
                try choose(container, "Telescope")
                let downloads = grid.matching(NSPredicate(format: "label BEGINSWITH[c] %@ OR label BEGINSWITH %@", "Downloads", "下载")).firstMatch
                try choose(downloads, "Downloads")
            }
        }
        try choose(document, raw)
        let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
        if confirm.isHittable { confirm.tap() }
        let result = app.alerts["导入完成"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "SSH")).firstMatch.exists)
        result.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["library.computer." + id.uuidString].waitForExistence(timeout: 8))
    }

    func testOpenReceivedArchiveFromSystemFiles() throws {
        guard let raw = ProcessInfo.processInfo.environment["DESKLINK_FILES_FIXTURE"], let id = UUID(uuidString: raw) else {
            throw XCTSkip("Run after receiving the matching archive on this iPad.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].waitForExistence(timeout: 10))
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        func named(_ labels: [String]) -> XCUIElement {
            files.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
        }
        let cells = files.collectionViews["File View"].cells
        func folder(_ labels: [String]) -> XCUIElement {
            cells.containing(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        func openItem(_ entry: XCUIElement, named label: String) throws {
            guard entry.waitForExistence(timeout: 10) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Files did not list " + label])
            }
            let icon = entry.images.firstMatch
            if icon.exists { icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            else { entry.tap() }
        }
        let start = named(["Continue", "继续"])
        if start.waitForExistence(timeout: 2), start.isHittable { start.tap() }
        let appNames = ["远程随航", "Telescope"]
        let local = ["On My iPad", "在我的 iPad 上", "我的iPad", "我的 iPad"]
        let appFolder = folder(appNames)
        let downloads = folder(["Downloads", "下载项", "下载"])
        let base = "DeskLink-" + id.uuidString
        let document = cells.matching(NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", id.uuidString, id.uuidString)).firstMatch
        if !document.exists {
            if !appFolder.exists {
                let browse = named(["Browse", "浏览"])
                if browse.exists, browse.isHittable { browse.tap() }
                let location = files.cells.containing(NSPredicate(format: "label IN %@", local)).firstMatch
                let sidebar = files.buttons["ToggleSideBar"]
                if !location.isHittable, sidebar.isHittable { sidebar.tap() }
                let localEntry = location.isHittable ? location : named(local)
                XCTAssertTrue(localEntry.waitForExistence(timeout: 6))
                localEntry.tap()
            }
            // Another provider can also have a Downloads folder. Enter ours from On My iPad.
            try openItem(appFolder, named: appNames[0])
            try openItem(downloads, named: "Downloads")
        }
        try openItem(document, named: base)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let result = app.alerts["导入完成"]
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["library.computer." + id.uuidString].waitForExistence(timeout: 8))
    }

    #endif

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
