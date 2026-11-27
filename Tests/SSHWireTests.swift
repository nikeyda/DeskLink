import XCTest
import RFBProtocol
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
        let encryptedPEM: String
        let encryptedPEMVariants: [String]?
        let openSSHCipherVariants: [String: String]?
    }

    func testSSHLoginAndHostIdentityFailuresRemainDistinctAtTheSessionBoundary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires the loopback SSH chart.")
        }
        let suite = "Telescope.SSHRecovery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pinKey = "ssh.trusted.\(peerHost):\(port)"
        let settings = SSHSettings(port: port, username: "fixture")
        let trust = HostTrust(defaults: defaults)
        let credentials = VNCCredentials(host: peerHost, password: "")

        for (pinnedIdentity, password, expected) in [
            (pin, "rejected-fixture", VNCProtocolError.sshAuthenticationFailed),
            ("SHA256:other-test-host", "chart-test-only", .sshHostIdentityRejected)
        ] {
            defaults.set(pinnedIdentity, forKey: pinKey)
            var configuration = VNCConfiguration()
            DesktopSSH.configureTransport(&configuration, settings: settings, proof: .password(password), trust: trust)
            let session = VNCSession(configuration: configuration)
            defer { session.disconnect() }
            do {
                try await session.connect(credentials: credentials)
                XCTFail("The isolated peer opened a rejected connection.")
            } catch {
                XCTAssertEqual(session.lastError, expected)
                XCTAssertTrue(SessionConnectionFailure(session.lastError, setupRequiresEditing: false).needsEditing)
                XCTAssertNil(trust.prompt)
                XCTAssertEqual(defaults.string(forKey: pinKey), pinnedIdentity)
            }
        }

        defaults.set(pin, forKey: pinKey)
        var configuration = VNCConfiguration()
        DesktopSSH.configureTransport(&configuration, settings: settings, proof: .password("chart-test-only"), trust: trust)
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: credentials)
        try await until { session.hasPresentedCurrentPicture }
        XCTAssertNil(session.lastError)
    }

    func testSSHLoginRejectionStopsAutomaticRecoveryAfterAnEstablishedSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let pin = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires the loopback SSH chart.")
        }
        let suite = "Telescope.SSHReconnect." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(pin, forKey: "ssh.trusted.\(peerHost):\(port)")
        let trust = HostTrust(defaults: defaults)
        let attempts = SSHRecoveryFixture(settings: .init(port: port, username: "fixture"), trust: trust)
        var configuration = VNCConfiguration()
        configuration.transportProvider = { host, desktopPort in
            await attempts.connection(host: host, desktopPort: desktopPort)
        }
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        try await session.connect(credentials: .init(host: peerHost, password: ""))
        try await until { session.hasPresentedCurrentPicture }
        await attempts.closeFirst()
        try await until { session.lastError == .sshAuthenticationFailed && session.connectionState.canConnect }
        let connectionCount = await attempts.count
        XCTAssertEqual(connectionCount, 2)
        XCTAssertTrue(SessionConnectionFailure(session.lastError, setupRequiresEditing: false).needsEditing)
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

        let session = VNCSession(configuration: local)
        defer { session.disconnect() }
        try await session.connect(credentials: .init(host: "127.0.0.1", port: port, password: ""))
        try await until { session.hasPresentedStandardPicture }
        let report = await ConnectionReport.capture(session: session, id: UUID(), startedAt: .now)
        XCTAssertEqual(report?.route, .verifiedLocal)
        XCTAssertEqual(report?.connectionPathLabel, "局域网直连")
        XCTAssertEqual(report?.encryption, "未加密")

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
        let initial = await ConnectionReport.capture(session: session, id: UUID(), startedAt: .now)
        XCTAssertEqual(initial?.route, .verifiedLocal)

        for attempt in 2...3 {
            XCTAssertTrue(session.reconnect(with: session.configuration))
            try await until { await routes.count >= attempt && session.connectionState.isConnected }
            XCTAssertEqual(session.configuration.videoQualityMode, .adaptive)
            XCTAssertTrue(session.configuration.enableHighPerformanceMode)
            XCTAssertNil(session.highPerformanceFallbackReason)
            let report = await ConnectionReport.capture(session: session, id: UUID(), startedAt: .now)
            XCTAssertEqual(report?.route, attempt == 2 ? .custom : .verifiedLocal)
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
        XCTAssertThrowsError(try SSHKeyFile.opened(first.encryptedPEM)) {
            XCTAssertEqual(($0 as NSError).code, Int(errSecPassphraseRequired))
        }
        XCTAssertThrowsError(try SSHKeyFile.opened(first.encryptedPEM, passphrase: "invalid")) {
            XCTAssertEqual(($0 as NSError).code, Int(errSecAuthFailed))
        }
        var pemIdentities: [NIOSSHPrivateKey] = []
        for item in fixtures {
            let material = try SSHKeyFile.opened(item.key, passphrase: "chart-key-phrase")
            let key = try SSHKeyFile.identity(material)
            XCTAssertEqual(String(openSSHPublicKey: key.publicKey), item.public)
            let pem = try SSHKeyFile.opened(item.encryptedPEM, passphrase: "chart-key-phrase")
            let pemKey = try SSHKeyFile.identity(pem)
            XCTAssertEqual(String(openSSHPublicKey: pemKey.publicKey), item.public)
            pemIdentities.append(pemKey)
            for variant in item.encryptedPEMVariants ?? [] {
                let opened = try SSHKeyFile.opened(variant, passphrase: "chart-key-phrase")
                XCTAssertEqual(String(openSSHPublicKey: try SSHKeyFile.identity(opened).publicKey), item.public)
            }
        }
        let login: NIOSSHPrivateKey
        if let variants = first.openSSHCipherVariants {
            let ciphers: Set<String> = ["aes128-ctr", "aes192-ctr", "aes256-ctr", "aes128-cbc", "aes192-cbc", "aes256-cbc"]
            XCTAssertEqual(Set(variants.keys), ciphers)
            for (cipher, variant) in variants {
                XCTAssertThrowsError(try SSHKeyFile.opened(variant), cipher) {
                    XCTAssertEqual(($0 as NSError).code, Int(errSecPassphraseRequired))
                }
                XCTAssertThrowsError(try SSHKeyFile.opened(variant, passphrase: "invalid"), cipher) {
                    XCTAssertEqual(($0 as NSError).code, Int(errSecAuthFailed))
                }
                let key = try SSHKeyFile.identity(SSHKeyFile.opened(variant, passphrase: "chart-key-phrase"))
                XCTAssertEqual(String(openSSHPublicKey: key.publicKey), first.public, cipher)
            }
            let cbcKey = try XCTUnwrap(variants["aes256-cbc"])
            login = try SSHKeyFile.identity(SSHKeyFile.opened(cbcKey, passphrase: "chart-key-phrase"))
        } else {
            login = try XCTUnwrap(pemIdentities.first)
        }
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
        let encryptedKey = try SSHKeyFile.identity(SSHKeyFile.opened(rsa.encryptedPEM, passphrase: "chart-key-phrase"))
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

    func testRSAHostFingerprintPersistsAndRejectsAChangedGateway() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let algorithm = env["DESKLINK_SSH_HOST_ALGORITHM"], algorithm.hasPrefix("rsa-sha2-"),
              let port = env["DESKLINK_SSH_PORT"].flatMap(UInt16.init), let fingerprint = env["DESKLINK_SSH_PIN"] else {
            throw XCTSkip("Requires the independent RSA-only SSH gateway.")
        }
        let domain = "DeskLinkRSAHost." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let trust = HostTrust(defaults: defaults)
        defer { trust.cancel() }
        let ssh = SSHSettings(port: port, username: "fixture")
        func dial() -> DesktopSSH {
            DesktopSSH(host: peerHost, desktopPort: 5900, settings: ssh,
                       proof: .password("chart-test-only"), trust: trust)
        }

        let first = dial()
        let initial = Task { try await first.connect() }
        defer { initial.cancel() }
        try await until { trust.prompt != nil }
        let prompt = try XCTUnwrap(trust.prompt)
        XCTAssertEqual(prompt.fingerprint, fingerprint)
        trust.answer(prompt.fingerprint == fingerprint, remember: true)
        try await initial.value
        let banner = try await first.read(exactly: 12)
        XCTAssertEqual(banner, Data("RFB 003.008\n".utf8))
        await first.close()
        XCTAssertEqual(HostTrust.saved(in: defaults).map(\.fingerprint), [fingerprint])

        let known = dial()
        var knownDone = false
        let reconnect = Task {
            defer { knownDone = true }
            try await known.connect()
        }
        defer { reconnect.cancel() }
        try await until { knownDone || trust.prompt != nil }
        if trust.prompt != nil {
            XCTFail("A saved RSA gateway fingerprint prompted again")
            trust.answer(false)
        }
        try await reconnect.value
        let reconnectedBanner = try await known.read(exactly: 12)
        XCTAssertEqual(reconnectedBanner, banner)
        await known.close()

        let priorFingerprint = "SHA256:" + String(repeating: "A", count: 43)
        defaults.set(priorFingerprint, forKey: prompt.id)
        let changed = dial()
        var rejected = false
        let attempt = Task {
            defer { rejected = true }
            try await changed.connect()
        }
        defer { attempt.cancel() }
        try await until { rejected || trust.prompt != nil }
        if trust.prompt != nil {
            XCTFail("A changed RSA gateway fingerprint prompted instead of rejecting")
            trust.answer(false)
        }
        do {
            try await attempt.value
            XCTFail("Connected using a different stored gateway fingerprint")
        } catch {
            XCTAssertEqual(defaults.string(forKey: prompt.id), priorFingerprint)
        }
        await changed.close()
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
        let report = await ConnectionReport.capture(session: session, id: UUID(), startedAt: .now)
        XCTAssertEqual(report?.route, .ssh)
        XCTAssertEqual(report?.connectionPathLabel, "SSH 隧道")
        XCTAssertEqual(report?.encryption, "SSH")
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

private actor SSHRecoveryFixture {
    let settings: SSHSettings
    let trust: HostTrust
    private var initial: DesktopSSH?
    private(set) var count = 0

    init(settings: SSHSettings, trust: HostTrust) {
        self.settings = settings
        self.trust = trust
    }

    func connection(host: String, desktopPort: UInt16) -> DesktopSSH {
        count += 1
        let password = count == 1 ? "chart-test-only" : "rejected-fixture"
        let transport = DesktopSSH(host: host, desktopPort: desktopPort, settings: settings, proof: .password(password), trust: trust)
        if count == 1 { initial = transport }
        return transport
    }

    func closeFirst() async { await initial?.close() }
}

private actor FixtureMediaRoutes {
    private(set) var count = 0

    // The same saved profile dials natively, through a tunnel, then natively again.
    func next() -> Bool {
        count += 1
        return count != 2
    }
}
