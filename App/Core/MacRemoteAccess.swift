#if targetEnvironment(macCatalyst)
import Foundation
import Network
import Observation
import dnssd

enum MacAccessService: String, Codable, CaseIterable {
    case ssh, screenSharing

    var port: UInt16 { self == .ssh ? 22 : 5900 }

    func link(to endpoint: Endpoint) -> URL? {
        if self == .ssh {
            guard let desktop = try? Endpoint(address: endpoint.host) else { return nil }
            return ConnectionRoute.sharing(desktop, sshPort: endpoint.port)
        }
        return ConnectionRoute.sharing(endpoint, sshPort: nil)
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
        case off, waiting, unavailable(Int32?), ready(Endpoint)
    }

    typealias StartMapping = (UInt16, @escaping (Status) -> Void) throws -> () -> Void
    private let defaults: UserDefaults
    private let startMapping: StartMapping
    private var cancelMapping: (() -> Void)?
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
            do {
                cancelMapping = try startMapping(service.port) { [weak self] in self?.status = $0 }
            } catch {
                status = .unavailable(Int32(clamping: (error as NSError).code))
            }
        }
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
        guard code == kDNSServiceErr_NoError else { return .unavailable(code) }
        guard address != 0, port != 0,
              let ip = IPv4Address(withUnsafeBytes(of: address) { Data($0) }),
              let endpoint = try? Endpoint(address: ip.debugDescription, defaultPort: UInt16(bigEndian: port))
        else { return .unavailable(nil) }
        return .ready(endpoint)
    }
}
#endif
