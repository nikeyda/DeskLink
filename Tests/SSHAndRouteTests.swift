import CryptoKit
import NIOCore
import NIOSSH
import XCTest
@testable import DeskLink

final class SSHAndRouteTests: XCTestCase {
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
