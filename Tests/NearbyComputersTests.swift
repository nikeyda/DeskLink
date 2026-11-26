import dnssd
import Network
import XCTest
@testable import DeskLink

@MainActor final class NearbyComputersTests: XCTestCase {
    func testLocalNetworkDenialCanBeDistinguishedAndClearsWhenReady() {
        let nearby = NearbyComputers()
        nearby.updateSearchState(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        XCTAssertTrue(nearby.needsLocalNetworkAccess)
        nearby.updateSearchState(.failed(.posix(.ENETDOWN)))
        XCTAssertNotNil(nearby.searchError)
        XCTAssertFalse(nearby.needsLocalNetworkAccess)
        nearby.updateSearchState(.ready)
        XCTAssertNil(nearby.searchError)
    }

    func testLocalBonjourComputerAppearsResolvesAndDisappears() async throws {
        let name = "Telescope-" + UUID().uuidString
        let port: UInt16 = 15276
        var registration: DNSServiceRef?
        let browser = NearbyComputers()
        browser.start()
        defer {
            if let registration { DNSServiceRefDeallocate(registration) }
            browser.stop()
        }
        let status = DNSServiceRegister(&registration, 0, kDNSServiceInterfaceIndexLocalOnly,
                                        name, "_rfb._tcp", "local.", nil, port.bigEndian, 0, nil, nil, nil)
        try XCTSkipIf(status == kDNSServiceErr_PolicyDenied, "Local network permission is required for Bonjour.")
        XCTAssertEqual(status, DNSServiceErrorType(kDNSServiceErr_NoError))
        let service = try XCTUnwrap(registration)
        try await waitFor { browser.entries.contains { $0.name == name } }
        let nearby = try XCTUnwrap(browser.entries.first { $0.name == name })
        var resolved: Computer?
        browser.select(nearby) { resolved = $0 }
        try await waitFor { resolved != nil || browser.errorMessage != nil }
        let computer = try XCTUnwrap(resolved, browser.errorMessage ?? "The advertised computer did not resolve.")
        XCTAssertEqual(computer.name, name)
        XCTAssertEqual(computer.endpoint.port, port)
        XCTAssertFalse(computer.endpoint.host.isEmpty)
        XCTAssertFalse(computer.saved)
        browser.retry()
        XCTAssertTrue(browser.entries.isEmpty)
        try await waitFor { browser.entries.contains { $0.id == nearby.id } }
        DNSServiceRefDeallocate(service)
        registration = nil
        try await waitFor { !browser.entries.contains { $0.id == nearby.id } }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
