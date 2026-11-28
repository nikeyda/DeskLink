import XCTest
#if !targetEnvironment(macCatalyst)
import dnssd
#endif

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
        app.buttons["library.presentation"].firstMatch.click()
        let list = app.menuItems["列表"].firstMatch
        if list.exists { list.click() } else { app.buttons["列表"].firstMatch.click() }
    }
    #else
    func testQuickConnectBrowsesNearbyAndPreservesManualDraftWhenGoingBack() throws {
        continueAfterFailure = false
        let token = UUID().uuidString.prefix(8).lowercased()
        let name = "Telescope quick " + token
        let discoveredHost = "telescope-\(token).local"
        let savedHost = discoveredHost + "."
        let port: UInt16 = 15282
        var addressRegistration: DNSServiceRef?
        var registration: DNSServiceRef?
        defer {
            if let registration { DNSServiceRefDeallocate(registration) }
            if let addressRegistration { DNSServiceRefDeallocate(addressRegistration) }
        }
        XCTAssertEqual(DNSServiceCreateConnection(&addressRegistration), DNSServiceErrorType(kDNSServiceErr_NoError))
        let addressService = try XCTUnwrap(addressRegistration)
        var addressRecord: DNSRecordRef?
        let loopback: [UInt8] = [127, 0, 0, 1]
        let addressStatus = loopback.withUnsafeBytes { data in
            DNSServiceRegisterRecord(addressService, &addressRecord, DNSServiceFlags(kDNSServiceFlagsUnique),
                                     kDNSServiceInterfaceIndexLocalOnly, savedHost, UInt16(kDNSServiceType_A),
                                     UInt16(kDNSServiceClass_IN), UInt16(data.count), data.baseAddress, 0,
                                     { _, _, _, _, _ in }, nil)
        }
        XCTAssertEqual(addressStatus, DNSServiceErrorType(kDNSServiceErr_NoError))
        var infoName = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        XCTAssertEqual(DNSServiceConstructFullName(&infoName, name, "_device-info._tcp", "local."), 0)
        var infoRecord: DNSRecordRef?
        let txt = NetService.data(fromTXTRecord: ["model": Data("Mac16,11".utf8)])
        let infoStatus = txt.withUnsafeBytes { bytes in
            DNSServiceRegisterRecord(addressService, &infoRecord, DNSServiceFlags(kDNSServiceFlagsUnique),
                                     kDNSServiceInterfaceIndexLocalOnly, infoName, UInt16(kDNSServiceType_TXT),
                                     UInt16(kDNSServiceClass_IN), UInt16(bytes.count), bytes.baseAddress, 0,
                                     { _, _, _, _, _ in }, nil)
        }
        XCTAssertEqual(infoStatus, DNSServiceErrorType(kDNSServiceErr_NoError))
        XCTAssertEqual(DNSServiceRegister(&registration, 0, kDNSServiceInterfaceIndexLocalOnly, name,
                                          "_rfb._tcp", "local.", savedHost, port.bigEndian, 0, nil, nil, nil),
                       DNSServiceErrorType(kDNSServiceErr_NoError))

        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let quick = app.buttons["library.quick"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        quick.tap()
        let host = app.textFields["connection.host"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        host.tap()
        host.typeText("draft.fixture.invalid")
        let choose = app.buttons["connection.chooseDevice"].firstMatch
        let hideKeyboard = app.keyboards.buttons["隐藏键盘"].firstMatch
        if hideKeyboard.isHittable {
            hideKeyboard.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 6))
        }
        choose.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompt = springboard.alerts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "local network", "本地网络")
        ).firstMatch
        if prompt.waitForExistence(timeout: 4) {
            prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch.tap()
        }
        let computer = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label CONTAINS %@",
            "connection.device.nearby.", name, "Mac mini")).firstMatch
        XCTAssertTrue(computer.waitForExistence(timeout: 12))
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if back.exists { back.tap() }
        else { app.navigationBars.buttons["快速连接"].firstMatch.tap() }
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(host.value as? String, "draft.fixture.invalid")
        choose.tap()
        let search = app.textFields["connection.deviceSearch"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText(String(port))
        XCTAssertTrue(computer.waitForExistence(timeout: 12))
        XCTAssertTrue(computer.label.contains(":\(port)"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iPad Nearby search by port"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        computer.tap()
        let portField = app.textFields["connection.port"].firstMatch
        XCTAssertTrue(portField.waitForExistence(timeout: 8))
        XCTAssertEqual(portField.value as? String, String(port))
        XCTAssertEqual(host.value as? String, discoveredHost)
        XCTAssertFalse(choose.exists)

        app.navigationBars.buttons["取消"].firstMatch.tap()
        let record: [String: Any] = [
            "version": 6, "id": UUID().uuidString, "type": ["saved": [:] as [String: String]],
            "name": "Saved Bonjour Mac", "hostname": savedHost, "port": port, "clientProtocol": "vnc",
            "users": [["username": "bonjour-fixture"]], "authenticationMethod": 1, "operatingSystem": 1,
            "startInObserveMode": false, "onDisconnectAction": 0,
            "useSharedClipboard": true, "useSecureConnection": false
        ]
        let archive = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".screens")
        defer { try? FileManager.default.removeItem(at: archive) }
        try JSONSerialization.data(withJSONObject: ["filename": "Bonjour fixture", "screens": [record], "folders": []])
            .write(to: archive)
        app.open(archive)
        let imported = app.alerts["导入完成"]
        XCTAssertTrue(imported.waitForExistence(timeout: 8))
        imported.buttons.firstMatch.tap()
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        quick.tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        choose.tap()
        XCTAssertTrue(computer.waitForExistence(timeout: 12))
        computer.tap()
        let username = app.textFields["connection.username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        XCTAssertEqual(username.value as? String, "bonjour-fixture")
        XCTAssertEqual(host.value as? String, savedHost)
        XCTAssertEqual(portField.value as? String, String(port))
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "iPad Bonjour discovery restores the saved profile"
        restored.lifetime = .keepAlways
        add(restored)

        app.navigationBars.buttons["取消"].firstMatch.tap()
        let numericID = UUID().uuidString
        var numericRecord = record
        numericRecord["id"] = numericID
        numericRecord["name"] = "Saved by IP"
        numericRecord["hostname"] = "127.0.0.1"
        numericRecord["users"] = [["username": "ip-fixture"]]
        try JSONSerialization.data(withJSONObject: ["filename": "Numeric fixture", "screens": [numericRecord], "folders": []])
            .write(to: archive)
        app.open(archive)
        XCTAssertTrue(imported.waitForExistence(timeout: 8))
        imported.buttons.firstMatch.tap()
        quick.tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 8))
        choose.tap()
        XCTAssertTrue(computer.waitForExistence(timeout: 12))
        computer.tap()
        let numeric = app.buttons["connection.profile." + numericID].firstMatch
        XCTAssertTrue(numeric.waitForExistence(timeout: 8))
        XCTAssertTrue(numeric.label.contains("127.0.0.1"))
        XCTAssertTrue(numeric.label.contains("ip-fixture"))
        XCTAssertFalse(username.exists)
        numeric.tap()
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        XCTAssertEqual(username.value as? String, "ip-fixture")
        XCTAssertEqual(host.value as? String, "127.0.0.1")
        XCTAssertEqual(portField.value as? String, String(port))

        app.navigationBars.buttons["取消"].firstMatch.tap()
        let sideEntry = app.descendants(matching: .any).matching(identifier: "library.nearby").firstMatch
        if !sideEntry.isHittable {
            let sidebar = app.buttons["ToggleSideBar"].firstMatch
            let back = app.buttons["BackButton"].firstMatch
            if sidebar.isHittable { sidebar.tap() }
            else if back.isHittable { back.tap() }
        }
        XCTAssertTrue(sideEntry.waitForExistence(timeout: 8))
        sideEntry.tap()
        let nearbyComputer = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label CONTAINS %@",
            "nearby.computer.", name, "Mac mini")).firstMatch
        let saveToLibrary = app.buttons["保存到连接库"].firstMatch
        XCTAssertTrue(nearbyComputer.waitForExistence(timeout: 12))
        let nearbyModels = XCTAttachment(screenshot: app.screenshot())
        nearbyModels.name = "Nearby Mac hardware families"
        nearbyModels.lifetime = .keepAlways
        add(nearbyModels)
        nearbyComputer.press(forDuration: 0.9)
        XCTAssertTrue(saveToLibrary.waitForExistence(timeout: 8))
        saveToLibrary.tap()
        XCTAssertTrue(numeric.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["connection.profile.manual"].firstMatch.label.contains("新建连接"))
        XCTAssertFalse(username.exists)
        numeric.tap()
        let nameField = app.textFields["connection.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        XCTAssertEqual(nameField.value as? String, "Saved by IP")
        XCTAssertEqual(host.value as? String, "127.0.0.1")
        XCTAssertEqual(username.value as? String, "ip-fixture")
        XCTAssertTrue(app.navigationBars["编辑连接"].firstMatch.exists)
        let editProfile = XCTAttachment(screenshot: app.screenshot())
        editProfile.name = "Edit saved IP profile from Nearby"
        editProfile.lifetime = .keepAlways
        add(editProfile)
    }

    func testNearbyContextMenuChoosesAConnectionModeWithoutChangingTheDefault() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let sideEntry = app.descendants(matching: .any).matching(identifier: "library.nearby").firstMatch
        if !sideEntry.isHittable {
            let sidebar = app.buttons["ToggleSideBar"].firstMatch
            let back = app.buttons["BackButton"].firstMatch
            if sidebar.isHittable { sidebar.tap() }
            else if back.isHittable { back.tap() }
        }
        XCTAssertTrue(sideEntry.waitForExistence(timeout: 8))
        sideEntry.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.containing(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "local network", "本地网络")
        ).firstMatch
        if permission.waitForExistence(timeout: 3) {
            let allow = permission.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允许"])).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }

        let name = "Telescope mode " + UUID().uuidString.prefix(8)
        let port: UInt16 = 15279
        var registration: DNSServiceRef?
        defer { if let registration { DNSServiceRefDeallocate(registration) } }
        XCTAssertEqual(DNSServiceRegister(&registration, 0, kDNSServiceInterfaceIndexLocalOnly, name,
                                          "_rfb._tcp", "local.", nil, port.bigEndian, 0, nil, nil, nil),
                       DNSServiceErrorType(kDNSServiceErr_NoError))
        let computer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                                                        "nearby.computer.", name)).firstMatch
        XCTAssertTrue(computer.waitForExistence(timeout: 12))

        func verifyConnectionMode(_ expected: String) {
            let portField = app.textFields["connection.port"]
            XCTAssertTrue(portField.waitForExistence(timeout: 8))
            XCTAssertEqual(portField.value as? String, String(port))
            let form = app.collectionViews["connection.form"].firstMatch
            let disclosure = form.buttons["显示器"].firstMatch
            for _ in 0..<4 where !disclosure.isHittable { form.swipeUp() }
            XCTAssertTrue(disclosure.isHittable)
            disclosure.tap()
            let quality = form.buttons["connection.quality"].firstMatch
            for _ in 0..<4 where !quality.isHittable { form.swipeUp() }
            XCTAssertTrue(quality.isHittable, form.debugDescription)
            XCTAssertTrue(quality.label.hasSuffix(expected), quality.debugDescription)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Nearby connection mode — \(expected)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        computer.press(forDuration: 0.9)
        let modes = app.buttons["连接模式"].firstMatch
        XCTAssertTrue(modes.waitForExistence(timeout: 8))
        modes.tap()
        let adaptive = app.buttons["以高性能模式连接"].firstMatch
        XCTAssertTrue(adaptive.waitForExistence(timeout: 5))
        adaptive.tap()
        verifyConnectionMode("高性能")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(computer.waitForExistence(timeout: 8))
        computer.tap()
        verifyConnectionMode("标准")
    }

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
