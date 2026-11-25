import CryptoKit
import XCTest
@testable import DeskLink

final class DesktopLinkTests: XCTestCase {
    func testURLCredentialsAndPortHaveSeparateDestinations() throws {
        let link = try DesktopLink(text: "vnc://editor:p%40ss%3A7@[::1]:5998?observe=true")
        XCTAssertEqual(link.target, .address(try Endpoint(address: "[::1]:5998")))
        XCTAssertEqual(link.username, "editor")
        XCTAssertEqual(link.password, "p@ss:7")
        XCTAssertEqual(link.observe, true)
        XCTAssertNil(link.sshPort)
        let ssh = try DesktopLink(text: "ssh://tunnel@example.invalid:2213?ssh-key=Test%20Key&observe=false")
        XCTAssertEqual(ssh.target, .address(try Endpoint(address: "example.invalid")))
        XCTAssertEqual(ssh.sshPort, 2213)
        XCTAssertEqual(ssh.keyName, "Test Key")
        XCTAssertEqual(ssh.observe, false)
        XCTAssertEqual(try DesktopLink(text: "ssh://[fe80::1%25en0]").target, .address(try Endpoint(address: "[fe80::1%en0]")))
        XCTAssertEqual(try DesktopLink(text: "ssh://host").sshPort, 22)
        XCTAssertNil(try DesktopLink(text: "vnc://host/").observe)
        for scheme in ["vnc", "screens", "ssh"] {
            let observe = try DesktopLink(text: scheme + "://example.invalid?guest=0&observe=1")
            XCTAssertEqual(observe.observe, true)
            XCTAssertFalse(observe.requestsGuest)
            let guest = try DesktopLink(text: scheme + "://example.invalid?guest=1&observe=0")
            XCTAssertEqual(guest.observe, false)
            XCTAssertTrue(guest.requestsGuest)
        }
    }

    func testNamedLinksResolveOnlyAnUnambiguousSavedComputer() throws {
        let endpoint = try Endpoint(address: "studio.local:5905")
        var first = Computer(name: "剪辑 Mac", endpoint: endpoint)
        first.username = "first"
        var second = Computer(name: first.name, endpoint: try Endpoint(address: "spare.local"))
        second.username = "second"
        var recent = Computer(name: first.name, endpoint: endpoint)
        recent.saved = false
        let archive = LibraryArchive(computers: [first, recent, second])
        let named = try DesktopLink(text: "screens://second:example@剪辑%20Mac?observe=true")
        XCTAssertEqual(try EditorRequest.from(named, in: archive, allowUnsavedHost: false).computer?.id, second.id)
        XCTAssertThrowsError(try EditorRequest.from(DesktopLink(text: "screens://剪辑 Mac"), in: archive, allowUnsavedHost: false))
        let direct = try DesktopLink(text: "screens://studio.local:5905")
        XCTAssertEqual(try EditorRequest.from(direct, in: archive, allowUnsavedHost: false).computer?.id, first.id)
        let unknown = try DesktopLink(text: "screens://unknown.local")
        XCTAssertThrowsError(try EditorRequest.from(unknown, in: archive, allowUnsavedHost: false))
        XCTAssertEqual(try EditorRequest.from(unknown, in: archive, allowUnsavedHost: true).initialAddress, "unknown.local")
        let guest = try DesktopLink(text: "vnc://my-mac.local?guest=true")
        XCTAssertTrue(guest.requestsGuest)
        XCTAssertThrowsError(try EditorRequest.from(guest, in: archive, allowUnsavedHost: true))
    }

    func testMalformedLinksCannotBecomeAnOrdinaryConnection() {
        for invalid in ["ssh://host:0", "ssh://host:65536", "vnc://a@b@host", "vnc://host/path",
                        "vnc://host?Observe=true", "vnc://host?observe=yes", "vnc://host?guest=true&guest=false",
                        "vnc://host?ssh-key=some", "ssh://host?ssh-key=", "vnc://host?observe", "vnc://host#anything",
                        "vnc://name%0A:password@host", "vnc://vnc%3A%2F%2Fhost", "ssh://host:", "screens://"] {
            XCTAssertThrowsError(try DesktopLink(text: invalid))
        }
    }

    func testNamedKeyRetainsExactCaseAndArchiveContainsOnlyItsName() throws {
        let name = "DeskLink fixture " + UUID().uuidString
        let key = P256.Signing.PrivateKey().pemRepresentation
        try PasswordStore.addNamedKey(key, name: name, synchronize: false)
        defer { try? PasswordStore.removeNamedKey(name, synchronize: false) }
        XCTAssertTrue(try PasswordStore.keyNames(synchronize: false).contains(name))
        XCTAssertTrue(try PasswordStore.namedKey(name, synchronize: false) == key)
        XCTAssertTrue(try PasswordStore.namedKey(name.lowercased(), synchronize: false) == nil)
        XCTAssertThrowsError(try PasswordStore.addNamedKey(key, name: name, synchronize: false))
        var computer = Computer(endpoint: try Endpoint(address: "test.invalid"))
        computer.ssh = SSHSettings(username: "fixture", usesKey: true, keyName: name)
        let encoded = try LibraryArchive(computers: [computer]).encoded()
        XCTAssertNil(encoded.range(of: Data("PRIVATE KEY".utf8)))
        XCTAssertEqual(try LibraryArchive.read(encoded).computers.first?.ssh?.keyName, name)
        let oldSettings = Data(#"{"port":22,"username":"legacy","usesKey":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SSHSettings.self, from: oldSettings).keyName)
        try PasswordStore.removeNamedKey(name, synchronize: false)
        XCTAssertTrue(try PasswordStore.namedKey(name, synchronize: false) == nil)
    }
}
