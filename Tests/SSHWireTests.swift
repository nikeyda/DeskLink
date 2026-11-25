import XCTest
import NIOSSH
import Security
import rootshellVNC
@testable import DeskLink

@MainActor
final class SSHWireTests: XCTestCase {
    private struct GeneratedKey: Decodable {
        let key: String
        let `public`: String
    }

    func testPassphraseProtectedKeysAndPublicKeyLogin() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let encoded = env["DESKLINK_KEY_FIXTURES"], let data = Data(base64Encoded: encoded),
              let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires fresh encrypted identities from the loopback SSH test peer.")
        }
        let fixtures = try JSONDecoder().decode([GeneratedKey].self, from: data)
        XCTAssertEqual(fixtures.count, 4)
        let first = try XCTUnwrap(fixtures.first)
        XCTAssertThrowsError(try SSHKeyFile.opened(first.key)) { XCTAssertEqual(($0 as NSError).code, Int(errSecPassphraseRequired)) }
        XCTAssertThrowsError(try SSHKeyFile.opened(first.key, passphrase: "invalid")) {
            XCTAssertEqual(($0 as NSError).code, Int(errSecAuthFailed))
        }
        var opened: [NIOSSHPrivateKey] = []
        for item in fixtures {
            let material = try SSHKeyFile.opened(item.key, passphrase: "chart-key-phrase")
            let key = try SSHKeyFile.identity(material)
            XCTAssertEqual(String(openSSHPublicKey: key.publicKey), item.public)
            opened.append(key)
        }
        let login = try XCTUnwrap(opened.first)
        let domain = "DeskLinkKeyLogin." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let trust = HostTrust(defaults: defaults)
        let settings = SSHSettings(port: port, username: "fixture-key", usesKey: true)
        var config = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        config.transportProvider = { host, desktopPort in
            DesktopSSH(host: host, desktopPort: desktopPort, settings: settings, proof: .privateKey(login), trust: trust)
        }
        let session = VNCSession(configuration: config)
        defer { trust.cancel(); session.disconnect() }
        let attempt = Task { try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", password: "")) }
        defer { attempt.cancel() }
        try await until { trust.prompt != nil }
        let matches = trust.prompt?.fingerprint == pin
        trust.answer(matches)
        XCTAssertTrue(matches)
        try await attempt.value
        try await until { session.currentImage?.width == 320 }
    }

    func testSeparateSSHServerUsesItsOwnFingerprintAndTheSelectedDesktop() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires the loopback SSH fixture")
        }
        let suite = "DeskLinkSSHServer." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = HostTrust(defaults: defaults)
        let settings = SSHSettings(port: port, username: "fixture", usesKey: false, server: "127.0.0.1")
        var config = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        config.transportProvider = { host, port in
            DesktopSSH(host: host, desktopPort: port, settings: settings, proof: .password("chart-test-only"), trust: trust)
        }
        let session = VNCSession(configuration: config)
        defer { trust.cancel(); session.disconnect() }
        let connection = Task {
            try await session.connect(credentials: .init(host: "chart.fixture.invalid", port: 5917, password: ""))
        }
        defer { connection.cancel() }
        try await until { trust.prompt != nil }
        let matches = trust.prompt?.host == "127.0.0.1:\(port)" && trust.prompt?.fingerprint == pin
        trust.answer(matches)
        XCTAssertTrue(matches)
        try await connection.value
        try await until { session.currentImage?.width == 320 }
        XCTAssertEqual(session.currentImage?.height, 192)
    }

    func testIndependentSSHPeerDeliversFramebuffer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires the loopback peer from script/ssh_test_desktop.py")
        }
        let domain = "DeskLinkSSHWire." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let trust = HostTrust(defaults: defaults)
        let settings = SSHSettings(port: port, username: "fixture", usesKey: false)
        var config = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        config.transportProvider = { host, desktopPort in
            DesktopSSH(host: host, desktopPort: desktopPort, settings: settings, proof: .password("chart-test-only"), trust: trust)
        }
        let session = VNCSession(configuration: config)
        var remoteText: String?
        session.onServerClipboardText = { remoteText = $0 }
        defer { trust.cancel(); session.disconnect() }
        let task = Task { try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", password: "")) }
        defer { task.cancel() }
        try await until { trust.prompt != nil || session.connectionState.canConnect && session.connectionState != .idle }
        XCTAssertEqual(trust.prompt?.fingerprint, pin)
        guard trust.prompt?.fingerprint == pin else { trust.answer(false); return }
        trust.answer(true)
        try await until { session.hasPresentedStandardPicture || session.lastError != nil }
        try await task.value
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertEqual(session.currentImage?.width, 320)
        XCTAssertEqual(session.currentImage?.height, 192)
        try await until { remoteText != nil }
        XCTAssertEqual(remoteText, "DeskLink clipboard fixture")
        session.sendClipboardText("DeskLink clipboard fixture")
        // The independent peer echoes only this exact generated test value.
        try await until { remoteText == "DeskLink clipboard receipt" }
        VNCDisconnectAction.bottomRight.send(to: session)
        await session.flushPendingInput()
        try await until { remoteText == "DeskLink corner receipt" }
        VNCDisconnectAction.controlAltDelete.send(to: session)
        await session.flushPendingInput()
        try await until { remoteText == "DeskLink chord receipt" }
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        guard predicate() else { throw URLError(.timedOut) }
    }
}
