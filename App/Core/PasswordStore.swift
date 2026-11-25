import Foundation
import Security

enum PasswordStore {
    enum Kind: String { case desktop = "vnc", sshPassword = "ssh-password", sshKey = "ssh-key", tailnet = "tailscale-oauth" }

    static func account(for entry: Computer, kind: Kind) -> String {
        if kind != .desktop, let ssh = entry.ssh {
            return "\(ssh.server ?? entry.endpoint.host):\(ssh.port)\n\(ssh.username)"
        }
        let desktop = "\(entry.endpoint.address)\n\(entry.username)"
        if kind == .desktop, let ssh = entry.ssh, let server = ssh.server {
            return desktop + "\nssh:\(server):\(ssh.port)\n\(ssh.username)"
        }
        return desktop
    }

    private static func query(_ entry: Computer, kind: Kind, synchronized: Bool) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.nikey.desklink." + kind.rawValue,
            kSecAttrAccount as String: account(for: entry, kind: kind),
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: synchronized
        ]
    }

    static func read(_ entry: Computer, kind: Kind = .desktop, synchronize: Bool = false) throws -> String? {
        if synchronize, kind != .tailnet,
           let shared = try value(matching: query(entry, kind: kind, synchronized: true)) { return shared }
        return try value(matching: query(entry, kind: kind, synchronized: false))
    }

    private static func value(matching query: [String: Any]) throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    private static func namedQuery(_ name: String? = nil, synchronized: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.nikey.desklink.named-ssh-key",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: synchronized
        ]
        if let name { query[kSecAttrAccount as String] = name }
        return query
    }

    static func keyNames(synchronize: Bool) throws -> [String] {
        var query = namedQuery(synchronized: false)
        if synchronize { query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let entries = result as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        let names = Set(entries.compactMap { $0[kSecAttrAccount as String] as? String })
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func namedKey(_ name: String, synchronize: Bool) throws -> String? {
        if synchronize, let key = try value(matching: namedQuery(name, synchronized: true)) { return key }
        return try value(matching: namedQuery(name, synchronized: false))
    }

    static func addNamedKey(_ key: String, name: String, synchronize: Bool) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              name.utf8.count <= 255, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NamedKeyError.invalidName
        }
        _ = try SSHKeyFile.identity(key)
        if try keyNames(synchronize: synchronize).contains(name) { throw NamedKeyError.duplicateName }
        var item = namedQuery(name, synchronized: synchronize)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = synchronize ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { throw NamedKeyError.duplicateName }
        try check(added)
    }

    static func removeNamedKey(_ name: String, synchronize: Bool) throws {
        if synchronize { try delete(namedQuery(name, synchronized: true)) }
        try delete(namedQuery(name, synchronized: false))
    }

    enum NamedKeyError: LocalizedError {
        case invalidName, duplicateName, missingKey
        var errorDescription: String? {
            switch self {
            case .invalidName: "请输入有效的密钥名称。"
            case .duplicateName: "已有同名的 SSH 密钥。请使用其他名称。"
            case .missingKey: "找不到指定的 SSH 密钥。请选择其他密钥，或在设置中导入。"
            }
        }
    }

    static func write(_ password: String?, for entry: Computer, kind: Kind = .desktop,
                      synchronize: Bool = false) throws {
        let shared = synchronize && kind != .tailnet
        let target = query(entry, kind: kind, synchronized: shared)
        if let password, !password.isEmpty {
            let updates = [kSecValueData as String: Data(password.utf8)] as CFDictionary
            let status = SecItemUpdate(target as CFDictionary, updates)
            if status == errSecItemNotFound {
                var item = target
                item[kSecValueData as String] = Data(password.utf8)
                item[kSecAttrAccessible as String] = shared ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                if added == errSecDuplicateItem { try check(SecItemUpdate(target as CFDictionary, updates)) }
                else { try check(added) }
            } else { try check(status) }
        } else { try delete(target) }
        // A successful synchronized save replaces this account's older device-only copy.
        // Reading an old entry or turning on the preference alone never uploads its contents.
        if shared { try delete(query(entry, kind: kind, synchronized: false)) }
    }

    private static func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
