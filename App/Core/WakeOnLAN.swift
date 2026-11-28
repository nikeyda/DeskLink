import Foundation
import Network
#if targetEnvironment(macCatalyst)
import Darwin
#endif

struct WakeHardwareAddress: Codable, Equatable, Sendable {
    let text: String

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups: [Substring]
        if value.contains(":") || value.contains("-") {
            groups = value.split(separator: value.contains(":") ? ":" : "-", omittingEmptySubsequences: false)
        } else {
            guard value.utf8.count == 12, value.utf8.allSatisfy(Self.isHex) else { return nil }
            groups = stride(from: 0, to: 12, by: 2).map { offset in
                let index = value.index(value.startIndex, offsetBy: offset)
                return value[index..<value.index(index, offsetBy: 2)]
            }
        }
        guard groups.count == 6, groups.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy(Self.isHex) }),
              let first = UInt8(groups[0], radix: 16), first & 1 == 0,
              groups.contains(where: { $0 != "00" }) else { return nil }
        self.text = groups.joined(separator: ":").uppercased()
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    var packet: Data {
        let address = text.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        var payload = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { payload.append(contentsOf: address) }
        return payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let validated = Self(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Wake-on-LAN hardware address")
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

#if targetEnvironment(macCatalyst)
enum WakeOnLAN {
    struct Interface: Sendable {
        let index: UInt32
        let address: UInt32
        let mask: UInt32

        func broadcast(for target: UInt32) -> UInt32? {
            let network = address & mask
            let broadcast = network | ~mask
            guard target & mask == network, target != network, target != broadcast, target != address else { return nil }
            return broadcast
        }
    }

    static func address(_ host: String) -> UInt32? {
        IPv4Address(host)?.rawValue.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func interface(for target: UInt32, in interfaces: [Interface]) -> Interface? {
        guard !interfaces.contains(where: { $0.address == target }) else { return nil }
        let attached = interfaces.filter { target & $0.mask == $0.address & $0.mask }
        guard let route = attached.max(by: { $0.mask.nonzeroBitCount < $1.mask.nonzeroBitCount }),
              route.broadcast(for: target) != nil else { return nil }
        return route
    }

    @MainActor static func prepare(_ endpoint: Endpoint, hardwareAddress: WakeHardwareAddress) async throws {
        let targets = await addresses(for: endpoint.host)
        try Task.checkCancellation()
        guard let route = broadcastRoute(for: targets, in: interfaces()) else { return }
        try await waitForDesktop(probe: { await ScreenSharingCheck.check(endpoint, timeout: .milliseconds(450)) }, send: {
            sendPacket(hardwareAddress.packet, to: route.destination, interface: route.interfaceIndex)
        })
    }

    static func broadcastRoute(for targets: [UInt32],
                               in interfaces: [Interface]) -> (destination: UInt32, interfaceIndex: UInt32)? {
        for target in targets {
            if let route = interface(for: target, in: interfaces), let destination = route.broadcast(for: target) {
                return (destination, route.index)
            }
        }
        return nil
    }

    static func addresses(for host: String) async -> [UInt32] {
        if let literal = address(host) { return [literal] }
        guard !host.contains(":"), !Task.isCancelled else { return [] }
        let (results, output) = AsyncStream.makeStream(of: [UInt32].self, bufferingPolicy: .bufferingOldest(1))
        DispatchQueue.global(qos: .utility).async {
            output.yield(resolveIPv4(host))
            output.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            output.finish()
        }
        defer {
            deadline.cancel()
            output.finish()
        }
        var iterator = results.makeAsyncIterator()
        return await iterator.next() ?? []
    }

    private static func resolveIPv4(_ host: String) -> [UInt32] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [UInt32] = []
        var next: UnsafeMutablePointer<addrinfo>? = result
        while let entry = next?.pointee {
            next = entry.ai_next
            guard let socketAddress = entry.ai_addr,
                  entry.ai_addrlen >= MemoryLayout<sockaddr_in>.size else { continue }
            let ipv4 = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            addresses.append(ipv4)
        }
        return addresses
    }

    @MainActor static func waitForDesktop(attempts: Int = 8, delay: Duration = .seconds(1),
                                         probe: () async -> ScreenSharingCheck.Outcome?, send: () -> Bool) async throws {
        let initial = await probe()
        try Task.checkCancellation()
        guard initial == .unavailable || initial == .timedOut, send() else { return }
        for _ in 0..<attempts {
            try await Task.sleep(for: delay)
            let status = await probe()
            try Task.checkCancellation()
            if status == .responding || status == .unexpectedResponse { return }
        }
    }

    static func sendPacket(_ packet: Data, to address: UInt32, interface: UInt32, port: UInt16 = 9) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var enabled: Int32 = 1
        var index = interface
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0 else { return false }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = address.bigEndian
        return withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                packet.withUnsafeBytes { bytes in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == bytes.count
                }
            }
        }
    }

    private static func interfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        let required = UInt32(IFF_UP | IFF_BROADCAST)
        var next: UnsafeMutablePointer<ifaddrs>? = first
        var result: [Interface] = []
        while let entry = next?.pointee {
            next = entry.ifa_next
            guard entry.ifa_flags & required == required, entry.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  let netmask = entry.ifa_netmask, netmask.pointee.sa_family == AF_INET else { continue }
            let index = if_nametoindex(entry.ifa_name)
            guard index != 0 else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(Interface(index: index, address: ip, mask: mask))
        }
        return result
    }
}
#endif
