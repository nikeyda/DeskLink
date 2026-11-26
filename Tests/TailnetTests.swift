import XCTest
@testable import DeskLink

final class TailnetTests: XCTestCase {
    @MainActor func testUnifiedSearchFindsOutsideTheSelectedFolderAndKeepsPortsAndVisibility() async throws {
        let domain = "TelescopeTailnetSearch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "fixture"),
                                 secret: "fixture-only", remember: false)
        let device = try XCTUnwrap(directory.visibleDevices.first)
        let id = try XCTUnwrap(directory.directoryID(for: device))
        directory.addFolder("Studio")
        let studio = try XCTUnwrap(directory.selectedFolder)
        directory.moveDevice(id, to: studio.id)
        directory.addFolder("Home")
        XCTAssertTrue(directory.devicesInSelectedFolder.isEmpty)
        try directory.setPorts(TailnetDevicePorts(vnc: "5910", ssh: "2200"), for: id)

        let query = LibrarySearchQuery("STUDIO 5910")
        let result = try XCTUnwrap(directory.searchMatches(query).first)
        XCTAssertEqual(result.id, device.id)
        XCTAssertEqual(result.folder, studio.name)
        XCTAssertEqual(result.computer.endpoint.port, 5910)
        XCTAssertEqual(result.sshPort, 2200)
        directory.setHidden(true, device: device)
        XCTAssertTrue(directory.searchMatches(query).isEmpty)
    }

    func testAccountRejectsPathInjectionAndEscapesFormFields() throws {
        for invalid in ["", ".", "..", "example/other", "x?bearer", "//example", "two words"] {
            XCTAssertThrowsError(try TailnetAccount(tailnet: invalid, clientID: "id"))
        }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        let request = try account.tokenRequest(secret: "generated+a&b=c")
        XCTAssertEqual(request.url?.absoluteString, "https://api.tailscale.com/api/v2/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let value = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(value.contains("client_secret=generated%2Ba%26b%3Dc"))
        XCTAssertTrue(value.contains("scope=devices%3Acore%3Aread"))
    }

    @MainActor func testReadOnlyAccountListsAuthorizedDevicesWithoutPersistingTheLogin() async throws {
        let domain = "DeskLinkTailnetTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        try await directory.link(account, secret: "generated-credential", remember: false)
        XCTAssertEqual(directory.devices.map(\.id), ["a"])
        XCTAssertEqual(directory.devices.first?.computer?.endpoint.address, "[fd7a:115c:a1e0::1]")
        let methods = await service.methods
        XCTAssertEqual(methods, ["POST", "GET"])
        XCTAssertNil(defaults.data(forKey: "tailnet.account"))
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertFalse(directory.loading)
        try directory.unlink()
        XCTAssertNil(directory.account)
        XCTAssertTrue(directory.devices.isEmpty)
    }

    @MainActor func testRememberedDirectoryUpdatesWidgetTargetsAcrossRenameHidingAndRevocation() async throws {
        let domain = "TelescopeTailnetWidget." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: UUID().uuidString)
        // Existing installations retain the linked account before the first directory refresh.
        defaults.set(try JSONEncoder().encode(account), forKey: "tailnet.account")
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        defer { try? directory.unlink() }
        XCTAssertEqual(directory.account, account)
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        try await directory.link(account, secret: "test-only-widget-credential", remember: true)
        let desk = try XCTUnwrap(directory.widgetComputers.first)
        XCTAssertEqual(directory.widgetComputers.count, 1)
        let link = try ConnectionRoute(url: ConnectionRoute.savedURL(desk.id))
        XCTAssertEqual(link, .saved(desk.id))
        XCTAssertEqual(TailnetDirectory(defaults: defaults).computerForWidget(desk.id)?.endpoint.address, "[fd7a:115c:a1e0::1]")
        let storage = try XCTUnwrap(defaults.data(forKey: "tailnet.account"))
        XCTAssertFalse(String(decoding: storage, as: UTF8.self).contains("test-only-widget-credential"))

        let original = try XCTUnwrap(directory.visibleDevices.first)
        directory.setHidden(true, device: original)
        XCTAssertTrue(directory.visibleDevices.isEmpty)
        XCTAssertEqual(directory.hiddenDevices.map(\.id), [original.id])
        XCTAssertNil(directory.computerForWidget(desk.id))
        XCTAssertNil(TailnetDirectory(defaults: defaults).computerForWidget(desk.id))

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Office","name":"office.fixture","addresses":["100.64.0.22"],"os":"linux","authorized":true}]}"#)
        await directory.refresh()
        XCTAssertTrue(directory.visibleDevices.isEmpty)
        let renamed = try XCTUnwrap(directory.hiddenDevices.first)
        XCTAssertEqual(renamed.hostname, "Office")
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertTrue(TailnetDirectory(defaults: defaults).widgetComputers.isEmpty)

        directory.setHidden(false, device: renamed)
        XCTAssertEqual(directory.visibleDevices.map(\.hostname), ["Office"])
        XCTAssertTrue(directory.hiddenDevices.isEmpty)
        XCTAssertEqual(directory.widgetComputers.map(\.id), [desk.id])
        let reopened = TailnetDirectory(defaults: defaults)
        let resolved = try XCTUnwrap(reopened.computerForWidget(desk.id))
        XCTAssertEqual(resolved.displayName, "Office")
        XCTAssertEqual(resolved.endpoint.address, "100.64.0.22")
        XCTAssertFalse(resolved.saved)

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Office","name":"office.fixture","addresses":["100.64.0.22"],"os":"linux","authorized":false}]}"#)
        await directory.refresh()
        XCTAssertTrue(directory.widgetComputers.isEmpty)
        XCTAssertNil(TailnetDirectory(defaults: defaults).computerForWidget(desk.id))
        try directory.unlink()
        XCTAssertNil(TailnetDirectory(defaults: defaults).account)
    }

    @MainActor func testHiddenDeviceFollowsItsTailnetAcrossUnlinkAndNewOAuthClient() async throws {
        let domain = "TelescopeTailnetHidden." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "first"),
                                 secret: "fixture-only", remember: false)
        directory.setHidden(true, device: try XCTUnwrap(directory.visibleDevices.first))
        try directory.unlink()
        XCTAssertTrue(directory.hiddenDevices.isEmpty)
        try await directory.link(TailnetAccount(tailnet: "other.fixture", clientID: "second"),
                                 secret: "fixture-only", remember: false)
        XCTAssertEqual(directory.visibleDevices.map(\.id), ["a"])
        XCTAssertTrue(directory.hiddenDevices.isEmpty)
        try await directory.link(TailnetAccount(tailnet: "fixture.example", clientID: "third"),
                                 secret: "fixture-only", remember: false)
        XCTAssertTrue(directory.visibleDevices.isEmpty)
        XCTAssertEqual(directory.hiddenDevices.map(\.id), ["a"])
        XCTAssertNil(defaults.data(forKey: "tailnet.account"))
    }

    @MainActor func testFoldersAndSelectionFollowDeviceIdentityWithinTheirTailnet() async throws {
        let domain = "TelescopeTailnetFolders." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "first")
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await directory.link(account, secret: "fixture-only", remember: false)
        let device = try XCTUnwrap(directory.visibleDevices.first)
        let id = try XCTUnwrap(directory.directoryID(for: device))
        directory.addFolder("   ")
        XCTAssertTrue(directory.folders.isEmpty)
        directory.addFolder("  Studio  ")
        let studio = try XCTUnwrap(directory.selectedFolder)
        XCTAssertEqual(studio.name, "Studio")
        directory.addFolder("studio")
        XCTAssertEqual(directory.folders, [studio])
        XCTAssertTrue(directory.devicesInSelectedFolder.isEmpty)

        directory.moveDevice(id, to: studio.id)
        XCTAssertEqual(directory.devicesInSelectedFolder.map(\.id), ["a"])
        directory.setHidden(true, device: device)
        XCTAssertTrue(directory.devicesInSelectedFolder.isEmpty)
        directory.setHidden(false, device: device)
        XCTAssertEqual(directory.folderID(for: device), studio.id)
        directory.addFolder("Home")
        XCTAssertEqual(directory.selectedFolder?.name, "Home")
        directory.selectFolder(studio.id)
        directory.renameFolder(studio.id, to: "Archive")
        XCTAssertEqual(directory.selectedFolder?.name, "Archive")

        let reopened = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Renamed","name":"renamed.fixture","addresses":["100.64.8.9"],"os":"linux"}]}"#)
        let otherAccount = try TailnetAccount(tailnet: "other.fixture", clientID: "second")
        try await reopened.link(otherAccount, secret: "fixture-only", remember: false)
        XCTAssertTrue(reopened.folders.isEmpty)
        XCTAssertNil(reopened.selectedFolder)
        XCTAssertEqual(reopened.devicesInSelectedFolder.map(\.id), ["a"])
        reopened.addFolder("Other")

        let sameTailnet = try TailnetAccount(tailnet: "fixture.example", clientID: "third")
        try await reopened.link(sameTailnet, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.selectedFolder?.id, studio.id)
        XCTAssertEqual(reopened.selectedFolder?.name, "Archive")
        let restored = try XCTUnwrap(reopened.devicesInSelectedFolder.first)
        XCTAssertEqual(restored.hostname, "Renamed")
        XCTAssertEqual(reopened.computer(for: restored)?.endpoint.host, "100.64.8.9")
        reopened.moveDevice(id, to: UUID())
        XCTAssertEqual(reopened.folderID(for: restored), studio.id)
        reopened.removeFolder(studio.id)
        XCTAssertNil(reopened.selectedFolder)
        XCTAssertNil(reopened.folderID(for: restored))
        XCTAssertEqual(reopened.devicesInSelectedFolder.map(\.id), ["a"])

        try await reopened.link(otherAccount, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.selectedFolder?.name, "Other")
    }

    func testPortOverridesValidateEachFieldAndTreatBlankAsDefault() throws {
        let ports = try TailnetDevicePorts(vnc: " 65535 ", ssh: "1")
        XCTAssertEqual(ports.vnc, 65535)
        XCTAssertEqual(ports.ssh, 1)
        XCTAssertNil(try TailnetDevicePorts(vnc: "", ssh: "").vnc)
        XCTAssertNil(try TailnetDevicePorts(vnc: "", ssh: " ").ssh)
        for invalid in ["0", "65536", "-22", "22x", "２２"] {
            XCTAssertThrowsError(try TailnetDevicePorts(vnc: invalid, ssh: ""))
            XCTAssertThrowsError(try TailnetDevicePorts(vnc: "", ssh: invalid))
        }
    }

    @MainActor func testDevicePortsPersistWithoutSavingOAuthCredentials() async throws {
        let domain = "TelescopeTailnetSessionPorts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: "fixture")
        let first = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await first.link(account, secret: "fixture-only", remember: false)
        let initial = try XCTUnwrap(first.visibleDevices.first)
        let id = try XCTUnwrap(first.directoryID(for: initial))
        try first.setPorts(TailnetDevicePorts(vnc: "5910", ssh: "2200"), for: id)
        XCTAssertNil(defaults.data(forKey: "tailnet.account"))
        try first.unlink()

        let reopened = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        try await reopened.link(account, secret: "fixture-only", remember: false)
        XCTAssertEqual(reopened.ports(for: id)?.ssh, 2200)
        XCTAssertEqual(reopened.computer(for: try XCTUnwrap(reopened.visibleDevices.first))?.endpoint.port, 5910)
        try reopened.setPorts(TailnetDevicePorts(vnc: "", ssh: ""), for: id)
        XCTAssertNil(TailnetDirectory(defaults: defaults).ports(for: id))
    }

    @MainActor func testPortsFollowTheDeviceAcrossRefreshAndRelaunchAndUpdateWidgetRoutes() async throws {
        let domain = "TelescopeTailnetPorts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let service = DirectoryFixture()
        let directory = TailnetDirectory(defaults: defaults) { try await service.reply(to: $0) }
        let account = try TailnetAccount(tailnet: "fixture.example", clientID: UUID().uuidString)
        defer { try? directory.unlink() }
        try await directory.link(account, secret: "test-only-port-credential", remember: true)

        let device = try XCTUnwrap(directory.visibleDevices.first)
        let id = try XCTUnwrap(directory.directoryID(for: device))
        let ports = try TailnetDevicePorts(vnc: "5907", ssh: "2201")
        XCTAssertNil(directory.ports(for: id))
        try directory.setPorts(ports, for: id)
        XCTAssertEqual(directory.computer(for: device)?.endpoint.address, "[fd7a:115c:a1e0::1]:5907")
        XCTAssertNil(directory.computer(for: device)?.ssh)
        XCTAssertEqual(directory.widgetComputers.first?.address, "[fd7a:115c:a1e0::1]:5907")
        XCTAssertEqual(TailnetDirectory(defaults: defaults).ports(for: id)?.ssh, 2201)
        XCTAssertEqual(TailnetDirectory(defaults: defaults).computerForWidget(id)?.endpoint.port, 5907)

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Renamed","name":"renamed.fixture","addresses":["100.64.0.20"],"os":"linux","authorized":true},{"id":"other","hostname":"Another","name":"another.fixture","addresses":["100.64.0.21"],"os":"linux","authorized":true}]}"#)
        await directory.refresh()
        let refreshed = try XCTUnwrap(directory.visibleDevices.first { $0.id == "a" })
        let other = try XCTUnwrap(directory.visibleDevices.first { $0.id == "other" })
        XCTAssertEqual(directory.computer(for: refreshed)?.endpoint.address, "100.64.0.20:5907")
        XCTAssertEqual(directory.computer(for: other)?.endpoint.port, 5900)
        XCTAssertEqual(TailnetDirectory(defaults: defaults).computerForWidget(id)?.displayName, "Renamed")

        try directory.unlink()
        try await directory.link(TailnetAccount(tailnet: "other.fixture", clientID: UUID().uuidString), secret: "fixture-only", remember: false)
        let differentTailnet = try XCTUnwrap(directory.visibleDevices.first { $0.id == "a" })
        XCTAssertEqual(directory.computer(for: differentTailnet)?.endpoint.port, 5900)
        XCTAssertThrowsError(try directory.setPorts(ports, for: id))
        try directory.unlink()
        try await directory.link(account, secret: "test-only-port-credential", remember: true)
        XCTAssertEqual(directory.ports(for: id), ports)

        try directory.setPorts(TailnetDevicePorts(vnc: "", ssh: ""), for: id)
        let reopened = TailnetDirectory(defaults: defaults)
        XCTAssertNil(reopened.ports(for: id))
        XCTAssertEqual(reopened.computerForWidget(id)?.endpoint.port, 5900)
    }
}

private actor DirectoryFixture {
    var methods = [String]()
    var listing = #"{"devices":[{"id":"a","hostname":"Desk","name":"desk.fixture","addresses":["fd7a:115c:a1e0::1"],"os":"linux","authorized":true},{"id":"b","hostname":"Unapproved","name":"other.fixture","addresses":["100.64.1.2"],"os":"linux","authorized":false}]}"#
    func changeListing(to value: String) { listing = value }
    func reply(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.tailscale.com")
        methods.append(request.httpMethod ?? "")
        let body: String
        switch url.path {
        case "/api/v2/oauth/token":
            body = #"{"access_token":"generated-access","token_type":"Bearer"}"#
        case "/api/v2/tailnet/fixture.example/devices", "/api/v2/tailnet/other.fixture/devices":
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer generated-access")
            body = listing
        default: throw URLError(.badURL)
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
