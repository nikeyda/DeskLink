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

    func testReturningToAnActiveBrowserRetriesOnlyLocalNetworkDenials() {
        let nearby = NearbyComputers()
        let permissionDenied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        nearby.updateSearchState(.failed(permissionDenied))
        nearby.retryAfterLocalNetworkDenial()
        XCTAssertEqual(nearby.searchError, permissionDenied)

        nearby.start()
        defer { nearby.stop() }
        let networkDown = NWError.posix(.ENETDOWN)
        nearby.updateSearchState(.failed(networkDown))
        nearby.retryAfterLocalNetworkDenial()
        XCTAssertEqual(nearby.searchError, networkDown)

        nearby.updateSearchState(.failed(permissionDenied))
        nearby.retryAfterLocalNetworkDenial()
        XCTAssertNil(nearby.searchError)
        XCTAssertTrue(nearby.isSearching)
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

    func testNearbyMacFamilyUsesOnlyRecognizedAdvertisedModels() throws {
        func family(_ model: String) -> NearbyMacFamily? {
            NearbyMacFamily(txtRecord: NetService.data(fromTXTRecord: ["model": Data(model.utf8)]))
        }
        XCTAssertEqual(family("Mac17,2"), .macBook)
        XCTAssertEqual(family("MacBookPro18,1"), .macBook)
        XCTAssertEqual(family("Mac16,11"), .macMini)
        XCTAssertEqual(family("Macmini9,1"), .macMini)
        XCTAssertEqual(family("iMac21,1"), .iMac)
        XCTAssertEqual(family("Mac16,9"), .macStudio)
        XCTAssertEqual(family("Mac14,8"), .macPro)
        XCTAssertNil(family("Mac99,1"))
        XCTAssertNil(family("MacBookPro"))
        XCTAssertNil(family("A PC named Mac mini"))

        let service = NetService(domain: "local.", type: "_rfb._tcp.", name: "Edit Bay")
        let endpoint = try Endpoint(address: "edit-bay.local")
        var entry = NearbyComputer(service: service, endpoint: endpoint)
        XCTAssertEqual(entry.symbol, "desktopcomputer")
        XCTAssertEqual(entry.detail, endpoint.address)
        XCTAssertFalse(entry.matches(LibrarySearchQuery("mac mini")))
        entry.macFamily = .macMini
        XCTAssertEqual(entry.detail, "Mac mini · " + endpoint.address)
        XCTAssertTrue(entry.matches(LibrarySearchQuery("edit mac mini 5900")))
        let named = NearbyComputer(service: NetService(domain: "local.", type: "_rfb._tcp.", name: "Library Mac mini"),
                                   endpoint: endpoint, macFamily: .macMini)
        XCTAssertEqual(named.detail, endpoint.address)
    }

    func testLocalBonjourComputerAppearsResolvesAndDisappears() async throws {
        let name = "Telescope Lab. " + String(UUID().uuidString.prefix(8))
        let port: UInt16 = 15276
        var registration: DNSServiceRef?
        var metadata: DNSServiceRef?
        let browser = NearbyComputers(localFilter: nil)
        browser.start()
        defer {
            if let registration { DNSServiceRefDeallocate(registration) }
            if let metadata { DNSServiceRefDeallocate(metadata) }
            browser.stop()
        }
        let status = DNSServiceRegister(&registration, 0, kDNSServiceInterfaceIndexLocalOnly,
                                        name, "_rfb._tcp", "local.", nil, port.bigEndian, 0, nil, nil, nil)
        try XCTSkipIf(status == kDNSServiceErr_PolicyDenied, "Local network permission is required for Bonjour.")
        XCTAssertEqual(status, DNSServiceErrorType(kDNSServiceErr_NoError))
        XCTAssertEqual(DNSServiceCreateConnection(&metadata), DNSServiceErrorType(kDNSServiceErr_NoError))
        let metadataService = try XCTUnwrap(metadata)
        var address = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        XCTAssertEqual(DNSServiceConstructFullName(&address, name, "_device-info._tcp", "local."), 0)
        let txt = NetService.data(fromTXTRecord: ["model": Data("Mac16,10".utf8)])
        var modelRecord: DNSRecordRef?
        let metadataStatus = txt.withUnsafeBytes { bytes in
            DNSServiceRegisterRecord(metadataService, &modelRecord, DNSServiceFlags(kDNSServiceFlagsUnique),
                                     kDNSServiceInterfaceIndexLocalOnly, address, UInt16(kDNSServiceType_TXT),
                                     UInt16(kDNSServiceClass_IN), UInt16(bytes.count), bytes.baseAddress, 0,
                                     { _, _, _, _, _ in }, nil)
        }
        XCTAssertEqual(metadataStatus, DNSServiceErrorType(kDNSServiceErr_NoError))
        let service = try XCTUnwrap(registration)
        try await waitFor { browser.entries.contains { $0.name == name && $0.endpoint?.port == port && $0.macFamily == .macMini } }
        let nearby = try XCTUnwrap(browser.entries.first { $0.name == name })
        XCTAssertEqual(nearby.symbol, "macmini")
        let host = try XCTUnwrap(nearby.endpoint?.host)
        let ip = try XCTUnwrap(nearby.numericAddresses.first)
        let socket = ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
        XCTAssertTrue(nearby.matches(LibrarySearchQuery("\(host):\(port)")))
        XCTAssertTrue(nearby.matches(LibrarySearchQuery(socket)))
        var resolved: Computer?
        var resolvedAddresses: Set<Endpoint> = []
        browser.select(nearby) { computer, addresses in
            resolved = computer
            resolvedAddresses = addresses
        }
        try await waitFor { resolved != nil || browser.errorMessage != nil }
        let computer = try XCTUnwrap(resolved, browser.errorMessage ?? "The advertised computer did not resolve.")
        XCTAssertEqual(computer.name, name)
        XCTAssertEqual(computer.endpoint.port, port)
        XCTAssertFalse(computer.endpoint.host.isEmpty)
        XCTAssertFalse(computer.saved)
        XCTAssertTrue(resolvedAddresses.contains(try Endpoint(address: ip, defaultPort: port)))
        browser.retry()
        XCTAssertTrue(browser.entries.isEmpty)
        try await waitFor { browser.entries.contains { $0.id == nearby.id } }
        browser.updateSearchState(.waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))))
        XCTAssertTrue(browser.entries.isEmpty)
        browser.retryAfterLocalNetworkDenial()
        try await waitFor { browser.searchError == nil && browser.entries.contains { $0.id == nearby.id } }
        DNSServiceRefDeallocate(service)
        registration = nil
        try await waitFor { !browser.entries.contains { $0.id == nearby.id } }
        browser.select(nearby) { _, _ in XCTFail("An expired advertisement must not open a connection.") }
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
        browser.select(visible) { computer, _ in selected = computer }
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
        if let expected = ProcessInfo.processInfo.environment["DESKLINK_LIVE_MAC_FAMILY"] {
            try await waitFor { unfiltered.entries.contains { $0.id == service.id && $0.macFamily?.rawValue == expected } }
        }
        var resolved: Computer?
        unfiltered.select(service) { computer, _ in resolved = computer }
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
