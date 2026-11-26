#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
import UIKit
import Vision
import XCTest

/// Drives the installed viewer only when the live Finder sample and both calibration marks are visible.
@MainActor final class FinderTransferUITests: XCTestCase {
    func testDragIdentifiedFinderFileToTheViewerDownloadTarget() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["DESKLINK_FINDER_TAG"] != nil, "Requires a prepared Finder fixture on the connected Mac.")
        let tag = try XCTUnwrap(env["DESKLINK_FINDER_TAG"].flatMap {
            $0.range(of: #"^[A-F0-9]{8}$"#, options: .regularExpression) == nil ? nil : $0
        })
        let width = try XCTUnwrap(env["DESKLINK_FINDER_WIDTH"].flatMap(Double.init))
        let height = try XCTUnwrap(env["DESKLINK_FINDER_HEIGHT"].flatMap(Double.init))
        let app = XCUIApplication(bundleIdentifier: "local.nikey.desklink")
        guard app.state != .notRunning else { throw XCTSkip("The signed-in viewer is required.") }
        app.activate()
        let mode = app.buttons["session.mode"]
        guard mode.waitForExistence(timeout: 6), ["控制", "Control"].contains(mode.label) else {
            return XCTFail("An active desktop in control mode is required")
        }
        let labels = Set(["L" + tag, "R" + tag, "F" + tag])
        var marks: [String: CGPoint] = [:]
        let deadline = Date().addingTimeInterval(14)
        repeat {
            marks = try autoreleasepool {
                let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
                let qr = VNDetectBarcodesRequest()
                qr.symbologies = [.qr]
                try VNImageRequestHandler(cgImage: image).perform([qr])
                var found: [String: CGPoint] = [:]
                for row in qr.results ?? [] {
                    guard let code = row.payloadStringValue, labels.contains(code) else { continue }
                    found[code] = CGPoint(x: row.boundingBox.midX, y: 1 - row.boundingBox.midY)
                }
                return found
            }
            if marks.count < 3 { try await Task.sleep(for: .milliseconds(250)) }
        } while marks.count < 3 && Date() < deadline
        guard let l = marks["L" + tag], let r = marks["R" + tag], let f = marks["F" + tag] else {
            return XCTFail("Required marks not all visible. Found " + marks.keys.sorted().joined(separator: ", "))
        }
        let dx = r.x - l.x, dy = r.y - l.y
        guard max(abs(dx), abs(dy)) > 0.13, min(abs(dx), abs(dy)) < 0.03 else { return XCTFail("Unexpected marker geometry") }
        let bounds = app.frame
        guard bounds.origin == .zero else { return XCTFail("Use the full-screen viewer for this gesture") }
        func mapped(_ point: CGPoint) -> CGPoint {
            let p: CGPoint
            if abs(dx) > abs(dy) {
                p = dx > 0 ? point : CGPoint(x: 1-point.x, y: 1-point.y)
            } else {
                p = dy > 0 ? CGPoint(x: point.y, y: 1-point.x) : CGPoint(x: 1-point.y, y: point.x)
            }
            return CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
        }
        let left = mapped(l), right = mapped(r), file = mapped(f)
        let desktopWidth = (right.x - left.x) / 0.70
        let visibleTop = max(mode.frame.maxY, left.y - 0.10 * desktopWidth * height / width)
        let minX = max(bounds.minX, left.x - 0.15 * desktopWidth)
        let maxX = min(bounds.maxX, right.x + 0.15 * desktopWidth)
        let halfWidth = min(130, (maxX - minX - 16) / 2)
        let drop = CGPoint(x: min(max(file.x, minX + halfWidth + 8), maxX - halfWidth - 8),
                           y: file.y - 72 >= visibleTop + 8 ? file.y - 44 : file.y + 44)
        guard bounds.contains(file), bounds.contains(drop), file.y > mode.frame.maxY else {
            return XCTFail("Fixture or download target outside the visible desktop")
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: file.x, dy: file.y))
        let end = origin.withOffset(CGVector(dx: drop.x, dy: drop.y))
        print("Finder sample \(tag) at \(file), download target \(drop), viewer \(bounds.size)")
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
    }
}
#endif
