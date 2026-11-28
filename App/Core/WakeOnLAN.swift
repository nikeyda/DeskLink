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
        guard let target = address(endpoint.host),
              let route = interface(for: target, in: interfaces()), let broadcast = route.broadcast(for: target) else { return }
        try await waitForDesktop(probe: { await ScreenSharingCheck.check(endpoint, timeout: .milliseconds(450)) }, send: {
            sendPacket(hardwareAddress.packet, to: broadcast, interface: route.index)
        })
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
