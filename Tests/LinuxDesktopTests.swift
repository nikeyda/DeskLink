import CoreGraphics
import CryptoKit
import RFBProtocol
import Speech
import SwiftUI
import UIKit
import XCTest
@testable import rootshellVNC
@testable import DeskLink

@MainActor
final class LinuxDesktopTests: XCTestCase {
    private var peerHost: String {
        ProcessInfo.processInfo.environment["DESKLINK_LINUX_HOST"] ?? "127.0.0.1"
    }

    func testRSAAESHostApprovalPasswordAndEncryptedDesktopInput() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_RSA_PORT"].flatMap(UInt16.init),
              let expectedPin = env["DESKLINK_RSA_PIN"],
              let bits = env["DESKLINK_RSA_BITS"].flatMap(Int.init) else {
            throw XCTSkip("Requires a TigerVNC RSA-AES fixture.")
        }
        let account = env["DESKLINK_RSA_ACCOUNT"] == "1"
        let validPassword = account ? "FixtureAccount71!" : "Chart42!"
        let domain = "DeskLinkRSA." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        computer.usesRaspberryPiRSAAES = account
        let pinKey = "rsa.trusted.\(peerHost):\(port)"
        // First reject the host. Then pin it and verify the server checks the
        // supplied password. A final connection must use the saved identity.
        for step in 0...3 {
            if step == 3 { defaults.set("SHA256:other-test-server", forKey: pinKey) }
            let trust = HostTrust(defaults: defaults)
            var config = computer.configuration
            config.reconnectionPolicy.isEnabled = false
            config.rsaHostValidationHandler = { host, port, pin in
                await trust.verify(host: host, port: port, fingerprint: pin, kind: .rsa)
            }
            let session = VNCSession(configuration: config)
            defer { trust.cancel(); session.disconnect() }
            let connection = Task {
                try await session.connect(credentials: VNCCredentials(host: peerHost, port: port,
                    password: step == 1 ? "wrong test password" : validPassword, username: account ? "chartuser" : ""))
            }
            defer { connection.cancel() }
            if step < 2 {
                try await waitUntil { trust.prompt != nil || session.lastError != nil }
                let identity = try XCTUnwrap(trust.prompt, session.lastError?.localizedDescription ?? "Missing RSA identity")
                XCTAssertEqual(identity.kind, .rsa)
                XCTAssertEqual(identity.fingerprint, expectedPin)
                trust.answer(step == 1 && identity.fingerprint == expectedPin, remember: true)
            }
            if step != 2 {
                do { try await connection.value; XCTFail("Unexpected RSA-AES login at step \(step)") }
                catch {
                    guard case .authenticationFailed(let reason) = (error as? VNCProtocolError) ?? session.lastError else {
                        return XCTFail("Unexpected failure at step \(step): \(error)")
                    }
                    if step == 1 { XCTAssertFalse(reason.contains("host key"), reason) }
                    else { XCTAssertTrue(reason.contains("host key"), reason) }
                }
                XCTAssertNil(session.currentImage)
                if step == 0 { XCTAssertNil(defaults.string(forKey: pinKey)) }
                continue
            }
            XCTAssertEqual(defaults.string(forKey: pinKey), expectedPin)
            try await connection.value
            try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 650 }
            XCTAssertEqual(session.currentImage?.width, 800)
            XCTAssertEqual(session.currentImage?.height, 480)
            XCTAssertEqual(session.negotiatedContentEncryption, .rsaAES(bits: bits))
            for key in Array("count".utf8).map(UInt32.init) + [0xff0d] {
                session.sendKeyEvent(downFlag: true, key: key)
                session.sendKeyEvent(downFlag: false, key: key)
            }
            try await waitUntil { self.pixels(matching: [255, 0, 0], in: session.currentImage) > 650 }
        }
    }

    func testWayVNCAuthenticatesWithTLSAndDeliversWaylandKeyboardInput() async throws {
        try await assertWaylandDesktopLogin(expectsRSA: false)
    }

    func testRaspberryPiAuthenticatesTheDesktopAccountAndReceivesReturn() async throws {
        guard ProcessInfo.processInfo.environment["DESKLINK_TEST_PI_DESKTOP_ACCOUNT"] == "1" else {
            throw XCTSkip("Requires the official Raspberry Pi OS desktop.")
        }
        try await assertWaylandDesktopLogin(expectsRSA: true)
    }

    private func assertWaylandDesktopLogin(expectsRSA: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["DESKLINK_WAYLAND_PORT"].flatMap(UInt16.init),
              let expected = environment[expectsRSA ? "DESKLINK_RSA_PIN" : "DESKLINK_TLS_PIN"] else {
            throw XCTSkip("Requires the isolated WayVNC desktop.")
        }
        let domain = "DeskLinkWaylandTLS." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let trust = HostTrust(defaults: defaults)
        var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        computer.usesRaspberryPiRSAAES = expectsRSA
        var config = computer.configuration
        config.certificateValidationHandler = { await trust.verifyCertificate($0) }
        config.rsaHostValidationHandler = { host, port, fingerprint in
            await trust.verify(host: host, port: port, fingerprint: fingerprint, kind: .rsa)
        }
        let session = VNCSession(configuration: config)
        defer { trust.cancel(); session.disconnect() }
        let connection = Task {
            try await session.connect(credentials: VNCCredentials(host: peerHost, port: port,
                                                                  password: "WaylandFixture42", username: "fixture"))
        }
        defer { connection.cancel() }
        try await waitUntil { trust.prompt != nil || session.lastError != nil }
        let identity = try XCTUnwrap(trust.prompt, session.lastError?.localizedDescription ?? session.connectionPhaseDescription ?? "")
        XCTAssertEqual(identity.fingerprint, expected)
        trust.answer(identity.fingerprint == expected, remember: false)
        try await connection.value
        let blue = [31, 89, 165]
        let green = [52, 174, 146]
        let toggles = environment["DESKLINK_TEST_PI_DESKTOP_ACCOUNT"] == "1"
        try await waitUntil {
            self.pixels(matching: blue, in: session.currentImage) > 650 ||
                (toggles && self.pixels(matching: green, in: session.currentImage) > 650) || session.lastError != nil
        }
        let afterReturn = self.pixels(matching: blue, in: session.currentImage) > 650 ? green : blue
        XCTAssertNil(session.lastError, "WayVNC closed during initial display")
        XCTAssertEqual(session.currentImage?.width, 800)
        XCTAssertEqual(session.currentImage?.height, 480)
        XCTAssertEqual(session.negotiatedContentEncryption, expectsRSA ? .rsaAES(bits: 256) : .tlsX509)
        session.sendKeyEvent(downFlag: true, key: 0xff0d)
        session.sendKeyEvent(downFlag: false, key: 0xff0d)
        try await waitUntil { self.pixels(matching: afterReturn, in: session.currentImage) > 650 }
    }

    func testWayVNCRejectsAnIncorrectPasswordForTheFixtureAccount() async throws {
        try await assertWayVNCRejects(username: "fixture", password: "Incorrect-fixture")
    }

    func testRaspberryPiRequiresTheActiveDesktopAccount() async throws {
        guard ProcessInfo.processInfo.environment["DESKLINK_TEST_PI_DESKTOP_ACCOUNT"] == "1" else {
            throw XCTSkip("Requires the official Raspberry Pi OS active desktop account fixture.")
        }
        // The second account has a valid system password and no graphical login.
        try await assertWayVNCRejects(username: "deskother", password: "OtherFixture72!")
    }

    private func assertWayVNCRejects(username: String, password: String) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_WAYLAND_PORT"].flatMap(UInt16.init), let expected = env["DESKLINK_TLS_PIN"] else {
            throw XCTSkip("Requires the isolated WayVNC desktop.")
        }
        let confirmed = expectation(description: "The fixture host identity was verified before credentials")
        var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        computer.usesRaspberryPiRSAAES = env["DESKLINK_TEST_PI_DESKTOP_ACCOUNT"] == "1"
        var config = computer.configuration
        config.certificateValidationHandler = { certificate in
            guard let leaf = certificate.certificateChainDER.first else { return .reject }
            let pin = Data(SHA256.hash(data: leaf)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
            guard "SHA256:" + pin == expected else { return .reject }
            confirmed.fulfill()
            return .acceptOnce
        }
        if let rsaPin = env["DESKLINK_RSA_PIN"] {
            config.rsaHostValidationHandler = { _, _, fingerprint in
                guard fingerprint == rsaPin else { return false }
                confirmed.fulfill()
                return true
            }
        }
        let session = VNCSession(configuration: config)
        defer { session.disconnect() }
        do {
            try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: password, username: username))
            XCTFail("WayVNC accepted credentials that should be rejected")
        } catch {
            guard case .authenticationFailed = (error as? VNCProtocolError) ?? session.lastError else {
                return XCTFail("Expected an authentication rejection from the fixture, received \(error)")
            }
            await fulfillment(of: [confirmed], timeout: 2)
            XCTAssertFalse(session.connectionState.isConnected)
            XCTAssertNil(session.currentImage)
        }
    }

    private func endpoint() throws -> UInt16 {
        guard let value = ProcessInfo.processInfo.environment["DESKLINK_LINUX_PORT"], let port = UInt16(value), port > 0 else {
            throw XCTSkip("Requires the isolated Alpine TigerVNC desktop on this Mac.")
        }
        return port
    }

    func testTigerVNCRejectsIncorrectPassword() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        do {
            try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "invalid!"))
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
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        for approve in [false, true] {
            let trust = HostTrust(defaults: defaults)
            var config = computer.configuration
            config.certificateValidationHandler = { await trust.verifyCertificate($0) }
            let session = VNCSession(configuration: config)
            defer { trust.cancel(); session.disconnect() }
            let connection = Task { try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!")) }
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
            XCTAssertNil(defaults.string(forKey: "tls.trusted.\(peerHost):\(port)"))
        }
    }

    func testTigerVNCAuthenticatesAndReceivesInputInLinuxWindow() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let seconds = ProcessInfo.processInfo.environment["DESKLINK_LINUX_SOAK_SECONDS"].flatMap(UInt32.init) ?? 0
        var configuration = computer.configuration
        if seconds > 0 { configuration.reconnectionPolicy.isEnabled = false }
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
        let keyboard = RemoteDesktopView(session: session).keyboardHandler
        XCTAssertFalse(keyboard.forwardsPhysicalKey(usage: 0x28))
        let input = HardwareKeyboardController(keyboardHandler: keyboard)
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + .seconds(Int(seconds))
        var probes = 0
        while true {
            try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 380 }
            XCTAssertEqual(session.currentImage?.width, 800)
            XCTAssertEqual(session.currentImage?.height, 480)
            XCTAssertGreaterThan(pixels(matching: [241, 183, 69], in: session.currentImage), 40)
            XCTAssertTrue(input.press(usage: 0x28, keysym: KeyboardInputHandler.keysymReturn))
            XCTAssertTrue(input.release(usage: 0x28))
            try await waitUntil { self.pixels(matching: [52, 174, 146], in: session.currentImage) > 800 }
            probes += 1
            if clock.now >= deadline { break }
            try await clock.sleep(until: min(deadline, clock.now + .seconds(30)))
        }
        if seconds > 0 {
            let statistics = await session.currentStatistics()
            let updates = try XCTUnwrap(statistics?.transport.framebufferUpdateCount)
            XCTAssertGreaterThanOrEqual(updates, UInt64(probes))
            XCTAssertFalse(session.configuration.reconnectionPolicy.isEnabled)
            let receipt = XCTAttachment(string: "elapsedSeconds=\(start.duration(to: clock.now).components.seconds) confirmedInputProbes=\(probes) framebufferUpdates=\(updates)")
            receipt.name = "Sustained Linux desktop session"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
    }

    func testTigerVNCManualReconnectReauthenticatesAndRestoresInput() async throws {
        let port = try endpoint()
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        var configuration = computer.configuration
        configuration.reconnectionPolicy.isEnabled = false
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
        try await waitUntil { session.supportsRemoteClipboardRequest && session.currentImage != nil }
        XCTAssertNil(session.lastReconnectTrigger)
        session.sendClipboardText("DeskLink reconnect fixture")
        await session.flushPendingInput()
        try await waitUntil { session.connectionState.canConnect }
        XCTAssertTrue(session.retryConnection())
        try await waitUntil {
            session.connectionState.isConnected && self.pixels(matching: [241, 183, 69], in: session.currentImage) > 40
        }
        let report = await ConnectionReport.capture(session: session, usesSSH: false, id: UUID(), startedAt: .now)
        XCTAssertEqual(report?.reconnectTrigger, .manual)
        session.sendKeyEvent(downFlag: true, key: 0xff0d)
        session.sendKeyEvent(downFlag: false, key: 0xff0d)
        try await waitUntil { self.pixels(matching: [52, 174, 146], in: session.currentImage) > 800 }
        session.disconnect()
        XCTAssertFalse(session.retryConnection())
    }

    func testTigerVNCStandardColorDepths() async throws {
        let port = try endpoint()
        for depth in [ColorDepth.low, .medium] {
            var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
            computer.colorDepth = depth
            let configuration = computer.configuration
            XCTAssertEqual(configuration.preferredPixelFormat?.bytesPerPixel, depth.rawValue / 8)
            let session = VNCSession(configuration: configuration)
            defer { session.disconnect() }
            try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
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
        var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        var display = computer.display(for: .current)
        display.quality = .adaptive
        display.smoothVideo = false
        display.retinaResolution = false
        display.matchWindow = true
        computer.setDisplay(display, for: .current)
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
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

    func testTigerVNCScrollSpeedProducesTheSelectedNumberOfX11WheelEvents() async throws {
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_RESIZE_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the isolated X11 terminal with wheel input reporting.")
        }
        var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
        try await waitUntil { session.currentImage != nil }
        let input = TouchInputHandler(sendPointerEvent: { session.sendPointerEvent(buttonMask: $0, x: $1, y: $2) },
                                      sendScrollEvent: { session.sendScrollEvent($0) })
        func sendLine(_ line: String) {
            for key in line.unicodeScalars.map(\.value) + [0xff0d] {
                session.sendKeyEvent(downFlag: true, key: key)
                session.sendKeyEvent(downFlag: false, key: key)
            }
        }
        let colors: [(RemoteScrollSpeed, [Int])] = [
            (.slow, [190, 80, 150]), (.moderatelySlow, [41, 123, 196]), (.standard, [88, 182, 118]),
            (.moderatelyFast, [145, 165, 73]), (.fast, [221, 117, 64])
        ]
        for (speed, color) in colors {
            computer.pcScrollSpeed = speed
            let actual = computer.scrollSpeed(forMac: session.serverUsesAppleModifierConvention)
            sendLine("reset")
            try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300 }
            var points = ScrollPointAccumulator()
            var wheel = ScrollWheelUnitAccumulator()
            let step = points.consume(CGPoint(x: 0, y: 40), speed: actual)
            let ticks = wheel.consume(pointDeltaX: step.x, pointDeltaY: step.y)
            input.handleScroll(x: 48, y: 35, pointDeltaX: step.x, pointDeltaY: step.y,
                               coarseDeltaX: ticks.x, coarseDeltaY: ticks.y, scrollPhase: .changed)
            sendLine("count")
            try await waitUntil { self.pixels(matching: color, in: session.currentImage) > 300 }
        }
        sendLine("reset")
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300 }
    }

    func testTigerVNCReceivesTheOnDeviceDictationOfTheFixedEnglishRecording() async throws {
        guard #available(iOS 26, macCatalyst 26, *),
              let port = ProcessInfo.processInfo.environment["DESKLINK_RESIZE_PORT"].flatMap(UInt16.init)
        else { throw XCTSkip("Requires on-device speech and the isolated X11 terminal.") }
        let module = try await LocalDictation.module(for: Locale(identifier: "en_US"))
        let installed = await AssetInventory.status(forModules: [module])
        try XCTSkipUnless(installed == .installed, "Requires the installed English dictation resource.")
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "dictation-en", withExtension: "caf") ??
                                    bundle.url(forResource: "dictation-en", withExtension: "caf", subdirectory: "Fixtures"))
        let text = try await LocalDictation.recognize(fixture, using: module)
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300 }
        KeyboardInputHandler { session.sendKeyEvent(downFlag: $0, key: $1) }.typeText(text + "\n")
        try await waitUntil { self.pixels(matching: [40, 155, 182], in: session.currentImage) > 300 }
    }

    private func desktopInput(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == "session.input" { return view }
        for child in view.subviews {
            if let input = desktopInput(in: child) { return input }
        }
        return nil
    }

    func testConnectedDesktopInstallsTheSelectedPinchPolicy() async throws {
        let port = try endpoint()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for allowed in [false, true] {
            var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
            computer.allowsViewportZoom = allowed
            let session = VNCSession(configuration: computer.configuration)
            defer { session.disconnect() }
            try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
            try await waitUntil { session.currentImage != nil }
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: RemoteDesktopView(session: session))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            try await waitUntil { self.desktopInput(in: host.view) != nil }
            let surface = try XCTUnwrap(desktopInput(in: host.view))
            let pinches = (surface.gestureRecognizers ?? []).compactMap { $0 as? UIPinchGestureRecognizer }
            XCTAssertEqual(pinches.map(\.isEnabled), [allowed])
        }
    }

    func testTigerVNCReceivesTheFirstUnicodeWordWithKeyboardCompatibilityEnabled() async throws {
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_RESIZE_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the isolated X11 text terminal.")
        }
        var computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        computer.preparesTigerVNCKeyboard = true
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300 }
        for character in "你好\n" {
            let key = KeyboardInputHandler.keysymForCharacter(character)
            session.sendKeyEvent(downFlag: true, key: key)
            session.sendKeyEvent(downFlag: false, key: key)
        }
        try await waitUntil { self.pixels(matching: [52, 174, 146], in: session.currentImage) > 300 }
    }

    func testTigerVNCReceivesCommittedMultilingualTextFromTheDesktopInputView() async throws {
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_RESIZE_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the isolated X11 text terminal.")
        }
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
        try await waitUntil { self.pixels(matching: [31, 89, 165], in: session.currentImage) > 300 }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: RemoteDesktopView(session: session))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { self.desktopInput(in: host.view) != nil }
        let input = try XCTUnwrap(desktopInput(in: host.view) as? any UIKeyInput)
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
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        var remoteText: String?
        session.onServerClipboardText = { remoteText = $0 }
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
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
        let computer = Computer(endpoint: try Endpoint(address: peerHost, defaultPort: port))
        let session = VNCSession(configuration: computer.configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: VNCCredentials(host: peerHost, port: port, password: "Chart42!"))
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
