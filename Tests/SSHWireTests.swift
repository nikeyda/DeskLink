import XCTest
import RFBTransport
import NIOSSH
import Security
import rootshellVNC
@testable import DeskLink

@MainActor
final class SSHWireTests: XCTestCase {
    private var peerHost: String {
        ProcessInfo.processInfo.environment["DESKLINK_SSH_HOST"] ?? "127.0.0.1"
    }

    private struct GeneratedKey: Decodable {
        let key: String
        let `public`: String
        let pem: [String]?
    }

    func testOnlyAnOptedInLocalSocketBypassesSSH() async throws {
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_LOCAL_ROUTE_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the independent loopback RFB chart.")
        }
        let trust = HostTrust()
        var configuration = VNCConfiguration(videoQualityMode: .adaptive)
        DesktopSSH.configureTransport(&configuration, settings: SSHSettings(), proof: .password("unused-fixture"), trust: trust)
        XCTAssertNil(configuration.preferredLocalConnection)
        let automatic = try await configuration.transportProvider?("127.0.0.1", port)
        XCTAssertTrue(automatic is DesktopSSH)
        var local = VNCConfiguration(videoQualityMode: .adaptive)
        DesktopSSH.configureTransport(&local, settings: SSHSettings(secureLocally: false), proof: nil, trust: trust)
        XCTAssertEqual(local.videoQualityMode, .adaptive)
        let direct = try await local.preferredLocalConnection?("127.0.0.1", port)
        let socket = try XCTUnwrap(direct)
        try await socket.connect()
        let banner = try await socket.read(exactly: 12)
        XCTAssertEqual(banner, Data("RFB 003.008\n".utf8))
        await socket.close()
        XCTAssertNil(trust.prompt)

        var separate = VNCConfiguration()
        let otherHost = SSHSettings(server: "gateway.fixture.invalid", secureLocally: false)
        DesktopSSH.configureTransport(&separate, settings: otherHost, proof: .password("unused-fixture"), trust: trust)
        let denied = try await separate.preferredLocalConnection?("127.0.0.1", port)
        XCTAssertNil(denied)
        let tunneled = try await separate.transportProvider?("127.0.0.1", port)
        XCTAssertTrue(tunneled is DesktopSSH)
    }

    func testReconnectReevaluatesRouteWithoutLosingTheRequestedMediaMode() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directPort = env["DESKLINK_MEDIA_DIRECT_PORT"].flatMap(UInt16.init),
              let tunnelPort = env["DESKLINK_MEDIA_TUNNEL_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Requires the two Apple-protocol loopback displays.")
        }
        let host = "127.0.0.1"
        let trust = HostTrust()
        var computer = Computer(endpoint: try Endpoint(address: host, defaultPort: directPort))
        computer.ssh = SSHSettings(secureLocally: false)
        computer.setDisplay(DesktopDisplayPreferences(quality: .adaptive), for: .current)
        var configuration = computer.configuration
        DesktopSSH.configureTransport(&configuration, settings: try XCTUnwrap(computer.ssh), proof: nil, trust: trust)
        let selectDirect = try XCTUnwrap(configuration.preferredLocalConnection)
        let routes = FixtureMediaRoutes()
        configuration.preferredLocalConnection = { host, port in
            guard await routes.next() else { return nil }
            return try await selectDirect(host, port)
        }
        // An independent loopback socket stands in for the byte-stream-only tunnel.
        configuration.transportProvider = { _, _ in TCPConnection(host: host, port: tunnelPort) }
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        XCTAssertTrue(configuration.enableHighPerformanceMode)
        try await session.connect(credentials: VNCCredentials(host: host, port: directPort, password: ""))
        try await until { session.hasPresentedStandardPicture }
        try await until { session.connectionState.isConnected }

        for attempt in 2...3 {
            XCTAssertTrue(session.reconnect(with: session.configuration))
            try await until { await routes.count >= attempt && session.connectionState.isConnected }
            XCTAssertEqual(session.configuration.videoQualityMode, .adaptive)
            XCTAssertTrue(session.configuration.enableHighPerformanceMode)
            XCTAssertNil(session.highPerformanceFallbackReason)
        }
    }

    func testPassphraseProtectedKeysAndPublicKeyLogin() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let encoded = env["DESKLINK_KEY_FIXTURES"], let data = Data(base64Encoded: encoded),
              let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires fresh encrypted identities from the loopback SSH test peer.")
        }
        let fixtures = try JSONDecoder().decode([GeneratedKey].self, from: data)
        XCTAssertEqual(fixtures.count, 5)
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
        let attempt = Task { try await session.connect(credentials: VNCCredentials(host: peerHost, password: "")) }
        defer { attempt.cancel() }
        try await until { trust.prompt != nil }
        let matches = trust.prompt?.fingerprint == pin
        trust.answer(matches)
        XCTAssertTrue(matches)
        try await attempt.value
        try await until { session.currentImage?.width == 320 }
    }

    func testRSAKeyFormatsAndForwardedDesktop() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let encoded = env["DESKLINK_KEY_FIXTURES"], let data = Data(base64Encoded: encoded),
              let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires a fresh RSA identity and the loopback SSH test peer.")
        }
        let fixtures = try JSONDecoder().decode([GeneratedKey].self, from: data)
        let rsa = try XCTUnwrap(fixtures.first { $0.public.hasPrefix("ssh-rsa ") })
        XCTAssertThrowsError(try SSHKeyFile.opened(rsa.key, passphrase: "invalid")) {
            XCTAssertEqual(($0 as NSError).code, Int(errSecAuthFailed))
        }
        let encryptedKey = try SSHKeyFile.identity(SSHKeyFile.opened(rsa.key, passphrase: "chart-key-phrase"))
        XCTAssertTrue(encryptedKey.isRSA)
        let pemKeys = try XCTUnwrap(rsa.pem)
        XCTAssertEqual(pemKeys.count, 2)
        for pem in pemKeys {
            let key = try SSHKeyFile.identity(SSHKeyFile.opened(pem))
            XCTAssertEqual(String(openSSHPublicKey: key.publicKey), rsa.public)
        }

        let domain = "DeskLinkRSAKeyLogin." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SSHSettings(port: port, username: "fixture-rsa", usesKey: true)
        let trust = HostTrust(defaults: defaults)
        let rejected = DesktopSSH(host: peerHost, desktopPort: 5900, settings: settings,
                                  proof: .privateKey(encryptedKey), trust: trust)
        let untrusted = Task { try await rejected.connect() }
        defer { untrusted.cancel() }
        try await until { trust.prompt != nil }
        XCTAssertEqual(trust.prompt?.fingerprint, pin)
        trust.answer(false)
        do {
            try await untrusted.value
            XCTFail("Connected after rejecting the SSH gateway fingerprint")
        } catch {
            XCTAssertNil(trust.prompt)
        }
        await rejected.close()

        var configuration = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        configuration.transportProvider = { host, port in
            DesktopSSH(host: host, desktopPort: port, settings: settings, proof: .privateKey(encryptedKey), trust: trust)
        }
        let session = VNCSession(configuration: configuration)
        defer { trust.cancel(); session.disconnect() }
        let connection = Task { try await session.connect(credentials: .init(host: peerHost, password: "")) }
        defer { connection.cancel() }
        try await until { trust.prompt != nil }
        let matches = trust.prompt?.fingerprint == pin
        trust.answer(matches)
        XCTAssertTrue(matches)
        try await connection.value
        try await until { session.currentImage?.width == 320 }
        XCTAssertEqual(session.currentImage?.height, 192)
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
        let settings = SSHSettings(port: port, username: "fixture", usesKey: false, server: peerHost, secureLocally: false)
        var config = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        DesktopSSH.configureTransport(&config, settings: settings, proof: .password("chart-test-only"), trust: trust)
        let session = VNCSession(configuration: config)
        defer { trust.cancel(); session.disconnect() }
        let connection = Task {
            try await session.connect(credentials: .init(host: "chart.fixture.invalid", port: 5917, password: ""))
        }
        defer { connection.cancel() }
        try await until { trust.prompt != nil }
        let shownHost = peerHost.contains(":") ? "[\(peerHost)]" : peerHost
        XCTAssertEqual(trust.prompt?.displayAddress, "\(shownHost):\(port)")
        let matches = trust.prompt?.host == "\(peerHost):\(port)" && trust.prompt?.fingerprint == pin
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
        let task = Task { try await session.connect(credentials: VNCCredentials(host: peerHost, password: "")) }
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

    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await predicate()) && Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        guard await predicate() else { throw URLError(.timedOut) }
    }
}

private actor FixtureMediaRoutes {
    private(set) var count = 0

    // The same saved profile dials natively, through a tunnel, then natively again.
    func next() -> Bool {
        count += 1
        return count != 2
    }
}
