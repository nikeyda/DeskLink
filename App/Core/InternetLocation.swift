import Foundation

enum InternetLocation {
    static func link(from data: Data) throws -> DesktopLink {
        guard data.count <= 1024 * 1024,
              let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let value = dictionary["URL"] as? String, value.lowercased().hasPrefix("vnc://") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try DesktopLink(text: value)
    }

    static func read(_ url: URL) throws -> DesktopLink {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limits = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard limits.isRegularFile == true, let size = limits.fileSize, size <= 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try link(from: Data(contentsOf: url))
    }
}
