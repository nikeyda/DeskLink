import UIKit
import XCTest

@MainActor
final class SessionUITests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
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
        let origin = surface.coordinate(withNormalizedOffset: .zero)
        let width = surface.frame.width, height = surface.frame.height
        let right = origin.withOffset(CGVector(dx: width - 16, dy: height * 0.52))
        right.press(forDuration: 0.03, thenDragTo: right.withOffset(CGVector(dx: -96, dy: 0)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        try await waitUntil { desktop.latestPointer?.x == 159 }
        let mappedY = try XCTUnwrap(desktop.latestPointer?.y)
        XCTAssertTrue((20...76).contains(mappedY))
        let corner = origin.withOffset(CGVector(dx: 16, dy: height - 16))
        corner.press(forDuration: 0.03, thenDragTo: corner.withOffset(CGVector(dx: 96, dy: -96)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        try await waitUntil { desktop.latestPointer == CGPoint(x: 80, y: 95) }
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
            app.buttons["connection.submit"].tap()
            try await waitUntil { desktop.frameCount > 0 }
            XCTAssertTrue(desktop.advertisedEncodings.contains(7))
            XCTAssertEqual(desktop.advertisedEncodings.contains(-28), compressed)
            XCTAssertFalse(desktop.advertisedEncodings.contains(-23))
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
        let quick = app.buttons["library.quick"]
        XCTAssertTrue(quick.waitForExistence(timeout: 12))
        prepare()
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        quick.tap()
        let field = app.textFields["connection.host"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let submit = app.buttons["connection.submit"]
        XCTAssertFalse(submit.isEnabled)
        field.tap()
        field.typeText("127.0.0.1:\(port)")
        submit.tap()
    }

    private func waitUntil(timeout: TimeInterval = 12, _ check: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !check() && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard check() else { throw TimedOut() }
    }

    private struct TimedOut: LocalizedError {
        var errorDescription: String? { "The expected UI or loopback event did not arrive before the deadline." }
    }

    private static func hasColorChart(_ screenshot: UIImage, minimumFraction: Double = 0.005,
                                      visible: Set<Int> = [0, 1, 2, 3]) -> Bool {
        guard let image = screenshot.cgImage else { return false }
        let dimension = 64
        var bytes = [UInt8](repeating: 0, count: dimension * dimension * 4)
        let colors = [[31,89,165], [241,183,69], [52,174,146], [223,102,88]]
        return bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            let pixels = storage.bindMemory(to: UInt8.self)
            var counts = [Int](repeating: 0, count: 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                for (color, components) in colors.enumerated() where
                    (0..<3).allSatisfy({ abs(Int(pixels[index+$0]) - components[$0]) < 28 }) {
                    counts[color] += 1
                }
            }
            return counts.enumerated().allSatisfy { index, count in
                let fraction = Double(count) / Double(dimension * dimension)
                return visible.contains(index) ? fraction > minimumFraction : fraction < 0.02
            }
        }
    }
}
