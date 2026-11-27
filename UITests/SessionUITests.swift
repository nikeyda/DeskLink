import UIKit
import XCTest

@MainActor
final class SessionUITests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
    func testSavedDesktopRestoresObservationAfterRelaunchWithoutSendingInput() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString, "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["library.new"].firstMatch.waitForExistence(timeout: 10))

        let id = UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appending(path: id + ".screens")
        defer { try? FileManager.default.removeItem(at: file) }
        let fixture = """
            {"filename":"Observe mode fixture","folders":[],"screens":[{
            "version":6,"id":"\(id)","type":{"saved":{}},"name":"Observe Mode Fixture",
            "hostname":"127.0.0.1","port":\(port),"clientProtocol":"vnc",
            "users":[],"authenticationMethod":3,"operatingSystem":6,"startInObserveMode":false,
            "onDisconnectAction":0,"useSharedClipboard":false,"useSecureConnection":false}]}
            """
        try Data(fixture.utf8).write(to: file)
        app.open(file)
        let imported = app.alerts["导入完成"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        imported.buttons["完成"].tap()

        let row = app.buttons["library.computer." + id].firstMatch
        let mode = app.buttons["session.mode"].firstMatch
        let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        let desktopCenter = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func connect(_ expected: String) async throws {
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            let frames = desktop.frameCount
            row.tap()
            try await waitUntil { desktop.frameCount > frames }
            try await waitUntil { mode.exists && mode.label == expected }
        }
        func disconnect() async throws {
            let closed = desktop.closedConnections
            desktop.expectsClientDisconnect = true
            app.buttons["session.close"].firstMatch.tap()
            try await waitUntil { desktop.closedConnections > closed && row.isHittable }
            desktop.expectsClientDisconnect = false
        }

        try await connect("控制")
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        try await disconnect()
        app.terminate()
        app.launch()

        app.buttons["library.quick"].firstMatch.tap()
        applyLink("screens://Observe%20Mode%20Fixture?observe=false", in: app)
        let framesBeforeLink = desktop.frameCount
        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        submit.tap()
        try await waitUntil { desktop.frameCount > framesBeforeLink && mode.label == "控制" }
        try await disconnect()

        try await connect("仅观察")
        XCTAssertFalse(input.exists)
        let clicks = desktop.clicks
        desktopCenter.tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(desktop.clicks, clicks)
        attachToolbarScreenshot(app, name: "Saved connection reopened in Observe mode")
        mode.tap()
        try await waitUntil { mode.label == "控制" && input.exists }
        desktopCenter.tap()
        try await waitUntil { desktop.clicks > clicks }
        try await disconnect()
        app.terminate()
        app.launch()

        try await connect("控制")
        XCTAssertEqual(desktop.acceptedConnections, 4)
        try await disconnect()
    }

    func testRememberedComputerConnectsFromItsTileAndWidgetURL() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        let name = "Desk " + String(UUID().uuidString.prefix(8))
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let new = app.buttons["library.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        let remember = app.switches["connection.remember"]
        let thumb = remember.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        thumb.tap()
        guard remember.value as? String == "1" else {
            XCTFail("The new connection form did not enable password storage.")
            return
        }
        let host = app.textFields["connection.host"]
        let computerName = app.textFields["connection.name"]
        computerName.tap()
        computerName.typeText(name)
        host.tap()
        host.typeText("127.0.0.1:\(port)")
        let username = app.textFields["connection.username"]
        username.tap()
        username.typeText("fixture-" + UUID().uuidString.lowercased())
        let secret = app.secureTextFields["connection.password"]
        secret.tap()
        secret.typeText("one-tap-fixture")
        XCTAssertEqual(remember.value as? String, "1")
        let save = app.buttons["connection.submit"]
        save.tap()
        let dismissPasswordManager = app.alerts["保存密码？"].buttons["以后"]
        if dismissPasswordManager.waitForExistence(timeout: 3) { dismissPasswordManager.tap() }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                  "library.computer.", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let id = try XCTUnwrap(row.identifier.split(separator: ".").last.flatMap { UUID(uuidString: String($0)) })
        let route = try XCTUnwrap(URL(string: "desklink:///connect/" + id.uuidString))
        func openWidgetURL() {
            XCUIDevice.shared.system.open(route)
            let confirm = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["打开"]
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        for fromWidget in [false, true] {
            let before = desktop.frameCount, closedBefore = desktop.closedConnections
            if fromWidget { openWidgetURL() } else { row.tap() }
            // The test peer handles its handshake on the runner's main actor. Give it time
            // to send the frame before XCTest synchronously asks the viewer for its UI.
            do { try await waitUntil(timeout: 30) { desktop.frameCount > before } }
            catch {
                XCTFail("No frame from \(fromWidget ? "widget URL" : "library tile"). Accepted \(desktop.acceptedConnections), closed \(desktop.closedConnections), overlapping \(desktop.overlappingConnections), server error \(desktop.failure ?? "none").")
                return
            }
            try await waitUntil(timeout: 30) {
                if dismissPasswordManager.exists && dismissPasswordManager.isHittable {
                    dismissPasswordManager.tap()
                    return false
                }
                return app.buttons["session.mode"].exists && Self.hasColorChart(app.screenshot().image)
            }
            app.typeKey("c", modifierFlags: [.shift, .control, .command])
            try await waitUntil { !app.buttons["session.mode"].exists && row.isHittable }
            do { try await waitUntil { desktop.closedConnections > closedBefore } }
            catch {
                XCTFail("The viewer returned to the library without closing its connection to the test display.")
                return
            }
        }
        // Forget only this test account, then check that credentials are requested again.
        row.press(forDuration: 0.8)
        app.buttons["编辑连接"].firstMatch.tap()
        XCTAssertEqual(remember.value as? String, "1")
        remember.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        save.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let frameCount = desktop.frameCount
        openWidgetURL()
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        XCTAssertEqual(remember.value as? String, "0")
        XCTAssertEqual(desktop.frameCount, frameCount)
    }

    private func reveal(_ element: XCUIElement, in form: XCUIElement) -> Bool {
        for _ in 0..<9 {
            if element.exists && element.isHittable
                && form.frame.insetBy(dx: 0, dy: 15).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                return true
            }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.76))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.32))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return false
    }

    func testPinchRespectsTheConnectionSettingAndKeepsPointerCoordinatesAligned() async throws {
        for allowsZoom in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
            app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
            let form = app.collectionViews["connection.form"].firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 8))
            let display = app.buttons["显示器"].firstMatch
            XCTAssertTrue(reveal(display, in: form))
            display.tap()
            let setting = app.switches["connection.viewportZoom"].firstMatch
            XCTAssertTrue(reveal(setting, in: form))
            XCTAssertEqual(setting.value as? String, "1")
            if !allowsZoom {
                setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                XCTAssertEqual(setting.value as? String, "0")
            }
            app.buttons["connection.submit"].tap()
            let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
            try await waitUntil { desktop.frameCount > 0 && surface.isHittable && Self.hasColorChart(app.screenshot().image) }
            let point = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            func clickedX() async throws -> Int {
                let earlier = desktop.primaryPresses.count
                point.tap()
                try await waitUntil { desktop.primaryPresses.count > earlier }
                return desktop.primaryPresses[earlier]
            }
            let before = try await clickedX()
            let coverageBefore = Self.chartFractions(XCUIScreen.main.screenshot().image).reduce(0, +)
            surface.pinch(withScale: 2.5, velocity: 1.5)
            let after = try await clickedX()
            let rendered = XCUIScreen.main.screenshot()
            let coverageAfter = Self.chartFractions(rendered.image).reduce(0, +)
            XCTAssertGreaterThan(coverageBefore, 0.2)
            XCTContext.runActivity(named: "Pinch enabled = \(allowsZoom), remote x = \(before) then \(after)") { activity in
                let screenshot = XCTAttachment(screenshot: rendered)
                screenshot.name = allowsZoom ? "Magnified desktop" : "Fitted desktop"
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
            }
            if allowsZoom {
                XCTAssertGreaterThan(coverageAfter - coverageBefore, 0.04)
                XCTAssertGreaterThan(after - before, 8, "Pinching should bring the sampled point nearer the center of the 160-pixel desktop.")
            } else {
                XCTAssertEqual(coverageAfter, coverageBefore, accuracy: 0.025)
                XCTAssertEqual(Double(after), Double(before), accuracy: 1)
            }
            app.terminate()
        }
    }

    func testHardwareControlReachesTheServerAsCommandWhenEnabledInTheEditor() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let form = app.collectionViews["connection.form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 8))
        let display = app.buttons["显示器"].firstMatch
        guard reveal(display, in: form) else { XCTFail("Display options are not visible in the connection form."); return }
        display.tap()
        let swap = app.switches["connection.swapCommandControl"].firstMatch
        guard reveal(swap, in: form) else { XCTFail("The keyboard switch is not visible in the connection form."); return }
        XCTAssertEqual(swap.value as? String, "0")
        swap.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(swap.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Hardware keyboard settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["connection.submit"].tap()
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.info"].exists }
        app.descendants(matching: .any).matching(identifier: "session.input").firstMatch.tap()
        app.typeKey("x", modifierFlags: .control)
        try await waitUntil { desktop.keyDowns.contains(0x78) }
        XCTAssertEqual(Array(desktop.keyDowns.suffix(2)), [0xFFEB, 0x78])
        XCTAssertFalse(desktop.keyDowns.contains(0xFFE3))
    }

    func testIPadSessionKeyboardShortcutsActOnTheViewerAndRemoteDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.info"].exists }
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.tap()
        let chord: XCUIElement.KeyModifierFlags = [.shift, .control, .command]
        app.typeKey("w", modifierFlags: chord)
        // This peer uses PC conventions. Close Window expands to Alt-F4.
        try await waitUntil { desktop.keyDowns.contains(0xFFC1) }
        XCTAssertTrue(desktop.keyDowns.contains(0xFFE9))
        XCTAssertFalse(desktop.keyDowns.contains(0x77))

        app.typeKey("r", modifierFlags: chord)
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        guard cancel.waitForExistence(timeout: 30) else {
            XCTFail("The screenshot shortcut did not open the system export sheet.")
            return
        }
        cancel.tap()
        XCTAssertFalse(desktop.keyDowns.contains(0x72))
        app.typeKey("c", modifierFlags: chord)
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        XCTAssertFalse(desktop.keyDowns.contains(0x63))
    }

    func testQuickConnectionCanBeFiledAsALinkWithoutSavingACustomComputer() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.close"].exists }
        app.buttons["session.close"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        let quick = app.buttons["library.quick"]
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        XCTAssertFalse(entry.exists)
        func selectPage(_ identifier: String) {
            let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            if !row.isHittable {
                let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["显示边栏", "显示侧边栏", "Show Sidebar"])).firstMatch
                if sidebar.isHittable { sidebar.tap() }
            }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
        }
        selectPage("library.links")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        app.buttons["library.more"].tap()
        app.buttons["新建文件夹"].tap()
        let alert = app.alerts["新建文件夹"]
        let folder = "临时桌面"
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText(folder)
        alert.buttons["保存"].tap()
        XCTAssertTrue(entry.waitForNonExistence(timeout: 5))
        selectPage("library.links")
        entry.press(forDuration: 0.8)
        app.buttons["移到链接文件夹"].tap()
        app.buttons[folder].firstMatch.tap()
        app.terminate()
        app.launch()
        selectPage("library.linkFolder." + folder)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("127.0.0.1"))
    }

    func testAutomaticReconnectReportIdentifiesTheInterruptedTransport() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let info = app.buttons["session.info"]
        try await waitUntil { info.exists && desktop.frameCount > 0 }
        let initialFrames = desktop.frameCount
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.frameCount > initialFrames && info.isEnabled }
        info.tap()
        let trigger = app.descendants(matching: .any)["details.reconnect"].firstMatch
        try await waitUntil { trigger.value as? String == "传输连接中断" }
    }

    func testFirstPictureStatusWaitsForNewFramesAfterReconnect() async throws {
        let desktop = LocalTestDisplay()
        desktop.withholdFramesAfterConnection = 0
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let waiting = app.descendants(matching: .any)["session.waitingForScreen"].firstMatch
        let statusAction = app.buttons["session.statusAction"]
        try await waitUntil { waiting.exists && statusAction.exists }
        XCTAssertEqual(desktop.frameCount, 0)
        XCTAssertEqual(statusAction.label, "取消")
        attachToolbarScreenshot(app, name: "Waiting for the first remote picture")
        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { !waiting.exists && desktop.frameCount > 0 }

        let mode = app.buttons["session.mode"]
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        desktop.withholdFramesAfterConnection = 1
        let frames = desktop.frameCount
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.acceptedConnections == 2 && waiting.exists }
        XCTAssertEqual(desktop.frameCount, frames)
        XCTAssertEqual(statusAction.label, "停止重新连接")
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))
        attachToolbarScreenshot(app, name: "Reconnecting while the old picture is still visible")
        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { !waiting.exists && desktop.frameCount > frames }
        XCTAssertEqual(mode.label, "仅观察")

        desktop.withholdFramesAfterConnection = 2
        desktop.dropCurrentConnection()
        try await waitUntil { desktop.acceptedConnections == 3 && waiting.exists }
        statusAction.tap()
        XCTAssertTrue(app.buttons["session.reconnect"].waitForExistence(timeout: 8))
        XCTAssertFalse(waiting.exists)
        XCTAssertEqual(desktop.acceptedConnections, 3)
    }

    func testCancellingBeforeTheFirstPictureReturnsToTheLibrary() async throws {
        let desktop = LocalTestDisplay()
        desktop.expectsClientDisconnect = true
        desktop.withholdFramesAfterConnection = 0
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let waiting = app.descendants(matching: .any)["session.waitingForScreen"].firstMatch
        let cancel = app.buttons["session.statusAction"]
        try await waitUntil { waiting.exists && cancel.isHittable }
        cancel.tap()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        XCTAssertFalse(waiting.exists)
        XCTAssertFalse(app.buttons["session.reconnect"].exists)
        desktop.withholdFramesAfterConnection = nil
        try await waitUntil { desktop.closedConnections == 1 }
        XCTAssertEqual(desktop.acceptedConnections, 1)
    }

    func testManualReconnectAfterPeerClosesUsesTheSameOpenSession() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) {
            app.buttons["library.more"].tap()
            app.buttons["设置"].tap()
            let automatic = app.switches["自动重新连接"]
            XCTAssertEqual(automatic.value as? String, "1")
            automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            XCTAssertEqual(automatic.value as? String, "0")
            app.buttons["关闭"].tap()
        }
        let info = app.buttons["session.info"]
        try await waitUntil { info.exists && desktop.frameCount > 0 }
        desktop.dropCurrentConnection()
        let retry = app.buttons["session.reconnect"]
        XCTAssertTrue(retry.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["session.editConnection"].exists)
        let frames = desktop.frameCount
        retry.tap()
        try await waitUntil { info.exists && desktop.frameCount > frames && !retry.exists }
        XCTAssertFalse(app.textFields["connection.host"].exists)
        app.buttons["toolbar.tab"].tap()
        try await waitUntil { desktop.keyDowns.contains(0xFF09) }
        info.tap()
        try await waitUntil { app.descendants(matching: .any)["details.reconnect"].firstMatch.value as? String == "手动重试" }
    }
    #endif

    func testSharedClipboardDefaultAndManualReceiveUseOnlyTheCurrentSession() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.clipboard"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        func select(_ label: String) {
            menu.tap()
            app.buttons[label].firstMatch.tap()
        }
        func checkLocalClipboard(_ value: String) async throws {
            let previous = desktop.clipboardWrites
            select("发送剪贴板")
            try await waitUntil { desktop.clipboardWrites > previous && desktop.receivedClipboard == Data(value.utf8) }
        }
        try await desktop.publishClipboard("First remote copy")
        try await checkLocalClipboard("First remote copy")
        select("自动共享剪贴板")
        try await desktop.publishClipboard("Second remote copy")
        try await checkLocalClipboard("First remote copy")
        select("接收剪贴板")
        try await checkLocalClipboard("Second remote copy")
        app.buttons["session.mode"].tap()
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        app.buttons["session.mode"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        try await desktop.publishClipboard("Third remote copy")
        try await checkLocalClipboard("Second remote copy")
    }

    #if !targetEnvironment(macCatalyst)
    func testPinyinCandidateSendsOnlyCommittedCharactersToTheRemoteDesktop() async throws {
        guard ProcessInfo.processInfo.environment["DESKLINK_TEST_PINYIN"] == "1" else {
            throw XCTSkip("Requires an active Simplified Chinese Pinyin onscreen keyboard.")
        }
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let submit = app.buttons["connection.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        submit.tap()
        let toggle = app.buttons["toolbar.keyboard"]
        try await waitUntil { desktop.frameCount > 0 && toggle.isHittable }
        try await selectPinyinGreeting(in: app) {
            XCTAssertEqual(desktop.keyDowns, [], "Uncommitted Pinyin reached the peer.")
        }
        let expected: [UInt32] = [0x0100_4F60, 0x0100_597D]
        try await waitUntil { desktop.keyDowns.count >= expected.count }
        XCTAssertEqual(desktop.keyDowns, expected)
        XCTAssertNil(desktop.failure)
        XCTContext.runActivity(named: "Selected 你好 after five system key taps, peer received only U+4F60 U+597D") { _ in }
        try await submitPinyinLine(in: app)
        try await waitUntil { desktop.keyDowns.count > expected.count }
        XCTAssertEqual(desktop.keyDowns, expected + [0xff0d])
    }

    func testRaspberryPiAuthenticationPickerHostFingerprintAndLiveEncryptionReport() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["DESKLINK_RSA_UI_TERMINAL"], let pin = env["DESKLINK_RSA_PIN"],
              var target = URLComponents(string: address) else { throw XCTSkip("Requires the paired RSA-AES desktop.") }
        target.user = "chartuser"
        target.password = "FixtureAccount71!"
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(target.url))
        let picker = app.buttons["connection.authentication"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        app.buttons["Raspberry Pi · RSA-AES"].firstMatch.tap()
        app.buttons["connection.submit"].tap()
        let identity = app.alerts.firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let fingerprint = identity.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", pin)).firstMatch
        guard fingerprint.exists else { return XCTFail("The approval dialog omitted the fixture host fingerprint") }
        let prompt = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        prompt.name = "RSA host fingerprint on iPad"
        prompt.lifetime = .keepAlways
        add(prompt)
        identity.buttons["记住主机指纹"].tap()
        let info = app.buttons["session.info"]
        try await waitUntil(timeout: 20) { info.exists && info.isEnabled }
        info.tap()
        let encryption = app.descendants(matching: .any).matching(identifier: "details.encryption").firstMatch
        try await waitUntil { encryption.value as? String == "RSA-AES-256" }
        let report = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        report.name = "Authenticated RSA-AES desktop and connection details"
        report.lifetime = .keepAlways
        add(report)
        app.buttons["details.done"].tap()
        app.buttons["session.close"].tap()
        try await waitUntil { app.buttons["library.quick"].exists }
    }

    func testSelectedPinyinCandidateArrivesInTheLinuxTerminal() async throws {
        guard let address = ProcessInfo.processInfo.environment["DESKLINK_TEST_PINYIN_TERMINAL"],
              var target = URLComponents(string: address) else { throw XCTSkip("Requires the isolated X11 Pinyin terminal.") }
        target.user = "fixture"
        target.password = "Chart42!"
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(target.url))
        let submit = app.buttons["connection.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 8))
        let form = app.collectionViews["connection.form"].firstMatch
        let display = app.buttons["显示器"].firstMatch
        guard reveal(display, in: form) else { return XCTFail("Could not reveal the display settings.") }
        display.tap()
        let compatibility = app.switches["connection.tigerKeyboard"].firstMatch
        guard reveal(compatibility, in: form) else { return XCTFail("Could not reveal the TigerVNC keyboard setting.") }
        XCTAssertEqual(compatibility.value as? String, "0")
        compatibility.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(compatibility.value as? String, "1")
        let setting = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        setting.name = "TigerVNC first key compatibility enabled"
        setting.lifetime = .keepAlways
        add(setting)
        submit.tap()
        try await waitUntil { app.buttons["toolbar.keyboard"].isHittable &&
            Self.chartFractions(XCUIScreen.main.screenshot().image).first.map { $0 > 0.10 } == true }
        try await selectPinyinGreeting(in: app)
        try await submitPinyinLine(in: app)
        // The terminal turns the X11 root green only on receiving the exact UTF-8 line.
        try await waitUntil {
            let colors = Self.chartFractions(XCUIScreen.main.screenshot().image)
            return colors.count == 4 && colors[2] > 0.04
        }
    }

    private func submitPinyinLine(in app: XCUIApplication) async throws {
        let enter = app.keyboards.firstMatch.descendants(matching: .any).matching(identifier: "Return").firstMatch
        try await waitUntil { enter.isHittable }
        enter.tap()
    }

    private func selectPinyinGreeting(in app: XCUIApplication, opensKeyboard: Bool = true,
                                      whileComposing: () -> Void = {}) async throws {
        if opensKeyboard { app.buttons["toolbar.keyboard"].tap() }
        let keyboard = app.keyboards.firstMatch
        try await waitUntil { keyboard.exists && keyboard.frame.height > 0 }
        for character in "nihao" {
            let key = keyboard.keys.matching(NSPredicate(format: "label ==[c] %@", String(character))).firstMatch
            try await waitUntil { key.exists && key.isHittable &&
                app.frame.contains(CGPoint(x: key.frame.midX, y: key.frame.midY)) }
            key.tap()
            whileComposing()
        }
        let candidate = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR identifier == %@", "你好", "你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 6), "The system IME did not expose the expected candidate.")
        XCTAssertTrue(candidate.isHittable)
        whileComposing()
        candidate.tap()
    }

    func testUpwardSwipeOnKeyboardShortcutStripReachesRemoteBottomEdge() async throws {
        try await verifyKeyboardToolbarEdgeSwipe(floating: false)
    }

    func testUpwardSwipeOnFloatingKeyboardShortcutStripReachesRemoteBottomEdge() async throws {
        try await verifyKeyboardToolbarEdgeSwipe(floating: true)
    }

    private func verifyKeyboardToolbarEdgeSwipe(floating: Bool) async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        if floating { selectToolbar("浮动", in: app) }
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let host = app.textFields["connection.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8))
        host.tap()
        let softwareKeyboard = app.keyboards.firstMatch
        XCTAssertTrue(softwareKeyboard.waitForExistence(timeout: 8))
        let letter = softwareKeyboard.keys.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", "a", "a")).firstMatch
        let controlKey = letter.exists ? letter.frame : .zero
        XCTContext.runActivity(named: "Address field keyboard \(softwareKeyboard.frame), A \(controlKey)") { _ in }
        app.buttons["connection.submit"].tap()
        let monitors = app.buttons["session.monitors"]
        try await waitUntil { desktop.frameCount > 0 && monitors.isHittable }
        monitors.tap()
        app.buttons["显示器 2"].firstMatch.tap()
        let keyboard = app.buttons["toolbar.keyboard"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6))
        keyboard.tap()
        XCTAssertTrue(softwareKeyboard.waitForExistence(timeout: 8))
        let tab = app.buttons["toolbar.tab"]
        func recordKeyboard(_ stage: String) {
            let keyFrame = letter.exists ? letter.frame : .zero
            XCTContext.runActivity(named: "\(stage) window \(app.frame), keyboard \(softwareKeyboard.frame), A \(keyFrame), Tab \(tab.frame)") { activity in
                let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                image.name = stage
                image.lifetime = .keepAlways
                activity.add(image)
            }
        }
        func hasVisibleKeyboard() -> Bool {
            guard letter.exists, letter.isHittable, app.frame.contains(CGPoint(x: letter.frame.midX, y: letter.frame.midY)),
                  tab.isHittable else { return false }
            return tab.frame.maxY <= letter.frame.minY
        }
        do { try await waitUntil { hasVisibleKeyboard() } }
        catch { recordKeyboard("Before swipe"); throw error }
        let start = tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.03, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -110)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        try await waitUntil { desktop.latestPointer.map { (80...159).contains($0.x) && $0.y == 95 } == true }
        let point = try XCTUnwrap(desktop.latestPointer)
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.keys, 0)
        recordKeyboard("After swipe")
        XCTAssertTrue(hasVisibleKeyboard())
        XCTContext.runActivity(named: "Keyboard strip moved remote pointer to \(Int(point.x)),\(Int(point.y))") { _ in }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xff09] }
        let backspace = softwareKeyboard.keys.matching(NSPredicate(
            format: "identifier IN %@ OR label IN %@",
            ["delete", "Delete", "Backspace", "删除", "退格"], ["delete", "Delete", "Backspace", "删除", "退格"])).firstMatch
        XCTAssertTrue(backspace.exists && backspace.isHittable)
        backspace.tap()
        try await waitUntil { desktop.keyDowns == [0xff09, 0xff08] }
    }

    func testInwardEdgeAndCornerSwipesMoveToTheSelectedDisplayWithoutClicking() async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.monitors"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        menu.tap()
        app.buttons["显示器 2"].firstMatch.tap()
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 6))
        let frame = surface.frame
        let origin = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: frame.minX - app.frame.minX, dy: frame.minY - app.frame.minY))
        let width = frame.width, height = frame.height
        func stroke(_ start: CGPoint, dx: CGFloat, dy: CGFloat) {
            let point = origin.withOffset(CGVector(dx: start.x, dy: start.y))
            point.press(forDuration: 0.03, thenDragTo: point.withOffset(CGVector(dx: dx, dy: dy)),
                        withVelocity: .fast, thenHoldForDuration: 0)
        }
        let left: CGFloat = 16, right = width - 16, top: CGFloat = 16, bottom = height - 16
        // The second display spans x = 80...159 and y = 0...95 in the combined framebuffer.
        let cases: [(CGPoint, CGFloat, CGFloat, ClosedRange<CGFloat>, ClosedRange<CGFloat>)] = [
            (CGPoint(x: right, y: height / 2), -96, 0, 159...159, 20...76),
            (CGPoint(x: left, y: height / 2), 96, 0, 80...80, 20...76),
            (CGPoint(x: width / 2, y: top), 0, 96, 100...140, 0...0),
            (CGPoint(x: width / 2, y: bottom), 0, -96, 100...140, 95...95),
            (CGPoint(x: left, y: bottom), 96, -96, 80...80, 95...95),
            (CGPoint(x: right, y: bottom), -96, -96, 159...159, 95...95),
            (CGPoint(x: left, y: top), 96, 96, 80...80, 0...0),
            (CGPoint(x: right, y: top), -96, 96, 159...159, 0...0)
        ]
        for (start, dx, dy, x, y) in cases {
            stroke(start, dx: dx, dy: dy)
            do {
                try await waitUntil { desktop.latestPointer.map { x.contains($0.x) && y.contains($0.y) } == true }
            } catch {
                XCTFail("Inward swipe from \(start) expected x \(x), y \(y); received \(String(describing: desktop.latestPointer)).")
                return
            }
            let point = try XCTUnwrap(desktop.latestPointer)
            XCTContext.runActivity(named: "Remote edge position \(Int(point.x)),\(Int(point.y))") { _ in }
        }
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.scrollTicks, 0)
        let mode = app.buttons["session.mode"]
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        try await waitUntil { !surface.exists }
        let previous = desktop.latestPointer
        stroke(CGPoint(x: left, y: height / 2), dx: 96, dy: 0)
        XCTAssertTrue(mode.exists)
        XCTAssertEqual(desktop.latestPointer, previous)
        XCTAssertEqual(desktop.clicks, 0)
        XCTAssertEqual(desktop.scrollTicks, 0)
    }
    #endif

    #if !targetEnvironment(macCatalyst)
    func testAppleStandardCompressionChangesPixelsAndPreservesNativePointerCoordinates() async throws {
        for capability in [true, false] {
            let desktop = LocalTestDisplay(appleScalingCapability: capability)
            let port = try await desktop.start()
            defer {
                if let error = desktop.failure { XCTFail(error) }
                desktop.stop()
            }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            app.buttons["library.quick"].tap()
            applyLink("vnc://127.0.0.1:\(port)", in: app)
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.tap()
            func policy(_ id: String, _ choice: String) {
                let control = app.buttons[id]
                for _ in 0..<4 where !control.isHittable { app.swipeUp() }
                control.tap()
                app.buttons[choice].firstMatch.tap()
            }
            policy("connection.adaptiveQuality", "永不启用")
            policy("connection.tightCompression", "始终启用")
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 || desktop.failure != nil }
            XCTAssertNil(desktop.failure)
            XCTAssertEqual(desktop.halfResolutionRequested, capability)
            let expected = capability ? CGSize(width: 160, height: 96) : CGSize(width: 320, height: 192)
            XCTAssertEqual(desktop.requestedFramebufferSize, expected)
            try await waitUntil { Self.hasColorChart(app.screenshot().image) }
            guard desktop.failure == nil else { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try await waitUntil { desktop.clicks > 0 || desktop.failure != nil }
            XCTAssertNil(desktop.failure)
            XCTAssertEqual(try XCTUnwrap(desktop.lastClickX), 160, accuracy: 4)
            app.buttons["session.close"].tap()
        }
    }
    #endif

    func testTightJPEGQualityOnWireHonorsAlwaysAndRemoteOnlyOnLoopback() async throws {
        for (choice, compressed) in [("始终启用", true), ("仅远程连接时启用", false)] {
            let desktop = LocalTestDisplay(servesJPEG: true)
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            app.buttons["library.quick"].tap()
            applyLink("vnc://127.0.0.1:\(port)", in: app)
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            XCTAssertTrue(display.isHittable)
            display.tap()
            let compression = app.buttons["connection.tightCompression"]
            for _ in 0..<4 where !compression.isHittable { app.swipeUp() }
            XCTAssertTrue(compression.isHittable)
            compression.tap()
            app.buttons[choice].firstMatch.tap()
            if compressed {
                let slider = app.sliders["connection.tightJPEGQuality"].firstMatch
                for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
                XCTAssertTrue(slider.isEnabled)
                slider.adjust(toNormalizedSliderPosition: 1)
            }
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 }
            XCTAssertTrue(desktop.advertisedEncodings.contains(7))
            let qualityEncodings = desktop.advertisedEncodings.filter { (-32 ... -23).contains($0) }
            XCTAssertEqual(qualityEncodings, compressed ? [-23] : [])
            try await waitUntil { Self.hasColorChart(app.screenshot().image) }
            app.buttons["session.close"].tap()
        }
    }

    func testControlAndObservationAgainstLoopbackDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        let quick = app.buttons["library.quick"]
        openChart(app, port: port)
        let mode = app.buttons["session.mode"]
        try await waitUntil { mode.exists && desktop.frameCount > 0 }
        XCTAssertNil(desktop.failure)
        try await waitUntil { Self.hasColorChart(app.screenshot().image) }
        let chart = XCTAttachment(screenshot: app.screenshot())
        chart.name = "Remote chart in control mode"
        chart.lifetime = .keepAlways
        add(chart)
        let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        point.tap()
        try await waitUntil { desktop.clicks > 0 }
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        let previous = desktop.clicks
        point.tap()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(desktop.clicks, previous)
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))
        app.buttons["session.close"].tap()
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
    }

    #if !targetEnvironment(macCatalyst)
    func testHoldDelayChangesWhetherTheSameFingerMotionDragsOrScrolls() async throws {
        for shortDelay in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            openChart(app, port: port) {
                app.buttons["library.more"].tap()
                app.buttons["设置"].firstMatch.tap()
                let slider = app.sliders["preferences.dragDelay"]
                for _ in 0..<6 where !slider.isHittable { app.swipeUp() }
                XCTAssertTrue(slider.isHittable)
                slider.adjust(toNormalizedSliderPosition: shortDelay ? 0 : 1)
                app.buttons["关闭"].firstMatch.tap()
            }
            try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
            let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
            point.press(forDuration: 0.42, thenDragTo: point.withOffset(CGVector(dx: 100, dy: 165)))
            if shortDelay {
                try await waitUntil { desktop.heldLeftX.count >= 2 }
            } else {
                try await waitUntil { desktop.scrollTicks > 0 }
                XCTAssertTrue(desktop.heldLeftX.isEmpty)
            }
            app.buttons["session.close"].tap()
        }
    }

    func testDraggingToTheNearbyDownloadTargetRequestsOnlyTheChosenFile() async throws {
        let desktop = LocalTestDisplay(appleScalingCapability: false, offersDraggedFile: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let file = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.57))
        let outside = file.withOffset(CGVector(dx: 24, dy: 160))
        file.press(forDuration: 1.2, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.4)
        try await waitUntil { desktop.heldLeftX.count > 1 }
        XCTAssertEqual(desktop.downloadRequests, 0)
        let target = file.withOffset(CGVector(dx: 78, dy: -44))
        file.press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.4)
        try await waitUntil { desktop.downloadRequests == 1 || desktop.failure != nil }
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.downloadRequests, 1)
    }

    func testDraggedDownloadContinuesAfterLeavingTheApp() async throws {
        let desktop = LocalTestDisplay(appleScalingCapability: false, offersDraggedFile: true, completesDraggedFile: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let file = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.57))
        let target = file.withOffset(CGVector(dx: 78, dy: -44))
        file.press(forDuration: 1.2, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.4)
        try await waitUntil { desktop.startedFileStreams == 1 || desktop.failure != nil }
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.startedFileStreams, 1)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        try await Task.sleep(for: .seconds(9))
        desktop.maySendRemainingFileBytes = true
        try await waitUntil { desktop.finishedFileStreams == 1 || desktop.failure != nil }
        XCTAssertNil(desktop.failure)
        XCTAssertEqual(desktop.finishedFileStreams, 1)
        XCTAssertEqual(app.state, .runningBackground)
    }

    func testConnectionDragDelayOverridesTheApplicationDefault() async throws {
        for shortDelay in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            app.launchArguments = ["--test-library", UUID().uuidString]
            app.launch()
            app.buttons["library.quick"].tap()
            applyLink("vnc://127.0.0.1:\(port)", in: app)
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.tap()
            let toggle = app.switches["connection.customDragDelay"].firstMatch
            for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "1")
            let slider = app.sliders["connection.dragDelay"]
            for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
            slider.adjust(toNormalizedSliderPosition: shortDelay ? 0 : 1)
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
            let point = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.42))
            point.press(forDuration: 0.42, thenDragTo: point.withOffset(CGVector(dx: 100, dy: 165)))
            if shortDelay {
                try await waitUntil { desktop.heldLeftX.count >= 2 }
            } else {
                try await waitUntil { desktop.scrollTicks > 0 }
                XCTAssertTrue(desktop.heldLeftX.isEmpty)
            }
            app.buttons["session.close"].tap()
        }
    }

    func testConnectionDetailsCountInputWrittenToTheDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let info = app.buttons["session.info"]
        try await waitUntil { info.exists && desktop.frameCount > 0 }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        try await waitUntil { desktop.clicks > 0 }
        app.buttons["toolbar.tab"].tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }
        info.tap()
        func detail(_ name: String) -> String? {
            let row = app.descendants(matching: .any).matching(identifier: "details." + name).firstMatch
            return row.exists ? row.value as? String : nil
        }
        try await waitUntil { detail("encoding") == "Raw" }
        XCTAssertEqual(detail("protocol"), "RFB 3.8")
        XCTAssertEqual(detail("dimensions"), "160 × 96")
        XCTAssertEqual(detail("encryption"), "未加密")
        XCTAssertGreaterThanOrEqual(Int(detail("pointer") ?? "") ?? 0, 2)
        XCTAssertEqual(Int(detail("keys") ?? ""), 2)
        XCTAssertGreaterThan(Int(detail("frames") ?? "") ?? 0, 0)
        app.buttons["details.done"].tap()
        app.buttons["session.close"].tap()
        try await waitUntil { app.buttons["library.quick"].exists }
        app.terminate()
        app.launch()
        let recent = app.staticTexts["最近连接"].firstMatch
        if !recent.isHittable {
            let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@", ["显示边栏", "显示侧边栏", "Show Sidebar"])).firstMatch
            if sidebar.isHittable { sidebar.tap() }
        }
        recent.tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        entry.press(forDuration: 0.8)
        app.buttons["上次连接信息"].tap()
        try await waitUntil { detail("date") != nil }
        XCTAssertEqual(detail("encoding"), "Raw")
        XCTAssertEqual(detail("dimensions"), "160 × 96")
        XCTAssertEqual(detail("keys"), "2")
        XCTAssertGreaterThanOrEqual(Int(detail("pointer") ?? "") ?? 0, 2)
        app.buttons["details.done"].tap()
    }

    func testMonitorKeyboardShortcutsSelectWithoutSendingDigitsToDesktop() async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.monitors"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.tap()
        app.typeKey("2", modifierFlags: [.control, .shift])
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [1, 3]) }
        app.typeKey("0", modifierFlags: [.control, .shift])
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04) }
        XCTAssertTrue(Set(desktop.keyDowns).isDisjoint(with: [0x30, 0x32, 0x29, 0x40]))
        app.buttons["session.close"].tap()
    }

    func testSwitchMonitorCropsThePictureAndMapsInputToTheSameMonitor() async throws {
        let desktop = LocalTestDisplay(hasTwoMonitors: true)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let menu = app.buttons["session.monitors"]
        let mode = app.buttons["session.mode"]
        try await waitUntil { desktop.frameCount > 0 && menu.exists }
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [0, 2]) }
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        target.tap()
        try await waitUntil { desktop.lastClickX.map { (0..<80).contains($0) } == true }
        menu.tap()
        app.buttons["显示器 2"].firstMatch.tap()
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [1, 3]) }
        target.tap()
        try await waitUntil { desktop.lastClickX.map { (80..<160).contains($0) } == true }
        mode.tap()
        try await waitUntil { mode.label == "仅观察" }
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04, visible: [1, 3]))
        let before = desktop.clicks
        menu.tap()
        app.buttons["所有显示器"].firstMatch.tap()
        try await waitUntil { Self.hasColorChart(app.screenshot().image, minimumFraction: 0.04) }
        target.tap()
        XCTAssertEqual(desktop.clicks, before)
        app.buttons["session.close"].tap()
    }

    func testSharedMacAccessLinksOpenWithTheExternalPortOnTheCorrectService() throws {
        let env = ProcessInfo.processInfo.environment
        let json = env["DESKLINK_MAC_ACCESS_LINKS"] ?? #"{"ssh":"desklink://[2001:db8::10]?ssh=42422","direct":"desklink://[2001:db8::10]:42422"}"#
        let links = try JSONDecoder().decode([String: URL].self, from: Data(json.utf8))
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))
        for kind in ["direct", "ssh"] {
            app.open(try XCTUnwrap(links[kind]))
            let host = app.textFields["connection.host"]
            XCTAssertTrue(host.waitForExistence(timeout: 10))
            XCTAssertEqual(host.value as? String, "2001:db8::10")
            XCTAssertEqual(app.textFields["connection.port"].value as? String, kind == "ssh" ? "5900" : "42422")
            if kind == "ssh" {
                let port = app.textFields["connection.sshPort"]
                for _ in 0..<4 where !port.exists { app.swipeUp() }
                XCTAssertEqual(port.value as? String, "42422")
            }
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        }
    }

    func testSystemVNCAndSSHLinksOpenTheCorrespondingConnectionForms() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))

        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let url = try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)?observe=1"))
        app.open(url)
        let submit = app.buttons["connection.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["connection.port"].value as? String, String(port))
        XCTAssertEqual(desktop.frameCount, 0)
        submit.tap()
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        XCTAssertEqual(app.buttons["session.mode"].label, "仅观察")
        app.buttons["session.close"].tap()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 10))

        for scheme in ["ssh", "screens-ssh"] {
            app.open(try XCTUnwrap(URL(string: scheme + "://reader@studio.fixture.invalid:2203")))
            XCTAssertTrue(submit.waitForExistence(timeout: 10))
            XCTAssertEqual(app.textFields["connection.host"].value as? String, "studio.fixture.invalid")
            XCTAssertEqual(app.textFields["connection.port"].value as? String, "5900")
            let sshPort = app.textFields["connection.sshPort"]
            for _ in 0..<4 where !sshPort.exists { app.swipeUp() }
            XCTAssertEqual(sshPort.value as? String, "2203")
            let sshUser = app.textFields["connection.sshUsername"]
            for _ in 0..<4 where !sshUser.exists { app.swipeUp() }
            XCTAssertEqual(sshUser.value as? String, "reader")
            app.buttons["取消"].firstMatch.tap()
            XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 8))
        }
    }

    func testQuickLinkKeepsObservationModeAndWaitsForExplicitConnection() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        app.buttons["library.quick"].tap()
        applyLink("vnc://127.0.0.1:\(port)?observe=1", in: app)
        let host = app.textFields["connection.host"]
        try await waitUntil { host.value as? String == "127.0.0.1" }
        XCTAssertEqual(app.textFields["connection.port"].value as? String, String(port))
        XCTAssertEqual(desktop.frameCount, 0)
        app.buttons["connection.submit"].tap()
        let mode = app.buttons["session.mode"]
        try await waitUntil { desktop.frameCount > 0 && mode.label == "仅观察" }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertEqual(desktop.clicks, 0)
        app.buttons["session.close"].tap()
    }

    func testChangingTheTargetClearsOnlyThePasswordFromTheLink() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        app.buttons["library.quick"].tap()
        applyLink("vnc://reader:fixture@host.invalid:5910", in: app)
        let host = app.textFields["connection.host"]
        try await waitUntil { host.value as? String == "host.invalid" }
        XCTAssertEqual(app.textFields["connection.username"].value as? String, "reader")
        let password = app.secureTextFields["connection.password"]
        let filled = try XCTUnwrap(password.value as? String)
        XCTAssertTrue(filled.contains("•"))
        XCTAssertEqual(app.switches["connection.remember"].value as? String, "0")
        host.tap()
        host.typeText("x")
        try await waitUntil { (password.value as? String)?.contains("•") != true }
        XCTAssertEqual(app.textFields["connection.username"].value as? String, "reader")
    }

    func testHoldingToolbarTabObeysTheRepeatSetting() async throws {
        for enabled in [true, false] {
            let desktop = LocalTestDisplay()
            let port = try await desktop.start()
            defer { desktop.stop() }
            let app = XCUIApplication()
            openChart(app, port: port) {
                if !enabled {
                    app.buttons["library.more"].tap()
                    app.buttons["设置"].firstMatch.tap()
                    let settings = app.buttons["preferences.keyRepeat"]
                    let navbar = app.navigationBars["设置"]
                    XCTAssertTrue(navbar.waitForExistence(timeout: 5))
                    let top = navbar.frame.maxY
                    let center = navbar.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 1))
                        .withOffset(.init(dx: 0, dy: 260))
                    for _ in 0..<8 {
                        if settings.exists, (top + 25...top + 420).contains(settings.frame.midY), settings.isHittable { break }
                        let step = settings.exists && settings.frame.midY < top + 25 ? 130 : -130
                        center.press(forDuration: 0.15, thenDragTo: center.withOffset(.init(dx: 0, dy: CGFloat(step))),
                                     withVelocity: .slow, thenHoldForDuration: 0.15)
                    }
                    settings.tap()
                    let toggle = app.switches["repeat.enabled"]
                    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                    toggle.coordinate(withNormalizedOffset: .init(dx: 0.94, dy: 0.5)).tap()
                    XCTAssertEqual(toggle.value as? String, "0")
                    app.navigationBars["键盘重复"].buttons.firstMatch.tap()
                    app.buttons["关闭"].firstMatch.tap()
                }
            }
            let key = app.buttons["toolbar.tab"]
            try await waitUntil { desktop.frameCount > 0 && key.isHittable }
            key.press(forDuration: 0.75)
            try await waitUntil { !desktop.keyDowns.isEmpty }
            let repeats = desktop.keyDowns.filter { $0 == 0xff09 }.count
            if enabled { XCTAssertGreaterThanOrEqual(repeats, 3) } else { XCTAssertEqual(repeats, 1) }
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(desktop.keyDowns.count, repeats)
            app.terminate()
        }
    }

    func testInteractiveToolbarSendsControlTabOnceAndRestoresAfterHiding() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let control = app.buttons["toolbar.control"]
        let tab = app.buttons["toolbar.tab"]
        XCTAssertTrue(control.waitForExistence(timeout: 8))
        control.tap()
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFFE3, 0xFF09] }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFFE3, 0xFF09, 0xFF09] }
        app.buttons["toolbar.toggle"].tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        app.buttons["toolbar.show"].tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = "iPad docked toolbar"
        result.lifetime = .keepAlways
        add(result)
        app.buttons["session.close"].tap()
    }

    func testPinnedRemoteActionsSendPlatformShortcuts() async throws {
        let desktop = LocalTestDisplay()
        var wire: [Int] = []
        desktop.onWireKey = { down, key in wire.append(down ? Int(key) : -Int(key)) }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let macDesktop = LocalTestDisplay(appleScalingCapability: false)
        var macWire: [Int] = []
        macDesktop.onWireKey = { down, key in macWire.append(down ? Int(key) : -Int(key)) }
        let macPort = try await macDesktop.start()
        defer { macDesktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) {
            app.buttons["library.more"].tap()
            app.buttons["设置"].firstMatch.tap()
            let settings = app.navigationBars["设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let top = settings.frame.maxY
            let scroll = settings.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 1))
                .withOffset(.init(dx: 0, dy: 260))
            let toolbar = app.buttons["preferences.toolbar"]
            for _ in 0..<8 {
                if toolbar.exists, (top + 25...top + 420).contains(toolbar.frame.midY), toolbar.isHittable { break }
                let step = toolbar.exists && toolbar.frame.midY < top + 25 ? CGFloat(120) : -120
                scroll.press(forDuration: 0.15, thenDragTo: scroll.withOffset(.init(dx: 0, dy: step)),
                             withVelocity: .slow, thenHoldForDuration: 0.15)
            }
            toolbar.coordinate(withNormalizedOffset: .init(dx: 0.35, dy: 0.5)).tap()
            XCTAssertTrue(app.navigationBars["互动工具栏"].waitForExistence(timeout: 5))
            let add = app.buttons["toolbar.addButton"]
            for _ in 0..<4 where !add.isHittable { app.swipeUp() }
            add.tap()
            for (id, title) in [("switchApp", "切换 App"), ("spotlight", "聚焦／开始菜单"), ("missionControl", "调度中心／任务视图")] {
                let option = app.buttons["toolbar.add." + id]
                for _ in 0..<4 where !option.isHittable { app.swipeUp() }
                XCTAssertTrue(option.isHittable)
                XCTAssertEqual(option.label, title)
                option.tap()
            }
            attachToolbarScreenshot(app, name: "Choose pinned toolbar commands")
            app.buttons["添加"].tap()
            app.terminate()
            app.launch()
        }
        let switchApp = app.buttons["toolbar.switchApp"]
        let spotlight = app.buttons["toolbar.spotlight"]
        let missionControl = app.buttons["toolbar.missionControl"]
        try await waitUntil { desktop.frameCount > 0 && switchApp.isHittable && switchApp.isEnabled }
        XCTAssertTrue(spotlight.isHittable)
        XCTAssertTrue(missionControl.isEnabled)
        XCTAssertEqual(spotlight.label, "开始菜单")
        XCTAssertEqual(missionControl.label, "任务视图")
        let control = app.buttons["toolbar.control"]
        control.tap()
        XCTAssertEqual(control.value as? String, "已选中")
        switchApp.tap()
        try await waitUntil { wire.count >= 4 }
        XCTAssertEqual(wire, [0xFFE9, 0xFF09, -0xFF09, -0xFFE9])
        XCTAssertNotEqual(control.value as? String, "已选中")
        spotlight.tap()
        try await waitUntil { wire.count >= 6 }
        XCTAssertEqual(Array(wire.suffix(2)), [0xFFEB, -0xFFEB])
        missionControl.tap()
        try await waitUntil { wire.count >= 10 }
        XCTAssertEqual(Array(wire.suffix(4)), [0xFFEB, 0xFF09, -0xFF09, -0xFFEB])
        attachToolbarScreenshot(app, name: "Pinned commands on a standard desktop")
        app.buttons["session.close"].tap()

        connectChart(app, port: macPort) {
            let display = app.buttons["显示器"].firstMatch
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.tap()
            let adaptive = app.buttons["connection.adaptiveQuality"]
            for _ in 0..<4 where !adaptive.isHittable { app.swipeUp() }
            adaptive.tap()
            app.buttons["永不启用"].firstMatch.tap()
        }
        try await waitUntil { macDesktop.frameCount > 0 && missionControl.isHittable && missionControl.isEnabled }
        XCTAssertEqual(spotlight.label, "聚焦")
        XCTAssertEqual(missionControl.label, "调度中心")
        attachToolbarScreenshot(app, name: "Pinned commands on a Mac desktop")
        switchApp.tap()
        try await waitUntil { macWire.count >= 4 }
        XCTAssertEqual(macWire, [0xFFEB, 0xFF09, -0xFF09, -0xFFEB])
        spotlight.tap()
        try await waitUntil { macWire.count >= 8 }
        XCTAssertEqual(Array(macWire.suffix(4)), [0xFFEB, 0x20, -0x20, -0xFFEB])
        missionControl.tap()
        try await waitUntil { macWire.count >= 12 }
        XCTAssertEqual(Array(macWire.suffix(4)), [0xFFE3, 0xFF52, -0xFF52, -0xFFE3])
        let receipt = XCTAttachment(string: "Standard RFB: \(wire)\nApple RFB: \(macWire)")
        receipt.name = "Remote key press and release events"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testPortraitSplitSeparatesPicturePointerAndKeyboardAcrossRotation() async throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let desktop = LocalTestDisplay()
        var wire: [(UInt8, CGPoint)] = []
        desktop.onWirePointer = { wire.append(($0, $1)) }
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.enablePortraitSplit(in: app) }
        let trackpad = app.descendants(matching: .any)["session.laptopTrackpad"].firstMatch
        let keypad = app.descendants(matching: .any)["session.splitKeypad"].firstMatch
        let tab = app.buttons["toolbar.tab"].firstMatch
        let keyboard = app.buttons["toolbar.keyboard"].firstMatch
        try await waitUntil { trackpad.exists && keypad.exists && desktop.frameCount > 0 }
        XCTAssertLessThan(keypad.frame.maxX, trackpad.frame.minX)
        XCTAssertGreaterThan(trackpad.frame.minY, app.frame.midY - 80)
        XCTAssertGreaterThan(trackpad.frame.height, 70)
        attachToolbarScreenshot(app, name: "Portrait with side-by-side controls")

        let upper = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.23))
        upper.tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(wire.contains { $0.0 != 0 })
        wire.removeAll()
        let left = trackpad.coordinate(withNormalizedOffset: .init(dx: 0.26, dy: 0.48))
        let right = trackpad.coordinate(withNormalizedOffset: .init(dx: 0.74, dy: 0.48))
        left.press(forDuration: 0.08, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0)
        try await waitUntil { Set(wire.map { $0.1.x }).count > 1 }
        XCTAssertFalse(wire.contains { $0.0 != 0 })
        app.buttons["session.trackpad.leftClick"].tap()
        try await waitUntil { wire.contains { $0.0 == 1 } }
        app.buttons["session.trackpad.rightClick"].tap()
        try await waitUntil { wire.contains { $0.0 == 4 } }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }

        keyboard.tap()
        let software = app.keyboards.firstMatch
        try await waitUntil(timeout: 15) { software.exists && software.frame.height > 120 && !trackpad.exists }
        XCTAssertLessThan(abs(software.frame.minY - keyboard.frame.maxY), 90)
        attachToolbarScreenshot(app, name: "Portrait with the system keyboard")
        let greeting: [UInt32] = [0x01004F60, 0x0100597D]
        try await selectPinyinGreeting(in: app, opensKeyboard: false) {
            XCTAssertEqual(desktop.keyDowns, [0xFF09])
        }
        try await waitUntil { desktop.keyDowns == [0xFF09] + greeting }
        keyboard.tap()
        try await waitUntil { trackpad.exists }

        app.buttons["切换全屏幕"].firstMatch.tap()
        try await waitUntil { !trackpad.exists && !app.buttons["session.close"].exists }
        let surface = app.descendants(matching: .any)["session.input"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        surface.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        try await waitUntil { trackpad.exists }

        device.orientation = .landscapeLeft
        try await waitUntil { app.frame.width > app.frame.height && !trackpad.exists && tab.isHittable }
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] + greeting + [0xFF09] }
        let landscape = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(landscape.image.size.width, landscape.image.size.height)
        let landscapeAttachment = XCTAttachment(screenshot: landscape)
        landscapeAttachment.name = "Landscape with the regular toolbar"
        landscapeAttachment.lifetime = .keepAlways
        add(landscapeAttachment)
        device.orientation = .portrait
        try await waitUntil { app.frame.height > app.frame.width && trackpad.exists }
        XCTAssertEqual(desktop.acceptedConnections, 1)
    }

    func testPortraitKeyboardAndTrackpadSendsKeysAndLeavesObservationReadOnly() async throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.enablePortraitSplit(in: app, layout: "键盘与触控板") }
        let trackpad = app.descendants(matching: .any)["session.laptopTrackpad"].firstMatch
        let keyboard = app.descendants(matching: .any)["session.laptopKeyboard"].firstMatch
        let letter = app.buttons["a"].firstMatch
        try await waitUntil { trackpad.exists && keyboard.exists && letter.isHittable && desktop.frameCount > 0 }
        XCTAssertLessThan(keyboard.frame.maxY, trackpad.frame.minY)
        attachToolbarScreenshot(app, name: "Portrait with the dedicated keyboard")
        letter.tap()
        try await waitUntil { desktop.keyDowns == [0x61] }
        let mode = app.buttons["session.mode"].firstMatch
        mode.tap()
        try await waitUntil { mode.label == "仅观察" && !trackpad.exists && !keyboard.exists }
        let received = desktop.clicks
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.56)).tap()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(desktop.clicks, received)
        mode.tap()
        try await waitUntil { trackpad.exists && keyboard.exists && letter.isHittable }
        letter.tap()
        try await waitUntil { desktop.keyDowns == [0x61, 0x61] }
        XCTAssertEqual(desktop.acceptedConnections, 1)
    }

    private func enablePortraitSplit(in app: XCUIApplication, layout: String? = nil) {
        app.buttons["library.more"].tap()
        app.buttons["设置"].firstMatch.tap()
        let toolbar = app.buttons["preferences.toolbar"]
        for _ in 0..<4 where !toolbar.isHittable { app.swipeUp() }
        XCTAssertTrue(toolbar.isHittable)
        toolbar.tap()
        let split = app.switches["toolbar.portraitSplit"].firstMatch
        for _ in 0..<4 where !split.isHittable { app.swipeUp() }
        XCTAssertTrue(split.isHittable)
        XCTAssertEqual(split.value as? String, "0")
        split.coordinate(withNormalizedOffset: .init(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(split.value as? String, "1")
        if let layout {
            app.buttons["toolbar.splitControls"].firstMatch.tap()
            app.buttons[layout].firstMatch.tap()
        }
        app.terminate()
        app.launch()
    }

    func testFloatingToolbarCanCollapseAndStillSendKeysAfterExpanding() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.selectToolbar("浮动", in: app) }
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let disclosure = app.buttons["toolbar.expand"]
        let tab = app.buttons["toolbar.tab"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        disclosure.press(forDuration: 1)
        XCTAssertTrue(app.buttons["显示键盘"].firstMatch.waitForExistence(timeout: 4))
        app.buttons["远程快捷命令"].firstMatch.tap()
        let insert = app.buttons["Insert"].firstMatch
        XCTAssertTrue(insert.waitForExistence(timeout: 4))
        insert.tap()
        try await waitUntil { desktop.keyDowns == [0xFF63] }
        disclosure.tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF63, 0xFF09] }
        attachToolbarScreenshot(app, name: "iPad floating toolbar")
        app.buttons["session.close"].tap()
    }

    func testTwoFingerDoubleTapEntersAndLeavesFullScreenWithoutRemoteClicks() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        let close = app.buttons["session.close"]
        try await waitUntil { desktop.frameCount > 0 && close.exists }
        let surface = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 4))
        surface.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        try await waitUntil { !close.exists && !app.buttons["toolbar.tab"].exists }
        surface.tap(withNumberOfTaps: 2, numberOfTouches: 2)
        try await waitUntil { close.exists && app.buttons["toolbar.tab"].exists }
        XCTAssertEqual(desktop.clicks, 0)
        close.tap()
    }

    func testCarouselPagesCanSendKeysAndMoveAwayFromDesktopContent() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port) { self.selectToolbar("轮播", in: app) }
        try await waitUntil { desktop.frameCount > 0 && app.buttons["session.mode"].exists }
        let next = app.buttons["toolbar.next"]
        let tab = app.buttons["toolbar.tab"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        tab.tap()
        try await waitUntil { desktop.keyDowns == [0xFF09] }
        next.tap()
        XCTAssertTrue(tab.waitForNonExistence(timeout: 5))
        app.buttons["toolbar.functions"].tap()
        app.buttons["F5"].tap()
        try await waitUntil { desktop.keyDowns == [0xFF09, 0xFFC2] }
        next.tap()
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        let start = next.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let previous = next.frame.midX
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: -140, dy: -60)))
        try await waitUntil { next.frame.midX < previous - 70 }
        attachToolbarScreenshot(app, name: "iPad carousel toolbar")
        app.buttons["session.close"].tap()
    }

    private func selectToolbar(_ style: String, in app: XCUIApplication) {
        app.buttons["library.more"].tap()
        app.buttons["设置"].firstMatch.tap()
        let toolbar = app.buttons["preferences.toolbar"]
        for _ in 0..<4 where !toolbar.isHittable { app.swipeUp() }
        XCTAssertTrue(toolbar.isHittable)
        toolbar.tap()
        app.buttons["toolbar.style.setting"].tap()
        app.buttons[style].firstMatch.tap()
        // Reopen from the library and use the style actually persisted by Settings.
        app.terminate()
        app.launch()
    }

    private func attachToolbarScreenshot(_ app: XCUIApplication, name: String) {
        let result = XCTAttachment(screenshot: app.screenshot())
        result.name = name
        result.lifetime = .keepAlways
        add(result)
    }

    @available(iOS 27, *)
    func testExternalDisplayShowsOnlyTheSelectedDesktop() async throws {
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        openChart(app, port: port)
        try await waitUntil { app.buttons["session.mode"].exists && desktop.frameCount > 0 }
        let mirror = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "镜像到外部显示器")).firstMatch
        let offered = mirror.waitForExistence(timeout: 6)
        try XCTSkipIf(!offered && XCUIScreen.screens.count < 2, "Requires an attached noninteractive external display")
        XCTAssertTrue(offered, "The system exposes another screen, but the session does not offer mirroring")
        guard offered else { return }
        mirror.tap()
        try await waitUntil { XCUIScreen.screens.dropFirst().contains { Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) } }
        let external = try XCTUnwrap(XCUIScreen.screens.dropFirst().first { Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) })
        let output = XCTAttachment(screenshot: external.screenshot())
        output.name = "External display, remote desktop only"
        output.lifetime = .keepAlways
        add(output)
        XCTAssertTrue(Self.hasColorChart(app.screenshot().image))
        app.buttons["session.close"].tap()
        try await waitUntil { app.buttons["library.quick"].exists }
        try await waitUntil { XCUIScreen.screens.dropFirst().allSatisfy { !Self.hasColorChart($0.screenshot().image, minimumFraction: 0.18) } }
    }
    #endif

    private func applyLink(_ text: String, in app: XCUIApplication) {
        app.buttons["connection.openLink"].tap()
        let field = app.alerts.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText(text)
        app.alerts.buttons["使用链接"].tap()
    }

    private func openChart(_ app: XCUIApplication, port: UInt16, prepare: () -> Void = {}) {
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].waitForExistence(timeout: 12))
        prepare()
        connectChart(app, port: port)
    }

    private func connectChart(_ app: XCUIApplication, port: UInt16, configure: () -> Void = {}) {
        let quick = app.buttons["library.quick"]
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        quick.tap()
        let field = app.textFields["connection.host"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let submit = app.buttons["connection.submit"]
        XCTAssertFalse(submit.isEnabled)
        field.tap()
        field.typeText("127.0.0.1:\(port)")
        configure()
        submit.tap()
    }

    private func waitUntil(timeout: TimeInterval = 12, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() {
            guard Date() < deadline else { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private struct TimedOut: LocalizedError {
        var errorDescription: String? { "The expected UI or loopback event did not arrive before the deadline." }
    }

    private static func hasColorChart(_ screenshot: UIImage, minimumFraction: Double = 0.005,
                                      visible: Set<Int> = [0, 1, 2, 3]) -> Bool {
        let fractions = chartFractions(screenshot)
        return fractions.count == 4 && fractions.enumerated().allSatisfy { index, fraction in
            visible.contains(index) ? fraction > minimumFraction : fraction < 0.02
        }
    }

    private static func chartFractions(_ screenshot: UIImage) -> [Double] {
        guard let image = screenshot.cgImage else { return [] }
        let dimension = 64
        var bytes = [UInt8](repeating: 0, count: dimension * dimension * 4)
        let colors = [[31,89,165], [241,183,69], [52,174,146], [223,102,88]]
        return bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return [] }
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            let pixels = storage.bindMemory(to: UInt8.self)
            var counts = [Int](repeating: 0, count: 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                for (color, components) in colors.enumerated() where
                    (0..<3).allSatisfy({ abs(Int(pixels[index+$0]) - components[$0]) < 28 }) {
                    counts[color] += 1
                }
            }
            return counts.map { Double($0) / Double(dimension * dimension) }
        }
    }
}
