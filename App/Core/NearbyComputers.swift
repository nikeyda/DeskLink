import Foundation
import Observation

struct NearbyComputer: Identifiable {
    let service: NetService
    var id: String { service.domain + "/" + service.type + "/" + service.name }
    var name: String { service.name }
}

@MainActor @Observable
final class NearbyComputers: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private(set) var entries: [NearbyComputer] = []
    var errorMessage: String?
    private var browser: NetServiceBrowser?
    private var resolving: NetService?
    private var selection: ((Computer) -> Void)?

    func start() {
        guard browser == nil else { return }
        entries = []
        errorMessage = nil
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        cancelSelection()
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

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let found = NearbyComputer(service: service)
        guard !entries.contains(where: { $0.id == found.id }) else { return }
        entries.append(found)
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let removed = NearbyComputer(service: service)
        entries.removeAll { $0.id == removed.id }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        errorMessage = Self.description(errorDict)
        stop()
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
