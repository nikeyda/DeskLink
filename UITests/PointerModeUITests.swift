#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class PointerModeUITests: XCTestCase {
    func testDefaultAndSessionPointerChoicesReachTheRemoteDesktop() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()

        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["设置"].firstMatch.tap()
        let preference = app.descendants(matching: .any).matching(identifier: "preferences.pointerMode").firstMatch
        for _ in 0..<6 where !preference.isHittable { app.swipeUp() }
        XCTAssertTrue(preference.isHittable)
        preference.tap()
        app.buttons["触控板"].firstMatch.tap()
        app.buttons["关闭"].firstMatch.tap()

        let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
        let mode = app.buttons["session.mode"].firstMatch
        let fixture = try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)"))
        func connect() async throws {
            let previous = desktop.frameCount
            app.open(fixture)
            let submit = app.buttons["connection.submit"].firstMatch
            XCTAssertTrue(submit.waitForExistence(timeout: 8))
            submit.tap()
            try await waitUntil { desktop.frameCount > previous && input.isHittable && mode.exists }
        }
        func tapSeparation() async throws -> Int {
            let prior = desktop.primaryPresses.count
            for x in [0.26, 0.73] {
                input.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
                let expected = prior + (x < 0.5 ? 1 : 2)
                try await waitUntil { desktop.primaryPresses.count >= expected }
            }
            return abs(desktop.primaryPresses[prior + 1] - desktop.primaryPresses[prior])
        }
        func openPointerMenu() {
            app.buttons["远程桌面控制"].firstMatch.tap()
            app.buttons["指针"].firstMatch.tap()
        }

        try await connect()
        let initial = try await tapSeparation()
        XCTAssertLessThanOrEqual(initial, 2)
        openPointerMenu()
        app.buttons["触摸"].firstMatch.tap()
        let changed = try await tapSeparation()
        XCTAssertGreaterThan(changed, 35)
        mode.tap()
        try await waitUntil { mode.label == "仅观察" && !input.isHittable }
        mode.tap()
        try await waitUntil { input.isHittable }
        let restored = try await tapSeparation()
        XCTAssertGreaterThan(restored, 35)
        XCTAssertEqual(desktop.acceptedConnections, 1)

        openPointerMenu()
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Touch mode retained after observation"
        screen.lifetime = .keepAlways
        add(screen)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45)).tap()
        app.buttons["session.close"].firstMatch.tap()
        try await waitUntil { desktop.closedConnections == 1 }

        try await connect()
        let subsequent = try await tapSeparation()
        XCTAssertLessThanOrEqual(subsequent, 2)
        XCTAssertEqual(desktop.acceptedConnections, 2)
        let receipt = XCTAttachment(string: "Default: \(initial) px\nTouch: \(changed) px\nAfter observing: \(restored) px\nNext session: \(subsequent) px")
        receipt.name = "Pointer mode distances"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    func testSelectedOptionTypesLocalCharactersAndOppositeOptionReachesTheRemoteDesktop() async throws {
        continueAfterFailure = false
        let desktop = LocalTestDisplay()
        let port = try await desktop.start()
        defer { desktop.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()

        let preference = app.descendants(matching: .any).matching(identifier: "preferences.localOptionKey").firstMatch
        func setOption(_ side: String, localized: String) {
            let more = app.buttons["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.tap()
            app.buttons["设置"].firstMatch.tap()
            for _ in 0..<6 where !preference.isHittable { app.swipeUp() }
            XCTAssertTrue(preference.isHittable)
            preference.tap()
            let choice = app.buttons.matching(NSPredicate(format: "label IN %@", [side, localized])).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            let selection = XCTAttachment(screenshot: app.screenshot())
            selection.name = side + " setting"
            selection.lifetime = .keepAlways
            add(selection)
            app.navigationBars.buttons["关闭"].firstMatch.tap()
        }
        func connect() async throws {
            let frames = desktop.frameCount
            let quick = app.buttons["library.quick"].firstMatch
            XCTAssertTrue(quick.waitForExistence(timeout: 10))
            quick.tap()
            let address = app.textFields["connection.host"]
            XCTAssertTrue(address.waitForExistence(timeout: 5))
            address.tap()
            address.typeText("127.0.0.1:\(port)")
            app.buttons["connection.submit"].firstMatch.tap()
            let input = app.descendants(matching: .any).matching(identifier: "session.input").firstMatch
            try await waitUntil { desktop.frameCount > frames && input.isHittable }
            input.tap()
        }

        setOption("左侧 Option", localized: "Left Option")
        try await connect()
        var wire: [(Bool, UInt32)] = []
        desktop.onWireKey = { down, symbol in wire.append((down, symbol)) }
        app.typeKey("k", modifierFlags: [])
        try await waitUntil { wire.contains { !$0.0 && $0.1 == 0x6B } }
        let prior = desktop.keyDowns.count
        wire.removeAll()
        app.typeKey("a", modifierFlags: .option)
        try await waitUntil { desktop.keyDowns.count > prior }
        app.typeKey("e", modifierFlags: .option)
        app.typeKey("e", modifierFlags: [])
        app.typeKey("2", modifierFlags: [.option, .shift])
        app.typeKey("n", modifierFlags: .option)
        app.typeKey("n", modifierFlags: [])
        app.typeKey("o", modifierFlags: .option)
        app.typeKey("z", modifierFlags: [])
        try await waitUntil { wire.contains { !$0.0 && $0.1 == 0x7A } }
        let modifierKeysyms = Set<UInt32>([0xFFE1, 0xFFE2, 0xFFE9, 0xFFEA])
        XCTAssertEqual(desktop.keyDowns.dropFirst(prior).filter { !modifierKeysyms.contains($0) }, [0xE5, 0xE9, 0x010020AC, 0xF1, 0xF8, 0x7A])
        XCTAssertFalse(wire.contains { $0.1 == 0xFFE9 || $0.1 == 0xFFEA })
        var shifts: Set<UInt32> = []
        for (down, symbol) in wire {
            if symbol == 0x010020AC, down { XCTAssertTrue(shifts.isEmpty) }
            if symbol == 0xFFE1 || symbol == 0xFFE2 {
                if down { shifts.insert(symbol) } else { shifts.remove(symbol) }
            }
        }
        let localReceipt = wire.map { ($0.0 ? "down " : "up ") + String($0.1, radix: 16) }

        app.buttons["session.close"].firstMatch.tap()
        try await waitUntil { desktop.closedConnections == 1 }
        setOption("右侧 Option", localized: "Right Option")
        try await connect()
        wire.removeAll()
        app.typeKey("a", modifierFlags: .option)
        try await waitUntil { wire.contains { !$0.0 && $0.1 == 0xFFE9 } }
        XCTAssertEqual(wire.map { $0.0 }, [true, true, false, false])
        XCTAssertEqual(wire.map { $0.1 }, [0xFFE9, 0x61, 0x61, 0xFFE9])
        app.typeKey("y", modifierFlags: [])
        try await waitUntil { wire.contains { !$0.0 && $0.1 == 0x79 } }
        XCTAssertFalse(wire.contains { $0.1 == 0xFFEA })

        let forwarded = wire.map { ($0.0 ? "down " : "up ") + String($0.1, radix: 16) }
        let receipt = XCTAttachment(string: (["Left selected"] + localReceipt + ["Right selected"] + forwarded).joined(separator: "\n"))
        receipt.name = "Local Option and remote Alt wire events"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(60))
        }
    }
}
#endif
