#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import UIKit
import Vision
import XCTest

/// Operates only the matching pair of generated controls in the Mac acceptance window.
@MainActor
final class PhysicalSessionUITests: XCTestCase {
    func testPrepareHighPerformanceConnectionOnInstalledIPad() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["DESKLINK_MEDIA_CHECK"] == "prepare")
        let host = try XCTUnwrap(environment["DESKLINK_MAC_TEST_HOST"])
        let app = XCUIApplication(bundleIdentifier: "local.nikey.desklink")
        app.activate()
        let recent = app.staticTexts["最近连接"].firstMatch
        if !recent.isHittable {
            let sidebar = app.buttons.matching(NSPredicate(format: "label IN %@",
                                                         ["显示边栏", "显示侧边栏", "Show Sidebar"])).firstMatch
            if sidebar.isHittable { sidebar.tap() }
        }
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "Open the iPad connection library")
        recent.tap()
        let computer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                                        "library.computer.", host)).firstMatch
        XCTAssertTrue(computer.waitForExistence(timeout: 5), "The authorized Mac must be in Recents")
        computer.press(forDuration: 0.8)
        app.buttons["连接模式"].firstMatch.tap()
        app.buttons["以高性能模式连接"].firstMatch.tap()
        let address = app.textFields["connection.host"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        func dnsName(_ value: String) -> String {
            let lower = value.lowercased()
            return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
        }
        XCTAssertEqual(dnsName(try XCTUnwrap(address.value as? String)), dnsName(host))
        XCTAssertTrue(app.buttons["connection.submit"].isEnabled)
    }

    func testReadMediaCountersFromInstalledIPad() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["DESKLINK_MEDIA_CHECK"] == "counters")
        let host = try XCTUnwrap(environment["DESKLINK_MAC_TEST_HOST"])
        let app = XCUIApplication(bundleIdentifier: "local.nikey.desklink")
        app.activate()
        let done = app.buttons["details.done"]
        if done.isHittable { done.tap() }
        let info = app.buttons["session.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        guard let name = info.value as? String, name.localizedCaseInsensitiveContains(host) else {
            return XCTFail("The connected session must be the selected Mac")
        }
        info.tap()
        defer { if app.buttons["details.done"].isHittable { app.buttons["details.done"].tap() } }
        func row(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "details." + name).firstMatch
        }
        let codec = row("encoding")
        XCTAssertTrue(codec.waitForExistence(timeout: 10))
        let decoded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in codec.value as? String == "HEVC" }, object: nil)
        let codecResult = XCTWaiter.wait(for: [decoded], timeout: 15)
        print("Media encoding=\(codec.value as? String ?? "-") transport=\(row("encryption").value as? String ?? "-") dimensions=\(row("dimensions").value as? String ?? "-")")
        guard codecResult == .completed else { return XCTFail("The selected session did not confirm decoded HEVC video") }
        for metric in ["frames", "audio"] {
            let item = row(metric)
            let positive = NSPredicate { _, _ in (Int(item.value as? String ?? "") ?? 0) > 0 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: positive, object: nil)], timeout: 15), .completed, metric)
            print("Media \(metric)=\(item.value as? String ?? "-")")
        }
    }

    func testTapAndTypeIntoConsentingMacTestWindow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKLINK_CHECK_MAC_WINDOW"] == "1",
                          "Select the physical Mac test window before running this acceptance test")
        let app = XCUIApplication(bundleIdentifier: "local.nikey.desklink")
        app.activate()
        let mode = app.buttons["session.mode"]
        guard mode.waitForExistence(timeout: 12), mode.label == "控制" else {
            return XCTFail("The physical iPad needs a signed-in control session")
        }
        guard let initial = try await waitForPanel(in: app, matching: { _ in true }) else {
            return XCTFail("Both test controls must be visible on the remote Mac")
        }
        tap(initial.button, in: app)
        guard let clicked = try await waitForPanel(in: app, matching: {
            $0.challenge == initial.challenge && $0.clicks > initial.clicks
        }) else { return XCTFail("The remote Mac did not acknowledge the iPad tap") }

        tap(clicked.focusInput, in: app)
        guard try await waitForPanel(in: app, matching: {
            $0.challenge == initial.challenge && !$0.accepted && $0.focusCount > clicked.focusCount
        }) != nil else { return XCTFail("The active Mac test window is no longer visible") }
        let keyboard = app.buttons["toolbar.keyboard"]
        if app.keyboards.count == 0, keyboard.isHittable { keyboard.tap() }
        app.typeText(initial.challenge)
        if app.keyboards.count > 0, keyboard.isHittable { keyboard.tap() }
        let matched = try await waitForPanel(in: app, matching: {
            $0.challenge == initial.challenge && $0.accepted
        })
        XCTAssertNotNil(matched, "The remote Mac must receive the exact synthetic keyboard challenge")
    }

    private struct Panel {
        let challenge: String
        let clicks: Int
        let accepted: Bool
        let focusCount: Int
        let button: Target
        let focusInput: Target
    }

    private struct Target {
        let desktop: CGSize
        let center: CGPoint
        let imageCenter: CGPoint
    }

    private func panel(in app: XCUIApplication) throws -> Panel? {
        try autoreleasepool {
            guard let frame = XCUIScreen.main.screenshot().image.cgImage else { return nil }
            let read = VNDetectBarcodesRequest()
            read.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: frame, orientation: .up).perform([read])
            var targets: [String: [String: Target]] = [:]
            for row in read.results ?? [] {
                guard let code = row.payloadStringValue, code.hasPrefix("DL-M4/") else { continue }
                let parts = code.components(separatedBy: "/")
                guard parts.count == 10,
                      parts[1] == ProcessInfo.processInfo.environment["DESKLINK_PANEL_CHALLENGE"],
                      parts[1].range(of: #"^PAD-[0-9A-F]{4}$"#, options: .regularExpression) != nil,
                      ["T", "K"].contains(parts[2]), let clicks = Int(parts[3]), clicks >= 0,
                      ["0", "1"].contains(parts[4]), let focusCount = Int(parts[5]), focusCount >= 0,
                      let width = Int(parts[6]), let height = Int(parts[7]), width > 0, height > 0,
                      let x = Int(parts[8]), let y = Int(parts[9]), (0..<width).contains(x),
                      (0..<height).contains(y) else { continue }
                let key = [parts[1], parts[3], parts[4], parts[5], parts[6], parts[7]].joined(separator: "/")
                let point = CGPoint(x: row.boundingBox.midX, y: 1 - row.boundingBox.midY)
                targets[key, default: [:]][parts[2]] = Target(desktop: CGSize(width: width, height: height),
                                                              center: CGPoint(x: x, y: y), imageCenter: point)
                if let button = targets[key]?["T"], let field = targets[key]?["K"],
                   field.center.x > button.center.x, abs(field.center.y - button.center.y) < 5 {
                    // XCTest can return an upright portrait raster for a landscape app.
                    // The two marks are horizontally ordered on the Mac, so their positions
                    // resolve the raster orientation without relying on device metadata.
                    let dx = field.imageCenter.x - button.imageCenter.x
                    let dy = field.imageCenter.y - button.imageCenter.y
                    guard max(abs(dx), abs(dy)) > 0.02,
                          min(abs(dx), abs(dy)) < max(abs(dx), abs(dy)) * 0.15 else { continue }
                    func oriented(_ target: Target) -> Target {
                        let p = target.imageCenter
                        let center: CGPoint
                        if abs(dx) > abs(dy) {
                            center = dx > 0 ? p : CGPoint(x: 1 - p.x, y: 1 - p.y)
                        } else {
                            center = dy > 0 ? CGPoint(x: p.y, y: 1 - p.x) : CGPoint(x: 1 - p.y, y: p.x)
                        }
                        return Target(desktop: target.desktop, center: target.center, imageCenter: center)
                    }
                    return Panel(challenge: parts[1], clicks: clicks, accepted: parts[4] == "1", focusCount: focusCount,
                                 button: oriented(button), focusInput: oriented(field))
                }
            }
            return nil
        }
    }

    private func waitForPanel(in app: XCUIApplication, matching: (Panel) -> Bool) async throws -> Panel? {
        let deadline = ContinuousClock.now + .seconds(12)
        repeat {
            if let panel = try panel(in: app), matching(panel) { return panel }
            try await Task.sleep(for: .milliseconds(300))
        } while ContinuousClock.now < deadline
        return nil
    }

    /// Uses the marks as rendered, including any zoom, pan, or letterboxing on this iPad.
    private func tap(_ target: Target, in app: XCUIApplication) {
        let bounds = app.frame
        let p = target.imageCenter
        let top = app.buttons["session.mode"].frame.maxY
        let bottom = app.buttons["toolbar.keyboard"].frame.minY
        guard bounds.origin == .zero, bounds.width > 0, (0..<1).contains(p.x),
              p.y * bounds.height > top, p.y * bounds.height < bottom else {
            return XCTFail("The generated marker is outside the fullscreen app’s desktop")
        }
        let normalized = CGVector(dx: p.x, dy: p.y)
        print("Fixture desktop=\(target.desktop) remote=\(target.center) app=\(bounds) marker=\(p)")
        app.coordinate(withNormalizedOffset: normalized).tap()
    }

}
#endif
