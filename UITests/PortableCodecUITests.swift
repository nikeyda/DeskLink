#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class PortableCodecUITests: XCTestCase {
    func testDisabledCodecsAreOmittedFromTheWireAndRawStillDisplays() async throws {
        let peer = LocalTestDisplay()
        let port = try await peer.start()
        defer { peer.stop() }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 10))

        let display = app.buttons["显示器"].firstMatch
        for _ in 0..<5 where !display.isHittable { app.swipeUp() }
        display.tap()
        let encodings = app.buttons["VNC 编码"].firstMatch
        for _ in 0..<4 where !encodings.isHittable { app.swipeUp() }
        encodings.tap()
        for code in [7, 16, -239, 0] {
            let toggle = app.switches["connection.codec.\(code)"].firstMatch
            for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
            XCTAssertEqual(toggle.value as? String, "1")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, "0")
        }
        submit.tap()
        let deadline = ContinuousClock.now + .seconds(12)
        while peer.frameCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(peer.frameCount, 0)
        let advertised = Set(peer.advertisedEncodings)
        XCTAssertTrue(advertised.isDisjoint(with: [7, 16, -239, -240, 0, -28]))
        XCTAssertTrue(advertised.isSuperset(of: [-224, 6, 1, -223, -308]))
        XCTAssertNil(peer.failure)
        let presentationDeadline = ContinuousClock.now + .seconds(10)
        repeat {
            let screenshot = XCUIScreen.main.screenshot()
            if showsTestDisplay(screenshot.image.cgImage) {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "Remote frame after disabling explicit Raw advertisement"
                attachment.lifetime = .keepAlways
                add(attachment)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < presentationDeadline
        XCTFail("The remote color chart was not presented")
    }

    private func showsTestDisplay(_ image: CGImage?) -> Bool {
        guard let image,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        let samples: [(Double, Double, [Int])] = [(0.25, 0.42, [31, 89, 165]), (0.75, 0.58, [223, 102, 88])]
        for (x, y, expected) in samples {
            let rect = CGRect(x: Int(x * Double(image.width)), y: Int(y * Double(image.height)), width: 1, height: 1)
            guard let pixel = image.cropping(to: rect) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard (0..<3).allSatisfy({ abs(Int(buffer[$0]) - expected[$0]) <= 8 }) else { return false }
        }
        return true
    }
}
#endif
