import CoreGraphics
import SwiftUI
import UIKit
import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor
final class LinuxDesktopTests: XCTestCase {
    func testWayVNCAuthenticatesWithTLSAndDeliversWaylandKeyboardInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["DESKLINK_WAYLAND_PORT"].flatMap(UInt16.init),
              let expected = environment["DESKLINK_TLS_PIN"] else {
            throw XCTSkip("Requires the isolated WayVNC and Sway desktop.")
        }
        let domain = "DeskLinkWaylandTLS." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let trust = HostTrust(defaults: defaults)
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        var config = computer.configuration
        config.certificateValidationHandler = { await trust.verifyCertificate($0) }
        let session = VNCSession(configuration: config)
        defer { trust.cancel(); session.disconnect() }
        let connection = Task {
            try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port,
                                                                  password: "WaylandFixture42", username: "fixture"))
        }
        defer { connection.cancel() }
        try await waitUntil { trust.prompt != nil || session.lastError != nil }
        let identity = try XCTUnwrap(trust.prompt, session.connectionPhaseDescription ?? "")
        XCTAssertEqual(identity.fingerprint, expected)
        trust.answer(identity.fingerprint == expected, remember: false)
        try await connection.value
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 650 || session.lastError != nil }
        XCTAssertNil(session.lastError, "WayVNC closed during initial display")
        XCTAssertEqual(session.currentImage?.width, 800)
        XCTAssertEqual(session.currentImage?.height, 480)
        XCTAssertEqual(session.negotiatedContentEncryption, .tlsX509)
        session.sendKeyEvent(downFlag: true, key: 0xff0d)
        session.sendKeyEvent(downFlag: false, key: 0xff0d)
        try await waitUntil { self.pixels(matching: [52, 174, 146], in: session.currentImage) > 650 }
    }

    private func endpoint() throws -> UInt16 {
        guard let value = ProcessInfo.processInfo.environment["DESKLINK_LINUX_PORT"], let port = UInt16(value), port > 0 else {
            throw XCTSkip("Requires the isolated Alpine TigerVNC desktop on this Mac.")
        }
        return port
    }

    func testTigerVNCRejectsIncorrectPassword() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        do {
            try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "invalid!"))
            XCTFail("The fixture accepted an incorrect password")
        } catch {
            XCTAssertFalse(session.connectionState.isConnected)
            XCTAssertNil(session.currentImage)
        }
    }

    func testTigerVNCRequiresApprovedCertificateBeforePasswordAuthentication() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_TLS_PORT"].flatMap(UInt16.init), let expected = env["DESKLINK_TLS_PIN"] else {
            throw XCTSkip("Requires the disposable TLS TigerVNC desktop.")
        }
        let domain = "DeskLinkTigerTLS." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        for approve in [false, true] {
            let trust = HostTrust(defaults: defaults)
            var config = computer.configuration
            config.certificateValidationHandler = { await trust.verifyCertificate($0) }
            let session = VNCSession(configuration: config)
            defer { trust.cancel(); session.disconnect() }
            let connection = Task { try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!")) }
            defer { connection.cancel() }
            try await waitUntil { trust.prompt != nil || session.lastError != nil }
            let identity = try XCTUnwrap(trust.prompt)
            XCTAssertEqual(identity.kind, .tls)
            XCTAssertEqual(identity.fingerprint, expected)
            trust.answer(approve && identity.fingerprint == expected, remember: false)
            if approve {
                try await connection.value
                try await waitUntil { session.currentImage?.width == 320 }
                XCTAssertEqual(session.currentImage?.height, 200)
            } else {
                do { try await connection.value; XCTFail("The rejected certificate opened a desktop") } catch {}
                XCTAssertNil(session.currentImage)
            }
            XCTAssertNil(defaults.string(forKey: "tls.trusted.127.0.0.1:\(port)"))
        }
    }

    func testTigerVNCAuthenticatesAndReceivesInputInLinuxWindow() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 380 }
        XCTAssertEqual(session.currentImage?.width, 800)
        XCTAssertEqual(session.currentImage?.height, 480)
        XCTAssertGreaterThan(pixels(matching: [241, 183, 69], in: session.currentImage), 40)
        session.sendKeyEvent(downFlag: true, key: 0xff0d)
        session.sendKeyEvent(downFlag: false, key: 0xff0d)
        try await waitUntil { self.pixels(matching: [52, 174, 146], in: session.currentImage) > 800 }
    }

    func testTigerVNCManualReconnectReauthenticatesAndRestoresInput() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        var configuration = computer.configuration
        configuration.reconnectionPolicy.isEnabled = false
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
        try await waitUntil { session.supportsRemoteClipboardRequest && session.currentImage != nil }
        session.sendClipboardText("DeskLink reconnect fixture")
        await session.flushPendingInput()
        try await waitUntil { session.connectionState.canConnect }
        XCTAssertTrue(session.retryConnection())
        try await waitUntil {
            session.connectionState.isConnected && self.pixels(matching: [241, 183, 69], in: session.currentImage) > 40
        }
        session.sendKeyEvent(downFlag: true, key: 0xff0d)
        session.sendKeyEvent(downFlag: false, key: 0xff0d)
        try await waitUntil { self.pixels(matching: [52, 174, 146], in: session.currentImage) > 800 }
        session.disconnect()
        XCTAssertFalse(session.retryConnection())
    }

    func testTigerVNCStandardColorDepths() async throws {
        let port = try endpoint()
        for depth in [ColorDepth.low, .medium] {
            var computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
            computer.colorDepth = depth
            let configuration = computer.configuration
            XCTAssertEqual(configuration.preferredPixelFormat?.bytesPerPixel, depth.rawValue / 8)
            let session = VNCSession(configuration: configuration)
            defer { session.disconnect() }
            try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
            // The X11 fixture has a blue window or green background, depending
            // on when the separate input test sent Return.
            let colors = depth == .low ? [[36, 73, 170], [36, 182, 170]] : [[31, 89, 165], [52, 174, 146]]
            try await waitUntil { colors.contains { self.pixels(matching: $0, in: session.currentImage) > 380 } }
            XCTAssertEqual(session.currentImage?.width, 800)
            XCTAssertEqual(session.currentImage?.height, 480)
        }
    }

    func testTigerVNCResizesTheRemoteX11DesktopAsTheClientWindowChanges() async throws {
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_RESIZE_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the isolated TigerVNC resize desktop.")
        }
        var computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        var display = computer.display(for: .current)
        display.quality = .adaptive
        display.smoothVideo = false
        display.retinaResolution = false
        display.matchWindow = true
        computer.setDisplay(display, for: .current)
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
        try await waitUntil { session.currentImage?.width == 800 }
        for size in [CGSize(width: 1024, height: 640), CGSize(width: 1280, height: 800), CGSize(width: 400, height: 240)] {
            if size.width == 400 { session.configuration.fixedDesktopSize = size }
            session.updateRemoteDisplaySize(viewSize: size, displayScale: 2)
            try await waitUntil {
                session.currentImage?.width == Int(size.width * 2) && session.currentImage?.height == Int(size.height * 2) &&
                    self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300
            }
            // Allow the independent X11 geometry sampler to observe this size before the next request.
            try await Task.sleep(for: .milliseconds(350))
        }
    }

    func testTigerVNCReceivesCommittedMultilingualTextFromTheDesktopInputView() async throws {
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_RESIZE_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the isolated X11 text terminal.")
        }
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RemoteDesktopView(session: session))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func inputView(in view: UIView) -> (any UIKeyInput)? {
            if view.accessibilityIdentifier == "session.input" { return view as? any UIKeyInput }
            for child in view.subviews {
                if let input = inputView(in: child) { return input }
            }
            return nil
        }
        try await waitUntil { inputView(in: host.view) != nil }
        let input = try XCTUnwrap(inputView(in: host.view))
        input.insertText("DeskLink ")
        #if targetEnvironment(macCatalyst)
        input.insertText("中文")
        #else
        let composition = try XCTUnwrap(input as? any UITextInput)
        composition.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0))
        composition.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        composition.unmarkText()
        #endif
        input.insertText(" cafe\u{301} Ω 🙂")
        input.insertText("\n")
        // The terminal changes the X11 background only after its UTF-8 input matches byte for byte.
        try await waitUntil { self.pixels(matching: [194, 54, 132], in: session.currentImage) > 300 }
    }

    func testTigerVNCUnicodeClipboardRoundTripFromX11() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        var remoteText: String?
        session.onServerClipboardText = { remoteText = $0 }
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
        try await waitUntil { session.currentImage != nil && session.supportsRemoteClipboardRequest }
        session.sendClipboardText("DeskLink X11 收到 Ω")
        await session.flushPendingInput()
        // The guest responds only after an independent xclip process reads
        // the expected UTF-8 text from the X11 CLIPBOARD selection.
        let deadline = Date().addingTimeInterval(12)
        while remoteText != "X11 已回传 ✓", Date() < deadline {
            session.requestRemoteClipboard()
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(remoteText, "X11 已回传 ✓")
    }

    func testTigerVNCAutomaticClipboardExchangesAnIsolatedSystemPasteboardWithX11() async throws {
        let port = try endpoint()
        let name = UIPasteboard.Name("local.nikey.desklink.tests." + UUID().uuidString)
        let board = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: "Chart42!"))
        try await waitUntil { session.currentImage != nil && session.supportsRemoteClipboardRequest }
        let synchronizer = VNCClipboardSynchronizer(session: session, pasteboard: board)
        defer { synchronizer.invalidate() }
        synchronizer.setHostWindowActive(true)
        synchronizer.sharedClipboardEnabled = true
        board.string = "DeskLink 自动同步 Ω"
        try await waitUntil { board.string == "X11 自动回传 ✓" }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(70)) }
        guard condition() else { throw URLError(.timedOut) }
    }

    private func pixels(matching color: [Int], in image: CGImage?) -> Int {
        guard let image else { return 0 }
        let width = 40, height = 24
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter { start in
                (0..<3).allSatisfy { abs(Int(pixels[start + $0]) - color[$0]) < 18 }
            }.count
        }
    }
}
