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
        XCTAssertFalse(directory.loading)
        try directory.unlink()
        XCTAssertNil(directory.account)
        XCTAssertTrue(directory.devices.isEmpty)
    }
}

private actor DirectoryFixture {
    var methods = [String]()
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
            body = #"{"devices":[{"id":"a","hostname":"Desk","name":"desk.fixture","addresses":["fd7a:115c:a1e0::1"],"os":"linux","authorized":true},{"id":"b","hostname":"Unapproved","name":"other.fixture","addresses":["100.64.1.2"],"os":"linux","authorized":false}]}"#
        default: throw URLError(.badURL)
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(body.utf8), response)
    }
}
