import Foundation
import Observation

struct TailnetAccount: Codable, Equatable, Sendable {
    let tailnet: String
    let clientID: String

    init(tailnet: String, clientID: String) throws {
        let name = tailnet.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_@")
        guard !name.isEmpty, ![".", ".."].contains(name), name.utf8.count <= 253,
              name.unicodeScalars.allSatisfy(valid.contains),
              !id.isEmpty, id.utf8.count <= 256, id.unicodeScalars.allSatisfy(valid.contains) else { throw URLError(.badURL) }
        self.tailnet = name
        self.clientID = id
    }

    var devicesURL: URL {
        URL(string: "https://api.tailscale.com/api/v2/tailnet")!.appending(path: tailnet).appending(path: "devices")
    }

    func tokenRequest(secret: String) throws -> URLRequest {
        guard !secret.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let values = [("grant_type", "client_credentials"), ("client_id", clientID), ("client_secret", secret), ("scope", "devices:core:read")]
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var request = URLRequest(url: URL(string: "https://api.tailscale.com/api/v2/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = try values.map { key, value in
            guard let text = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw URLError(.badURL) }
            return key + "=" + text
        }
        request.httpBody = Data(encoded.joined(separator: "&").utf8)
        return request
    }

    func credentialKey() throws -> Computer {
        var result = Computer(endpoint: try Endpoint(address: "api.tailscale.com"))
        result.username = tailnet + "/" + clientID
        return result
    }
}

struct TailnetDevice: Decodable, Identifiable, Sendable {
    let id: String
    let hostname: String
    let name: String
    let addresses: [String]
    let os: String
    let authorized: Bool?

    var computer: Computer? {
        guard authorized != false else { return nil }
        guard let address = addresses.compactMap({ try? Endpoint(address: $0) }).first ??
                (try? Endpoint(address: name)) else { return nil }
        var item = Computer(name: hostname.isEmpty ? name : hostname, endpoint: address)
        item.saved = false
        return item
    }

    func directoryID(in account: TailnetAccount) -> UUID? {
        guard !id.isEmpty else { return nil }
        // The same node keeps its identity across renames and address changes.
        let identity = "local.nikey.desklink/tailnet/" + account.tailnet.lowercased() + "/" + id
        return UUID.derived(from: identity)
    }

    func widgetComputer(in account: TailnetAccount) -> ComputerEntity? {
        guard let id = directoryID(in: account), let computer else { return nil }
        return ComputerEntity(id: id, name: computer.displayName, address: computer.endpoint.address)
    }
}

private final class FixedServiceDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @Observable
final class TailnetDirectory {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Token: Decodable { let access_token: String; let token_type: String }
    private struct Listing: Decodable { let devices: [TailnetDevice] }
    private struct RememberedDirectory: Codable {
        let account: TailnetAccount
        let computers: [ComputerEntity]
    }
    private static let hiddenDevicesKey = "tailnet.hiddenDevices"
    private static let session = URLSession(configuration: .ephemeral, delegate: FixedServiceDelegate(), delegateQueue: nil)

    private let defaults: UserDefaults
    private let transport: Transport
    private var secret: String?
    private var attempt = UUID()
    private var hiddenIDs: Set<UUID>
    private var widgetCandidates = [ComputerEntity]()
    private(set) var account: TailnetAccount?
    private(set) var devices = [TailnetDevice]()
    private(set) var loading = false
    var error: String?

    var visibleDevices: [TailnetDevice] { devices.filter { !isHidden($0) } }
    var hiddenDevices: [TailnetDevice] { devices.filter { isHidden($0) } }
    var widgetComputers: [ComputerEntity] { widgetCandidates.filter { !hiddenIDs.contains($0.id) } }

    init(defaults: UserDefaults = .standard, transport: Transport? = nil) {
        self.defaults = defaults
        hiddenIDs = Set((defaults.stringArray(forKey: Self.hiddenDevicesKey) ?? []).compactMap(UUID.init(uuidString:)))
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
        if let data = defaults.data(forKey: "tailnet.account") {
            let decoder = JSONDecoder()
            let cache = try? decoder.decode(RememberedDirectory.self, from: data)
            if let stored = cache?.account ?? (try? decoder.decode(TailnetAccount.self, from: data)),
               let validated = try? TailnetAccount(tailnet: stored.tailnet, clientID: stored.clientID) {
                account = validated
                widgetCandidates = cache?.computers ?? []
            }
        }
    }

    func link(_ new: TailnetAccount, secret: String, remember: Bool) async throws {
        let generation = UUID()
        attempt = generation
        loading = true
        defer { if attempt == generation { loading = false } }
        let listing = try await requestDevices(new, secret: secret)
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
        if remember { try PasswordStore.write(secret, for: new.credentialKey(), kind: .tailnet) }
        if let previous = account, defaults.data(forKey: "tailnet.account") != nil, previous != new || !remember {
            try PasswordStore.write(nil, for: previous.credentialKey(), kind: .tailnet)
        }
        try storeWidgetComputers(listing, account: new, remember: remember)
        account = new
        self.secret = secret
        devices = listing
        error = nil
    }

    func refresh() async {
        guard let account, !loading else { return }
        let generation = UUID()
        attempt = generation
        loading = true
        defer { if attempt == generation { loading = false } }
        do {
            guard let proof = try secret ?? PasswordStore.read(account.credentialKey(), kind: .tailnet) else {
                throw URLError(.userAuthenticationRequired)
            }
            let listing = try await requestDevices(account, secret: proof)
            if attempt == generation {
                try storeWidgetComputers(listing, account: account, remember: defaults.data(forKey: "tailnet.account") != nil)
                devices = listing
                error = nil
            }
        } catch { if attempt == generation { self.error = error.localizedDescription } }
    }

    func unlink() throws {
        if let account, defaults.data(forKey: "tailnet.account") != nil {
            try PasswordStore.write(nil, for: account.credentialKey(), kind: .tailnet)
        }
        attempt = UUID()
        account = nil
        secret = nil
        devices = []
        widgetCandidates = []
        loading = false
        error = nil
        defaults.removeObject(forKey: "tailnet.account")
    }

    func setHidden(_ hidden: Bool, device: TailnetDevice) {
        guard let account, let id = device.directoryID(in: account) else { return }
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
        defaults.set(hiddenIDs.map(\.uuidString).sorted(), forKey: Self.hiddenDevicesKey)
    }

    private func isHidden(_ device: TailnetDevice) -> Bool {
        guard let account, let id = device.directoryID(in: account) else { return false }
        return hiddenIDs.contains(id)
    }

    func computerForWidget(_ id: UUID) -> Computer? {
        guard let item = widgetComputers.first(where: { $0.id == id }),
              let endpoint = try? Endpoint(address: item.address) else { return nil }
        var computer = Computer(name: item.name, endpoint: endpoint)
        computer.saved = false
        return computer
    }

    private func storeWidgetComputers(_ listing: [TailnetDevice], account: TailnetAccount, remember: Bool) throws {
        guard remember else {
            defaults.removeObject(forKey: "tailnet.account")
            widgetCandidates = []
            return
        }
        let computers = listing.compactMap { $0.widgetComputer(in: account) }
        let cache = RememberedDirectory(account: account, computers: computers)
        defaults.set(try JSONEncoder().encode(cache), forKey: "tailnet.account")
        widgetCandidates = computers
    }

    private func requestDevices(_ account: TailnetAccount, secret: String) async throws -> [TailnetDevice] {
        let authentication = try await data(for: account.tokenRequest(secret: secret))
        let token = try JSONDecoder().decode(Token.self, from: authentication)
        guard token.token_type.lowercased() == "bearer", !token.access_token.isEmpty else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: account.devicesURL)
        request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
        let response = try await data(for: request)
        return try JSONDecoder().decode(Listing.self, from: response).devices
            .filter { $0.computer != nil }.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }

    private func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport(request)
        if [401, 403].contains(response.statusCode) { throw URLError(.userAuthenticationRequired) }
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
