import Foundation
import XCTest
@testable import DeskLink
#if targetEnvironment(macCatalyst)
import Darwin
#endif

final class WakeOnLANTests: XCTestCase {
    func testHardwareAddressRoundTripsAndBuildsTheExactPacket() throws {
        let address = try XCTUnwrap(WakeHardwareAddress(" 02-13-2a-45-67-89 "))
        XCTAssertEqual(address.text, "02:13:2A:45:67:89")
        XCTAssertEqual(WakeHardwareAddress("02132a456789"), address)
        XCTAssertEqual(try JSONDecoder().decode(WakeHardwareAddress.self, from: JSONEncoder().encode(address)), address)
        XCTAssertEqual(address.packet, Data(Array(repeating: UInt8(0xff), count: 6) +
                                          Array(repeating: [UInt8(2), 0x13, 0x2a, 0x45, 0x67, 0x89], count: 16).flatMap { $0 }))
        for invalid in ["ff:ff:ff:ff:ff:ff", "01:20:30:40:50:60", "000000000000", "02:13-2A:45:67:89", "02:13:2A:45:67:", "02132A45678g"] {
            XCTAssertNil(WakeHardwareAddress(invalid), invalid)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(WakeHardwareAddress.self, from: Data("\"bad\"".utf8)))
    }

    func testNativeLibraryPreservesWakeSettingsAndReadsOlderRecords() throws {
        let endpoint = try Endpoint(address: "192.168.10.2")
        let original = Computer(name: "Test desktop", endpoint: endpoint)
        var archive = LibraryArchive(computers: [original])
        XCTAssertNil(try LibraryArchive.read(archive.encoded()).computers.first?.wakeHardwareAddress)
        archive.computers[0].wakeHardwareAddress = WakeHardwareAddress("02:13:2A:45:67:89")
        XCTAssertEqual(try LibraryArchive.read(archive.encoded()), archive)
    }

    #if targetEnvironment(macCatalyst)
    func testUsesTheAttachedSubnetAndNeverSelectsSelfNetworkOrBroadcast() throws {
        func ip(_ value: String) throws -> UInt32 { try XCTUnwrap(WakeOnLAN.address(value)) }
        let broad = try WakeOnLAN.Interface(index: 1, address: ip("192.168.20.1"), mask: ip("255.255.0.0"))
        let narrow = try WakeOnLAN.Interface(index: 2, address: ip("192.168.10.1"), mask: ip("255.255.255.0"))
        let local = try ip("192.168.10.27")
        let route = WakeOnLAN.interface(for: local, in: [broad, narrow])
        XCTAssertEqual(route?.index, 2)
        XCTAssertEqual(route?.broadcast(for: local), try ip("192.168.10.255"))
        XCTAssertNil(WakeOnLAN.interface(for: try ip("203.0.113.2"), in: [broad, narrow]))
        for address in ["192.168.10.0", "192.168.10.1", "192.168.10.255"] {
            XCTAssertNil(WakeOnLAN.interface(for: try ip(address), in: [broad, narrow]), address)
        }
    }

    func testResolvesHostnamesAndUsesTheFirstAttachedRemoteAddress() async throws {
        let lookup = await WakeOnLAN.addresses(for: "localhost")
        XCTAssertTrue(lookup.contains(INADDR_LOOPBACK))
        let testInterface = WakeOnLAN.Interface(index: 4, address: 0x7f00_0002, mask: 0xff00_0000)
        let resolvedRoute = WakeOnLAN.broadcastRoute(for: lookup, in: [testInterface])
        XCTAssertEqual(resolvedRoute?.interfaceIndex, 4)
        XCTAssertEqual(resolvedRoute?.destination, 0x7fff_ffff)

        let literal = await WakeOnLAN.addresses(for: "192.168.10.27")
        let ipv6 = await WakeOnLAN.addresses(for: "::1")
        XCTAssertEqual(literal, [try XCTUnwrap(WakeOnLAN.address("192.168.10.27"))])
        XCTAssertTrue(ipv6.isEmpty)

        let localAddress = try XCTUnwrap(WakeOnLAN.address("192.168.10.1"))
        let mask = try XCTUnwrap(WakeOnLAN.address("255.255.255.0"))
        let offLink = try XCTUnwrap(WakeOnLAN.address("203.0.113.2"))
        let network = [WakeOnLAN.Interface(index: 5, address: localAddress, mask: mask)]
        XCTAssertNil(WakeOnLAN.broadcastRoute(for: lookup + [localAddress, offLink], in: network))
        let route = WakeOnLAN.broadcastRoute(for: [offLink, localAddress] + literal, in: network)
        XCTAssertEqual(route?.destination, WakeOnLAN.address("192.168.10.255"))
        XCTAssertEqual(route?.interfaceIndex, 5)
    }

    @MainActor func testBroadcastIsSkippedForAnAwakeServerAndRunsOnceForASleepingOne() async throws {
        var broadcasts = 0
        try await WakeOnLAN.waitForDesktop(delay: .zero, probe: { .responding }, send: { broadcasts += 1; return true })
        XCTAssertEqual(broadcasts, 0)
        var samples: [ScreenSharingCheck.Outcome] = [.unavailable, .timedOut, .responding]
        try await WakeOnLAN.waitForDesktop(delay: .zero, probe: { samples.removeFirst() }, send: { broadcasts += 1; return true })
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(broadcasts, 1)
    }

    @MainActor func testCancellationStopsWakePollingBeforeAnyConnectionCanStart() async throws {
        let (events, sent) = AsyncStream<Void>.makeStream()
        var probes = 0
        let preparation = Task { @MainActor in
            defer { sent.finish() }
            try await WakeOnLAN.waitForDesktop(delay: .seconds(4), probe: { probes += 1; return .unavailable }, send: {
                sent.yield(())
                return true
            })
        }
        var iterator = events.makeAsyncIterator()
        let didSend = await iterator.next() != nil
        XCTAssertTrue(didSend)
        preparation.cancel()
        do {
            try await preparation.value
            XCTFail("Cancelled preparation must not open the session")
        } catch is CancellationError {}
        XCTAssertEqual(probes, 1)
    }

    @MainActor func testDesktopThatStaysAsleepGetsOnlyABoundedNumberOfProbes() async throws {
        var probes = 0
        var broadcasts = 0
        try await WakeOnLAN.waitForDesktop(attempts: 3, delay: .zero, probe: {
            probes += 1
            return .timedOut
        }, send: {
            broadcasts += 1
            return true
        })
        XCTAssertEqual(probes, 4)
        XCTAssertEqual(broadcasts, 1)
    }

    func testSocketSendsThePacketToALoopbackReceiver() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        XCTAssertEqual(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                if Darwin.bind(descriptor, address, size) != 0 {
                    let failure = errno
                    if failure == EPERM || failure == EACCES {
                        throw XCTSkip("The loopback UDP fixture requires inbound networking in the test host")
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
                }
                XCTAssertEqual(getsockname(descriptor, address, &size), 0)
            }
        }
        let payload = try XCTUnwrap(WakeHardwareAddress("02:13:2A:45:67:89")).packet
        XCTAssertTrue(WakeOnLAN.sendPacket(payload, to: INADDR_LOOPBACK, interface: if_nametoindex("lo0"),
                                          port: UInt16(bigEndian: address.sin_port)))
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(count, payload.count)
        XCTAssertEqual(Data(buffer.prefix(max(0, count))), payload)
    }
    #endif
}
