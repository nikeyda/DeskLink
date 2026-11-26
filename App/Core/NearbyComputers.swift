import Foundation
import Network
import Observation
import dnssd

struct NearbyComputer: Identifiable {
    let service: NetService
    var id: String { service.domain + "/" + service.type + "/" + service.name }
    var name: String { service.name }
}

@MainActor @Observable
final class NearbyComputers: NSObject, @preconcurrency NetServiceDelegate {
    private(set) var entries: [NearbyComputer] = []
    var errorMessage: String?
    private(set) var searchError: NWError?
    var needsLocalNetworkAccess: Bool { searchError == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)) }
    private var browser: NWBrowser?
    private var resolving: NetService?
    private var selection: ((Computer) -> Void)?

    func start() {
        guard browser == nil else { return }
        entries = []
        errorMessage = nil
        searchError = nil
        let browser = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                self.updateSearchState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, browser === self.browser else { return }
                var found: [String: NearbyComputer] = [:]
                for result in results {
                    guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                    let service = NetService(domain: domain, type: type, name: name)
                    let entry = NearbyComputer(service: service)
                    found[entry.id] = entry
                }
                self.entries = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        entries = []
        cancelSelection()
    }

    func retry() {
        stop()
        start()
    }

    func select(_ entry: NearbyComputer, completion: @escaping (Computer) -> Void) {
        cancelSelection()
        resolving = entry.service
        selection = completion
        entry.service.delegate = self
        entry.service.resolve(withTimeout: 8)
    }

    private func cancelSelection() {
        resolving?.delegate = nil
        resolving?.stop()
        resolving = nil
        selection = nil
    }

    func updateSearchState(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            searchError = error
            entries = []
            cancelSelection()
        case .ready:
            searchError = nil
        default: break
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender === resolving else { return }
        let action = selection
        defer { cancelSelection() }
        guard let host = sender.hostName, let port = UInt16(exactly: sender.port), port > 0,
              let endpoint = try? Endpoint(address: host, defaultPort: port) else {
            errorMessage = URLError(.cannotFindHost).localizedDescription
            return
        }
        var entry = Computer(name: sender.name, endpoint: endpoint)
        entry.saved = false
        action?(entry)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard sender === resolving else { return }
        errorMessage = Self.description(errorDict)
        cancelSelection()
    }

    private static func description(_ error: [String: NSNumber]) -> String {
        NSError(domain: "NSNetServicesErrorDomain", code: error[NetService.errorCode]?.intValue ?? -1).localizedDescription
    }
}
