#if targetEnvironment(macCatalyst)
import XCTest
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
        let ssh = try XCTUnwrap(reopened.configuration?.service.link(to: external))
        XCTAssertEqual(try ConnectionRoute(url: ssh), .secureAddress(try Endpoint(address: "2001:db8::10"), sshPort: 42422))
        reopened.apply(.manual(.screenSharing, external))
        let vnc = try XCTUnwrap(reopened.configuration?.service.link(to: external))
        XCTAssertEqual(try ConnectionRoute(url: vnc), .address(external))
        let links = try JSONEncoder().encode(["ssh": ssh.absoluteString, "direct": vnc.absoluteString])
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
        let initial = MacRemoteAccess.mappingStatus(code: 0, address: UInt32(0xCB00712A).bigEndian, port: UInt16(48130).bigEndian)
        reply?(initial)
        XCTAssertEqual(access.status, .ready(try Endpoint(address: "203.0.113.42:48130")))
        reply?(MacRemoteAccess.mappingStatus(code: 0, address: 0, port: 0))
        XCTAssertEqual(access.status, .unavailable(nil))
        reply?(MacRemoteAccess.mappingStatus(code: 0, address: UInt32(0xCB00712B).bigEndian, port: UInt16(48231).bigEndian))
        XCTAssertEqual(access.status, .ready(try Endpoint(address: "203.0.113.43:48231")))
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
}
#endif
