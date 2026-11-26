import XCTest

@MainActor
final class DisconnectActionUITests: XCTestCase {
    func testFourCornersArriveBeforeTheConnectionCloses() async throws {
        for (name, x, y) in [("左上触发角", 0, 0), ("右上触发角", 159, 0),
                             ("左下触发角", 0, 95), ("右下触发角", 159, 95)] {
            try await check(name, pointer: CGPoint(x: x, y: y))
        }
    }

    func testLockLogoutAndControlAltDeleteDeliverCompleteChords() async throws {
        try await check("锁定远程屏幕", apple: true, chord: [0xffe3, 0xffeb, 0x71])
        try await check("注销用户", apple: true, chord: [0xffe1, 0xffeb, 0x71])
        try await check("Ctrl-Alt-Delete", chord: [0xffe3, 0xffe9, 0xffff])
    }

    func testNoActionAndObservationCloseWithoutRemoteInput() async throws {
        try await check("无操作")
        try await check("Ctrl-Alt-Delete", observing: true)
    }

    private func check(_ action: String, apple: Bool = false, observing: Bool = false,
                       pointer: CGPoint? = nil, chord: [Int] = []) async throws {
        let desktop = LocalTestDisplay(appleScalingCapability: apple ? false : nil)
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let create = app.buttons["library.new"].firstMatch
        guard create.waitForExistence(timeout: 10) else { return XCTFail("Missing New Connection") }
        create.tap()
        let form = app.descendants(matching: .any)["connection.form"].firstMatch
        let host = app.textFields["connection.host"].firstMatch
        guard host.waitForExistence(timeout: 6) else { return XCTFail("Missing address editor") }
        // Choose the action before opening the software keyboard.
        if action != "无操作" {
            let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "断开时")).firstMatch
            for _ in 0..<6 {
                if picker.exists && picker.isHittable { break }
                form.swipeUp()
            }
            guard picker.exists && picker.isHittable else { return XCTFail("Missing disconnect action picker") }
            picker.tap()
            let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", action)).firstMatch
            guard option.waitForExistence(timeout: 4) else { return XCTFail("Missing action " + action) }
            option.tap()
        }
        for _ in 0..<6 where !host.isHittable { form.swipeDown() }
        host.tap()
        host.typeText("127.0.0.1:\(port)")
        let submit = app.buttons["connection.submit"].firstMatch
        submit.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.computer.")).firstMatch
        guard row.waitForExistence(timeout: 6) else { return XCTFail("The saved test connection is missing") }
        row.tap()
        guard submit.waitForExistence(timeout: 6) else { return XCTFail("Missing connect button") }
        submit.tap()
        let deadline = Date().addingTimeInterval(15)
        while desktop.frameCount == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard desktop.frameCount > 0 else { return XCTFail("No framebuffer for " + action) }
        let mode = app.buttons["session.mode"].firstMatch
        guard mode.waitForExistence(timeout: 6) else { return XCTFail("The session did not open") }
        if observing {
            mode.tap()
            XCTAssertEqual(mode.label, "仅观察")
        }
        var keys = [Int]()
        var pointers = [CGPoint]()
        desktop.onWireKey = { down, value in keys.append(down ? Int(value) : -Int(value)) }
        desktop.onWirePointer = { buttons, point in
            XCTAssertEqual(buttons, 0, "A disconnect action must not click")
            pointers.append(point)
        }
        desktop.expectsClientDisconnect = true
        app.buttons["session.close"].firstMatch.tap()
        let end = Date().addingTimeInterval(10)
        while desktop.closedConnections == 0 && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(desktop.closedConnections, 1, action)
        XCTAssertNil(desktop.failure, action)
        XCTAssertTrue(row.waitForExistence(timeout: 5), action)
        XCTAssertEqual(keys, chord + chord.reversed().map { -$0 }, action)
        XCTAssertEqual(pointers, pointer.map { [$0] } ?? [], action)
        let receipt = XCTAttachment(string: "port=\(port) frames=\(desktop.frameCount) closed=\(desktop.closedConnections) keys=\(keys) pointers=\(pointers)")
        receipt.name = action + (observing ? " (observe)" : "")
        receipt.lifetime = .keepAlways
        add(receipt)
    }
}
