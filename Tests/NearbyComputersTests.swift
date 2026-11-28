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

    func testLocalIdentityAcceptsShortBonjourHostAndDoesNotGuessFromAnotherDomain() {
        let localAddresses: Set<String> = ["192.0.2.12"]
        XCTAssertTrue(NearbyLocalIdentity.matches(host: "studio-Mac.LOCAL.", addresses: [], localHost: "Studio-Mac",
                                                 localAddresses: localAddresses))
        XCTAssertFalse(NearbyLocalIdentity.matches(host: "studio-mac.local.", addresses: ["192.0.2.15"],
                                                  localHost: "studio-mac.example.org", localAddresses: localAddresses))
        XCTAssertTrue(NearbyLocalIdentity.matches(host: "renamed.local.", addresses: ["192.0.2.12"],
                                                 localHost: "studio-mac.example.org", localAddresses: localAddresses))
    }

    func testNearbySearchMatchesTheDisplayNameAndResolvedAddress() throws {
        let service = NetService(domain: "local.", type: "_rfb._tcp.", name: "Design Computer")
        let endpoint = try Endpoint(address: "studio-mac.local")
        let entry = NearbyComputer(service: service, endpoint: endpoint,
                                   numericAddresses: ["192.0.2.12", "fe80::1%en0"])
        XCTAssertTrue(entry.matches(LibrarySearchQuery("design studio-mac")))
        XCTAssertTrue(entry.matches(LibrarySearchQuery("5900")))
        XCTAssertTrue(entry.matches(LibrarySearchQuery("design 192.0.2.12:5900")))
        XCTAssertTrue(entry.matches(LibrarySearchQuery("[FE80::1%en0]:5900")))
        XCTAssertFalse(entry.matches(LibrarySearchQuery("studio-mac 5901")))
    }

    func testLocalBonjourComputerAppearsResolvesAndDisappears() async throws {
        let name = "Telescope-" + UUID().uuidString
        let port: UInt16 = 15276
        var registration: DNSServiceRef?
        let browser = NearbyComputers(localFilter: nil)
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
        try await waitFor { browser.entries.contains { $0.name == name && $0.endpoint?.port == port } }
        let nearby = try XCTUnwrap(browser.entries.first { $0.name == name })
        let host = try XCTUnwrap(nearby.endpoint?.host)
        let ip = try XCTUnwrap(nearby.numericAddresses.first)
        let socket = ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
        XCTAssertTrue(nearby.matches(LibrarySearchQuery("\(host):\(port)")))
        XCTAssertTrue(nearby.matches(LibrarySearchQuery(socket)))
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
        browser.select(nearby) { _ in XCTFail("An expired advertisement must not open a connection.") }
        XCTAssertNotNil(browser.errorMessage)
        XCTAssertFalse(browser.isResolvingSelection)
    }

    #if targetEnvironment(macCatalyst)
    func testThisMacIsNotPublishedWhileOtherDiscoveredResultsRemainUsable() async throws {
        let token = UUID().uuidString.prefix(8)
        let localName = "Local-\(token)"
        let visibleName = "Visible-\(token)"
        var inspectedLocal = false
        let browser = NearbyComputers(localFilter: { service in
            if service.name == localName {
                inspectedLocal = true
                return NearbyComputers.defaultLocalFilter?(service) == true
            }
            // The second registration simulates a peer after address classification.
            return false
        })
        var localRegistration: DNSServiceRef?
        var visibleRegistration: DNSServiceRef?
        browser.start()
        defer {
            if let localRegistration { DNSServiceRefDeallocate(localRegistration) }
            if let visibleRegistration { DNSServiceRefDeallocate(visibleRegistration) }
            browser.stop()
        }
        let localStatus = DNSServiceRegister(&localRegistration, 0, kDNSServiceInterfaceIndexLocalOnly,
                                              localName, "_rfb._tcp", "local.", nil, UInt16(15276).bigEndian, 0, nil, nil, nil)
        let visibleStatus = DNSServiceRegister(&visibleRegistration, 0, kDNSServiceInterfaceIndexLocalOnly,
                                                visibleName, "_rfb._tcp", "local.", nil, UInt16(15277).bigEndian, 0, nil, nil, nil)
        try XCTSkipIf(localStatus == kDNSServiceErr_PolicyDenied || visibleStatus == kDNSServiceErr_PolicyDenied,
                      "Local network permission is required for Bonjour.")
        XCTAssertEqual(localStatus, DNSServiceErrorType(kDNSServiceErr_NoError))
        XCTAssertEqual(visibleStatus, DNSServiceErrorType(kDNSServiceErr_NoError))
        var displayedLocal = false
        try await waitFor {
            displayedLocal = displayedLocal || browser.entries.contains { $0.name == localName }
            return inspectedLocal && browser.entries.contains { $0.name == visibleName }
        }
        XCTAssertFalse(displayedLocal)
        XCTAssertFalse(browser.entries.contains { $0.name == localName })
        let visible = try XCTUnwrap(browser.entries.first { $0.name == visibleName })
        XCTAssertNotNil(visible.address)
        var selected: Computer?
        browser.select(visible) { selected = $0 }
        try await waitFor { selected != nil || browser.errorMessage != nil }
        XCTAssertEqual(selected?.endpoint.port, 15277)
    }

    func testBuiltInScreenSharingStaysOutOfTheDefaultMacBrowser() async throws {
        guard let name = ProcessInfo.processInfo.environment["DESKLINK_LIVE_SCREEN_SHARING_NAME"] else {
            throw XCTSkip("Set DESKLINK_LIVE_SCREEN_SHARING_NAME to the Mac's advertised Screen Sharing service.")
        }
        let unfiltered = NearbyComputers(localFilter: nil)
        let browser = NearbyComputers()
        unfiltered.start()
        browser.start()
        defer {
            unfiltered.stop()
            browser.stop()
        }
        try await waitFor { unfiltered.entries.contains { $0.name == name } }
        let service = try XCTUnwrap(unfiltered.entries.first { $0.name == name })
        var resolved: Computer?
        unfiltered.select(service) { resolved = $0 }
        let deadline = Date().addingTimeInterval(12)
        repeat {
            XCTAssertFalse(browser.entries.contains { $0.id == service.id })
            if resolved != nil, !browser.isSearching { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        XCTAssertEqual(resolved?.endpoint.port, 5900)
        XCTAssertNil(browser.searchError)
        XCTAssertFalse(browser.isSearching)
    }
    #endif

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
