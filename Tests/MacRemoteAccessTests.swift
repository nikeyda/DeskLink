#if targetEnvironment(macCatalyst)
import XCTest
import Network
import dnssd
@testable import DeskLink

@MainActor final class MacRemoteAccessTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "Telescope-MacAccess-" + UUID().uuidString

    override func setUp() async throws { defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testManualAddressMakesTheExpectedConnectionLinkAndSurvivesRelaunch() throws {
        let mapping: MacRemoteAccess.StartMapping = { _, _ in XCTFail("Manual mode contacted the router"); return {} }
        let access = MacRemoteAccess(defaults: defaults, startMapping: mapping)
        XCTAssertNil(access.configuration)
        let external = try Endpoint(address: "[2001:db8::10]:42422")
        access.apply(.manual(.ssh, external))
        let reopened = MacRemoteAccess(defaults: defaults, startMapping: mapping)
        XCTAssertEqual(reopened.status, .ready(external))
        let ssh = try XCTUnwrap(reopened.connectionLink())
        XCTAssertEqual(try ConnectionRoute(url: ssh), .secureAddress(try Endpoint(address: "2001:db8::10"), sshPort: 42422))
        let observingSSH = try XCTUnwrap(reopened.connectionLink(observe: true))
        XCTAssertEqual(try ConnectionRoute(url: observingSSH),
                       .sharedAddress(try Endpoint(address: "2001:db8::10"), sshPort: 42422, server: nil,
                                      options: .init(observe: true)))
        reopened.apply(.manual(.screenSharing, external))
        let vnc = try XCTUnwrap(reopened.connectionLink())
        XCTAssertEqual(try ConnectionRoute(url: vnc), .address(external))
        let observingVNC = try XCTUnwrap(reopened.connectionLink(observe: true))
        XCTAssertEqual(try ConnectionRoute(url: observingVNC),
                       .sharedAddress(external, sshPort: nil, server: nil, options: .init(observe: true)))
        let links = try JSONEncoder().encode(["ssh": ssh.absoluteString, "direct": vnc.absoluteString,
                                             "sshObserve": observingSSH.absoluteString, "directObserve": observingVNC.absoluteString])
        let fixture = XCTAttachment(data: links, uniformTypeIdentifier: "public.json")
        fixture.name = "mac-remote-access-links.json"
        fixture.lifetime = .keepAlways
        add(fixture)
        reopened.apply(nil)
        XCTAssertEqual(MacRemoteAccess(defaults: defaults, startMapping: mapping).status, .off)
    }

    func testAutomaticMappingTracksChangesAndCancelsOnDisableOrSwitch() throws {
        var requested: [UInt16] = []
        var cancelled = 0
        var reply: ((MacRemoteAccess.Status) -> Void)?
        let mapping: MacRemoteAccess.StartMapping = { port, update in
            requested.append(port)
            reply = update
            return { cancelled += 1 }
        }
        let access = MacRemoteAccess(defaults: defaults, startMapping: mapping)
        XCTAssertTrue(requested.isEmpty)
        access.apply(.automatic(.ssh))
        XCTAssertEqual(access.status, .waiting)
        reply?(try mappingResponse("192.0.0.9", port: 48130))
        XCTAssertEqual(access.status, .ready(try Endpoint(address: "192.0.0.9:48130")))
        XCTAssertNotNil(access.connectionLink())
        reply?(MacRemoteAccess.mappingStatus(code: 0, address: 0, port: 0))
        XCTAssertEqual(access.status, .unavailable(nil))
        XCTAssertNil(access.connectionLink())
        reply?(try mappingResponse("192.0.0.10", port: 48231))
        XCTAssertEqual(access.status, .ready(try Endpoint(address: "192.0.0.10:48231")))
        XCTAssertNotNil(access.connectionLink(observe: true))
        access.apply(.automatic(.screenSharing))
        XCTAssertEqual(requested, [22, 5900])
        XCTAssertEqual(cancelled, 1)
        let code = Int32(kDNSServiceErr_NATPortMappingUnsupported)
        reply?(MacRemoteAccess.mappingStatus(code: code, address: 0, port: 0))
        XCTAssertEqual(access.status, .unavailable(code))
        access.apply(nil)
        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(access.status, .off)
    }

    func testPrivateRouterAddressAndDoubleNATDoNotProduceShareLinks() throws {
        var reply: ((MacRemoteAccess.Status) -> Void)?
        let access = MacRemoteAccess(defaults: defaults) { _, update in reply = update; return {} }
        access.apply(.automatic(.ssh))
        for host in ["10.0.0.1", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.2.2",
                     "172.16.2.2", "172.31.255.254", "192.168.0.2", "192.0.2.9", "198.18.0.1", "224.0.0.1"] {
            let local = try Endpoint(address: "\(host):42422")
            reply?(try mappingResponse(host, port: 42422))
            XCTAssertEqual(access.status, .notPublic(local), host)
            XCTAssertNil(access.connectionLink(), host)
            XCTAssertNil(access.connectionLink(observe: true), host)
        }
        let doubleNAT = Int32(kDNSServiceErr_DoubleNAT)
        reply?(try mappingResponse("192.0.0.9", port: 42422, code: doubleNAT))
        XCTAssertEqual(access.status, .notPublic(try Endpoint(address: "192.0.0.9:42422")))
        XCTAssertNil(access.connectionLink())
        reply?(MacRemoteAccess.mappingStatus(code: doubleNAT, address: 0, port: 0))
        XCTAssertEqual(access.status, .notPublic(nil))

        // An explicit address can be intentionally reachable via a VPN.
        let manual = try Endpoint(address: "100.64.0.4:42422")
        access.apply(.manual(.ssh, manual))
        XCTAssertEqual(access.status, .ready(manual))
        XCTAssertNotNil(access.connectionLink(observe: true))
    }

    func testSupersededRepliesCannotReplaceTheCurrentAddressOrRestoreSharing() throws {
        var replies: [(MacRemoteAccess.Status) -> Void] = []
        let stale = try mappingResponse("192.0.0.9", port: 42422)
        let access = MacRemoteAccess(defaults: defaults) { _, update in
            replies.append(update)
            return { update(stale) }
        }
        access.apply(.automatic(.ssh))
        access.apply(.automatic(.screenSharing))
        replies[0](stale)
        XCTAssertEqual(access.status, .waiting)
        XCTAssertNil(access.connectionLink())

        let active = try mappingResponse("192.0.0.10", port: 42600)
        replies[1](active)
        XCTAssertEqual(access.status, active)
        XCTAssertNotNil(access.connectionLink())

        let manual = try Endpoint(address: "studio.fixture.invalid:42800")
        access.apply(.manual(.screenSharing, manual))
        replies[1](stale)
        XCTAssertEqual(access.status, .ready(manual))
        let link = try XCTUnwrap(access.connectionLink())
        XCTAssertEqual(try ConnectionRoute(url: link), .address(manual))
        access.apply(nil)
        replies[0](stale)
        replies[1](active)
        XCTAssertEqual(access.status, .off)
        XCTAssertNil(access.connectionLink(observe: true))
    }

    func testFailureToStartCanBeRetriedAndAnEnabledConfigurationRestarts() throws {
        var attempts = 0
        let mapping: MacRemoteAccess.StartMapping = { _, _ in
            attempts += 1
            if attempts == 1 { throw NSError(domain: "test", code: -42) }
            return {}
        }
        let access = MacRemoteAccess(defaults: defaults, startMapping: mapping)
        access.apply(.automatic(.ssh))
        XCTAssertEqual(access.status, .unavailable(-42))
        access.apply(access.configuration)
        XCTAssertEqual(access.status, .waiting)
        let reopened = MacRemoteAccess(defaults: defaults, startMapping: mapping)
        XCTAssertEqual(reopened.configuration, .automatic(.ssh))
        XCTAssertEqual(attempts, 3)
    }

    private func mappingResponse(_ host: String, port: UInt16, code: Int32 = 0) throws -> MacRemoteAccess.Status {
        let ipv4 = try XCTUnwrap(IPv4Address(host))
        let address = ipv4.rawValue.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return MacRemoteAccess.mappingStatus(code: code, address: address, port: port.bigEndian)
    }
}
#endif
