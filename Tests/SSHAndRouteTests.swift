import CryptoKit
import NIOCore
import NIOSSH
import XCTest
@testable import DeskLink

final class SSHAndRouteTests: XCTestCase {
    func testSavedEmptyDesktopPasswordIsDistinctFromMissingCredentials() throws {
        var computer = Computer(endpoint: try Endpoint(address: UUID().uuidString.lowercased() + ".fixture.invalid"))
        computer.username = "fixture-viewer"
        var otherAccount = computer
        otherAccount.username = "fixture-different-viewer"
        defer { try? PasswordStore.write(nil, for: computer) }

        XCTAssertNil(try SessionRequest.remembered(for: computer, synchronize: false))
        try PasswordStore.write("old-fixture-password", for: computer)
        try PasswordStore.write("", for: computer)
        XCTAssertEqual(try PasswordStore.read(computer), "")
        XCTAssertNil(try PasswordStore.read(otherAccount))
        let saved = try XCTUnwrap(SessionRequest.remembered(for: computer, synchronize: false))
        XCTAssertEqual(saved.password, "")
        XCTAssertTrue(saved.rememberPassword)

        try PasswordStore.write(nil, for: computer)
        XCTAssertNil(try PasswordStore.read(computer))
        XCTAssertNil(try SessionRequest.remembered(for: computer, synchronize: false))
    }

    func testRememberedConnectionWaitsForBothDesktopAndTunnelCredentials() throws {
        var computer = Computer(endpoint: try Endpoint(address: UUID().uuidString.lowercased() + ".fixture.invalid"))
        computer.username = "fixture-viewer"
        computer.ssh = SSHSettings(port: 2234, username: "fixture-helper")
        defer {
            try? PasswordStore.write(nil, for: computer)
            try? PasswordStore.write(nil, for: computer, kind: .sshPassword)
        }
        XCTAssertNil(try SessionRequest.remembered(for: computer, synchronize: false))
        try PasswordStore.write("fixture-desktop", for: computer)
        XCTAssertNil(try SessionRequest.remembered(for: computer, synchronize: false))
        try PasswordStore.write("", for: computer, kind: .sshPassword)
        XCTAssertNil(try PasswordStore.read(computer, kind: .sshPassword))
        try PasswordStore.write("fixture-tunnel", for: computer, kind: .sshPassword)
        let remembered = try XCTUnwrap(SessionRequest.remembered(for: computer, synchronize: false))
        XCTAssertEqual(remembered.password, "fixture-desktop")
        guard case let .password(proof) = remembered.sshProof else { return XCTFail("Expected the saved tunnel password") }
        XCTAssertEqual(proof, "fixture-tunnel")
        var different = computer
        different.ssh?.server = "other-" + UUID().uuidString.lowercased() + ".fixture.invalid"
        XCTAssertNil(try SessionRequest.remembered(for: different, synchronize: false))
    }

    func testSeparateSSHServerRoundTripsWithoutReusingOtherDesktopCredentials() throws {
        let desktop = try Endpoint(address: "[::1]:5917")
        let link = try XCTUnwrap(ConnectionRoute.sharing(desktop, sshPort: 2223, server: "GATEWAY.fixture.invalid"))
        XCTAssertEqual(try ConnectionRoute(url: link), .secureAddress(desktop, sshPort: 2223, server: "gateway.fixture.invalid"))
        for query in ["server=a", "ssh=22&server=", "ssh=22&server=host:22", "ssh=22&server=a&server=b"] {
            let url = try XCTUnwrap(URL(string: "desklink://studio.fixture.invalid?" + query))
            XCTAssertThrowsError(try ConnectionRoute(url: url))
        }
        var first = Computer(endpoint: desktop)
        first.username = "viewer"
        first.ssh = SSHSettings(port: 2223, username: "helper", server: "first.fixture.invalid")
        var other = first
        other.ssh?.server = "second.fixture.invalid"
        XCTAssertNotEqual(PasswordStore.account(for: first, kind: .desktop), PasswordStore.account(for: other, kind: .desktop))
        XCTAssertNotEqual(PasswordStore.account(for: first, kind: .sshPassword), PasswordStore.account(for: other, kind: .sshPassword))
        other.endpoint = try Endpoint(address: "another-desktop.fixture.invalid")
        other.ssh = first.ssh
        XCTAssertEqual(PasswordStore.account(for: first, kind: .sshPassword), PasswordStore.account(for: other, kind: .sshPassword))
        first.ssh?.server = nil
        XCTAssertEqual(PasswordStore.account(for: first, kind: .desktop), "[::1]:5917\nviewer")
        XCTAssertEqual(PasswordStore.account(for: first, kind: .sshPassword), "::1:2223\nhelper")
    }

    func testInputRetainsPacketFragmentsAndClosesPendingRead() async throws {
        let input = SSHInput()
        XCTAssertTrue(input.append(ByteBuffer(bytes: [1, 2])))
        let first = Task { try await input.read(minimum: 3, maximum: 3) }
        XCTAssertTrue(input.append(ByteBuffer(bytes: [3, 4, 5])))
        let bytes = try await first.value
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        let remainder = try await input.read(minimum: 1, maximum: 9)
        XCTAssertEqual(remainder, Data([4, 5]))
        let pending = Task { try await input.read(minimum: 1, maximum: 2) }
        input.finish(.connectionClosed, notify: false)
        do { _ = try await pending.value; XCTFail("Closed input yielded data") } catch {}
    }

    @MainActor func testHostKeyMustBeConfirmedAndChangedKeyIsRejected() async throws {
        let domain = "DeskLinkUnitTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let gate = HostTrust(defaults: defaults)
        let first = Task { await gate.verify(host: "fixture.invalid", port: 22, fingerprint: "SHA256:known") }
        while gate.prompt == nil { await Task.yield() }
        gate.answer(false)
        let rejected = await first.value
        XCTAssertFalse(rejected)
        let second = Task { await gate.verify(host: "fixture.invalid", port: 22, fingerprint: "SHA256:known") }
        while gate.prompt == nil { await Task.yield() }
        gate.answer(true)
        let accepted = await second.value
        XCTAssertTrue(accepted)
        let restored = HostTrust(defaults: defaults)
        let same = await restored.verify(host: "fixture.invalid", port: 22, fingerprint: "SHA256:known")
        let different = await restored.verify(host: "fixture.invalid", port: 22, fingerprint: "SHA256:changed")
        XCTAssertTrue(same)
        XCTAssertFalse(different)
        XCTAssertNil(restored.prompt)
        let saved = try XCTUnwrap(HostTrust.saved(in: defaults).first)
        XCTAssertEqual(saved.host, "fixture.invalid:22")
        HostTrust.forget(saved, in: defaults)
        XCTAssertTrue(HostTrust.saved(in: defaults).isEmpty)
        let recheck = Task { await restored.verify(host: "fixture.invalid", port: 22, fingerprint: "SHA256:changed") }
        while restored.prompt == nil { await Task.yield() }
        restored.answer(false)
        let wasAccepted = await recheck.value
        XCTAssertFalse(wasAccepted)
    }

    @MainActor func testSavedIPv6HostShowsItsPortAndKeepsItsOriginalTrustKey() async throws {
        let domain = "DeskLinkIPv6Trust." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = "ssh.trusted.2001:db8::2:2222"
        defaults.set("SHA256:fixture", forKey: key)
        let identity = try XCTUnwrap(HostTrust.saved(in: defaults).first)
        XCTAssertEqual(identity.id, key)
        XCTAssertEqual(identity.displayAddress, "[2001:db8::2]:2222")
        let trust = HostTrust(defaults: defaults)
        let known = await trust.verify(host: "2001:db8::2", port: 2222, fingerprint: "SHA256:fixture")
        XCTAssertTrue(known)
        XCTAssertNil(trust.prompt)
        HostTrust.forget(identity, in: defaults)
        XCTAssertNil(defaults.string(forKey: key))
    }

    func testPEMKeyImportReturnsMatchingPublicKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        let original = NIOSSHPrivateKey(p256Key: privateKey)
        let decoded = try SSHKeyFile.identity(privateKey.pemRepresentation)
        XCTAssertEqual(String(openSSHPublicKey: decoded.publicKey), String(openSSHPublicKey: original.publicKey))
        XCTAssertThrowsError(try SSHKeyFile.identity("not a private key"))
    }

    func testSharedSecureProfileKeepsSSHWithoutExportingCredentials() throws {
        let target = try Endpoint(address: "[::1]:5907")
        let url = try XCTUnwrap(ConnectionRoute.sharing(target, sshPort: 2205))
        XCTAssertEqual(url.absoluteString, "desklink://[::1]:5907?ssh=2205")
        XCTAssertEqual(try ConnectionRoute(url: url), .secureAddress(target, sshPort: 2205))
        for invalid in ["desklink://host?ssh=0", "vnc://host?ssh=22", "desklink://host?ssh=22&password=test",
                        "desklink://host?ssh=22&ssh=23", "desklink://user@host?ssh=22"] {
            XCTAssertThrowsError(try ConnectionRoute(url: XCTUnwrap(URL(string: invalid))))
        }
    }

    func testSharedOptionsKeepTheExactDesktopAndTunnelPorts() throws {
        let target = try Endpoint(address: "[2001:db8::12]:5907")
        for quality in PictureQuality.allCases {
            let options = ConnectionRoute.SharedOptions(observe: true, quality: quality)
            let url = try XCTUnwrap(ConnectionRoute.sharing(target, sshPort: 2243, server: "GATEWAY.fixture.invalid", options: options))
            let expected = ConnectionRoute.sharedAddress(target, sshPort: 2243, server: "gateway.fixture.invalid", options: options)
            XCTAssertEqual(try ConnectionRoute(url: url), expected)
            let authority = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertNil(authority.user)
            XCTAssertNil(authority.password)
        }
        let confirmControl = try XCTUnwrap(URL(string: "desklink://host.fixture.invalid?observe=0"))
        XCTAssertEqual(try ConnectionRoute(url: confirmControl),
                       .sharedAddress(try Endpoint(address: "host.fixture.invalid"), sshPort: nil, server: nil,
                                      options: .init(observe: false)))
    }

    func testSharedScopedIPv6AndMalformedOptions() throws {
        let local = try Endpoint(address: "[fe80::17%en0]:5912")
        let plain = try XCTUnwrap(ConnectionRoute.sharing(local, sshPort: nil))
        XCTAssertEqual(plain.absoluteString, "desklink://[fe80::17%25en0]:5912")
        XCTAssertEqual(try ConnectionRoute(url: plain), .address(local))
        let shared = try XCTUnwrap(ConnectionRoute.sharing(local, sshPort: nil, options: .init(observe: true)))
        XCTAssertEqual(try ConnectionRoute(url: shared),
                       .sharedAddress(local, sshPort: nil, server: nil, options: .init(observe: true)))
        for suffix in ["observe=maybe", "observe=true&observe=false", "quality=other", "quality=",
                       "observe=true&server=unbound.invalid", "observe=true&ssh=0", "observe=true&password=secret",
                       "observe=true&username=reader", "observe=true&guest=true"] {
            let url = try XCTUnwrap(URL(string: "desklink://desktop.invalid?" + suffix))
            XCTAssertThrowsError(try ConnectionRoute(url: url), suffix)
        }
        XCTAssertNil(ConnectionRoute.sharing(local, sshPort: nil, server: "unbound.invalid"))
        XCTAssertNil(ConnectionRoute.sharing(local, sshPort: 0))
    }

    func testSavedConnectionSharesItsExplicitAuthenticationWithoutTransferringCredentials() throws {
        let desktop = try Endpoint(address: "[2001:db8::12]:5907")
        for method in DesktopAuthentication.allCases {
            var computer = Computer(endpoint: desktop)
            computer.authentication = method
            computer.username = method.usesUsername ? "fixture-desktop-user" : ""
            computer.ssh = SSHSettings(port: 2243, username: "fixture-tunnel-user", usesKey: true,
                                       keyName: "fixture-private-key", server: "gateway.fixture.invalid")
            computer.viewOnly = true
            computer.quality = .lossless

            let url = try XCTUnwrap(computer.sharedConnectionURL(for: .iPad))
            let route = try ConnectionRoute(url: url)
            let authentication = method == .automatic ? nil : method
            XCTAssertEqual(route, .sharedAddress(desktop, sshPort: 2243, server: "gateway.fixture.invalid",
                options: .init(observe: true, quality: .lossless, authentication: authentication)))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertNil(components.user)
            XCTAssertNil(components.password)
            XCTAssertFalse(url.absoluteString.contains("fixture-desktop-user"))
            XCTAssertFalse(url.absoluteString.contains("fixture-tunnel-user"))
            XCTAssertFalse(url.absoluteString.contains("fixture-private-key"))
        }
    }

    func testAuthenticationOnlyLinksRoundTripAndRejectInvalidOrDuplicateValues() throws {
        let endpoint = try Endpoint(address: "desktop.fixture.invalid:5914")
        for method in DesktopAuthentication.allCases {
            let options = ConnectionRoute.SharedOptions(authentication: method)
            let url = try XCTUnwrap(ConnectionRoute.sharing(endpoint, sshPort: nil, options: options))
            XCTAssertEqual(try ConnectionRoute(url: url), .sharedAddress(endpoint, sshPort: nil, server: nil, options: options))
            guard case .sharedAddress(_, _, _, let parsed) = try ConnectionRoute(url: url) else {
                return XCTFail("Missing explicit authentication")
            }
            var computer = Computer(endpoint: endpoint)
            computer.authentication = try XCTUnwrap(parsed.authentication)
            XCTAssertEqual(computer.authentication, method)
        }
        for invalid in ["auth=unknown", "auth=", "auth=mac-user&auth=none",
                        "auth=none&user=viewer", "auth=none&password=secret",
                        "auth=raspberry-pi&ssh=0"] {
            let url = try XCTUnwrap(URL(string: "desklink://desktop.fixture.invalid?" + invalid))
            XCTAssertThrowsError(try ConnectionRoute(url: url), invalid)
        }
    }

    func testShortcutAndHostLinksRemainDistinct() throws {
        let id = UUID()
        XCTAssertEqual(try ConnectionRoute(url: ConnectionRoute.savedURL(id)), .saved(id))
        XCTAssertEqual(try ConnectionRoute(url: XCTUnwrap(URL(string: "desklink:///connect"))), .quick)
        XCTAssertEqual(try ConnectionRoute(url: XCTUnwrap(URL(string: "desklink://mac.local:5999"))), .address(try Endpoint(address: "mac.local:5999")))
        for invalid in ["desklink:///connect/bogus", "desklink://name:secret@mac.local", "desklink://mac.local?password=something"] {
            XCTAssertThrowsError(try ConnectionRoute(url: XCTUnwrap(URL(string: invalid))))
        }
    }
}
