import XCTest
@testable import DeskLink

final class TailnetTests: XCTestCase {
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

    @MainActor func testRememberedDirectoryUpdatesWidgetTargetsAcrossRelaunchRenameAndRevocation() async throws {
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

        await service.changeListing(to: #"{"devices":[{"id":"a","hostname":"Office","name":"office.fixture","addresses":["100.64.0.22"],"os":"linux","authorized":true}]}"#)
        await directory.refresh()
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
        case "/api/v2/tailnet/fixture.example/devices":
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer generated-access")
            body = listing
        default: throw URLError(.badURL)
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
