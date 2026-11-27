#if targetEnvironment(macCatalyst)
import Foundation
import Network
import Observation
import dnssd

enum MacAccessService: String, Codable, CaseIterable {
    case ssh, screenSharing

    var port: UInt16 { self == .ssh ? 22 : 5900 }

    func link(to endpoint: Endpoint, observe: Bool = false) -> URL? {
        let options = ConnectionRoute.SharedOptions(observe: observe ? true : nil)
        if self == .ssh {
            guard let desktop = try? Endpoint(address: endpoint.host) else { return nil }
            return ConnectionRoute.sharing(desktop, sshPort: endpoint.port, options: options)
        }
        return ConnectionRoute.sharing(endpoint, sshPort: nil, options: options)
    }
}

@MainActor @Observable
final class MacRemoteAccess {
    enum Configuration: Codable, Equatable {
        case automatic(MacAccessService)
        case manual(MacAccessService, Endpoint)

        var service: MacAccessService {
            switch self {
            case .automatic(let service), .manual(let service, _): service
            }
        }
    }

    enum Status: Equatable {
        case off, waiting, unavailable(Int32?), notPublic(Endpoint?), ready(Endpoint)
    }

    typealias StartMapping = (UInt16, @escaping (Status) -> Void) throws -> () -> Void
    private let defaults: UserDefaults
    private let startMapping: StartMapping
    private var cancelMapping: (() -> Void)?
    private var mappingRequest: UUID?
    private static let settingsKey = "mac.remoteAccess.configuration"
    private(set) var configuration: Configuration?
    private(set) var status: Status = .off

    init(defaults: UserDefaults, startMapping: StartMapping? = nil) {
        self.defaults = defaults
        self.startMapping = startMapping ?? MacPortMapping.start
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            apply(saved)
        }
    }

    func apply(_ configuration: Configuration?) {
        mappingRequest = nil
        cancelMapping?()
        cancelMapping = nil
        self.configuration = configuration
        if let configuration {
            defaults.set(try? JSONEncoder().encode(configuration), forKey: Self.settingsKey)
        } else {
            defaults.removeObject(forKey: Self.settingsKey)
        }
        switch configuration {
        case nil: status = .off
        case .manual(_, let endpoint): status = .ready(endpoint)
        case .automatic(let service):
            status = .waiting
            let request = UUID()
            mappingRequest = request
            do {
                cancelMapping = try startMapping(service.port) { [weak self] status in
                    guard let self, self.mappingRequest == request else { return }
                    self.status = status
                }
            } catch {
                mappingRequest = nil
                status = .unavailable(Int32(clamping: (error as NSError).code))
            }
        }
    }

    func connectionLink(observe: Bool = false) -> URL? {
        guard case .ready(let endpoint) = status else { return nil }
        return configuration?.service.link(to: endpoint, observe: observe)
    }
}

/// DNS-SD delivers lease changes on the main queue. Releasing the reference
/// there also withdraws the request when the user turns remote access off.
@MainActor private final class MacPortMapping {
    private var reference: DNSServiceRef?
    private let update: (MacRemoteAccess.Status) -> Void

    private init(update: @escaping (MacRemoteAccess.Status) -> Void) { self.update = update }

    static func start(port: UInt16, update: @escaping (MacRemoteAccess.Status) -> Void) throws -> () -> Void {
        let lease = MacPortMapping(update: update)
        var reference: DNSServiceRef?
        let result = DNSServiceNATPortMappingCreate(&reference, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_TCP),
                                                    port.bigEndian, 0, 0, { _, _, _, code, address, _, _, externalPort, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let lease = Unmanaged<MacPortMapping>.fromOpaque(context).takeUnretainedValue()
                lease.update(MacRemoteAccess.mappingStatus(code: code, address: address, port: externalPort))
            }
        }, Unmanaged.passUnretained(lease).toOpaque())
        guard result == kDNSServiceErr_NoError, let reference else {
            throw NSError(domain: NetService.errorDomain, code: Int(result))
        }
        let scheduled = DNSServiceSetDispatchQueue(reference, .main)
        guard scheduled == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            throw NSError(domain: NetService.errorDomain, code: Int(scheduled))
        }
        lease.reference = reference
        return { lease.cancel() }
    }

    private func cancel() {
        if let reference { DNSServiceRefDeallocate(reference) }
        reference = nil
    }

    isolated deinit {
        if let reference { DNSServiceRefDeallocate(reference) }
    }
}

extension MacRemoteAccess {
    static func mappingStatus(code: Int32, address: UInt32, port: UInt16) -> Status {
        let doubleNAT = code == kDNSServiceErr_DoubleNAT
        guard code == kDNSServiceErr_NoError || doubleNAT else { return .unavailable(code) }
        guard address != 0, port != 0,
              let ip = IPv4Address(withUnsafeBytes(of: address) { Data($0) }),
              let endpoint = try? Endpoint(address: ip.debugDescription, defaultPort: UInt16(bigEndian: port))
        else { return doubleNAT ? .notPublic(nil) : .unavailable(nil) }
        guard !doubleNAT, isPublicIPv4(ip) else { return .notPublic(endpoint) }
        return .ready(endpoint)
    }

    private static func isPublicIPv4(_ address: IPv4Address) -> Bool {
        let octets = Array(address.rawValue)
        // IANA non-global address ranges, plus multicast destinations.
        switch (octets[0], octets[1], octets[2], octets[3]) {
        case (192, 0, 0, 9...10): return true
        case (0, _, _, _), (10, _, _, _), (100, 64...127, _, _), (127, _, _, _),
             (169, 254, _, _), (172, 16...31, _, _), (192, 168, _, _),
             (192, 0, 0, _), (192, 0, 2, _), (192, 88, 99, _),
             (198, 18...19, _, _), (198, 51, 100, _), (203, 0, 113, _), (224...255, _, _, _):
            return false
        default: return true
        }
    }
}
#endif
