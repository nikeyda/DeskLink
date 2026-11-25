import AppIntents
import Foundation
import Security

struct ComputerEntity: AppEntity, Codable, Equatable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "已存储的电脑"
    static let defaultQuery = ComputerQuery()
    let id: UUID
    let name: String
    let address: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(address)", image: .init(systemName: "desktopcomputer"))
    }
}

struct ComputerQuery: EntityStringQuery {
    @MainActor private func entries() -> [ComputerEntity] {
        #if WIDGET_EXTENSION
        WidgetCatalog.read()
        #else
        ConnectionLibrary().archive.widgetComputers
        #endif
    }

    func entities(for identifiers: [UUID]) async throws -> [ComputerEntity] {
        let indexed = Dictionary(uniqueKeysWithValues: await entries().map { ($0.id, $0) })
        return identifiers.compactMap { indexed[$0] }
    }

    func entities(matching string: String) async throws -> [ComputerEntity] {
        await entries().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.address.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ComputerEntity] { await entries() }
}

enum WidgetCatalog {
    static let kind = "DeskLinkConnections"

    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DeskLinkWidgetGroup") as? String,
              let prefix = group.split(separator: ".").first,
              prefix.count == 10, group == "\(prefix).local.nikey.desklink.widget-index" else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrAccessGroup as String: group,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrService as String: "local.nikey.desklink.widget-index", kSecAttrAccount as String: "computers"]
    }

    static func read() -> [ComputerEntity] {
        guard var query else { return [] }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([ComputerEntity].self, from: data)) ?? []
    }

    #if !WIDGET_EXTENSION
    static func publish(_ entries: [ComputerEntity]) -> Bool {
        guard var query, read() != entries, let data = try? JSONEncoder().encode(entries) else { return false }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
    #endif
}
