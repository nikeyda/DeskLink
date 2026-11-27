import Foundation

struct ScreensDirectoryFolder: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let contentType: Int
    let items: [UUID]
    let rawItems: [String]?

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            Set(items).count == items.count && Set(rawItems ?? []).count == (rawItems?.count ?? 0)
    }
}

struct ScreensDirectoryFolders: Codable, Equatable, Sendable {
    enum Directory: String, CaseIterable, Sendable { case tailscale, screensConnect }

    var tailscale: [ScreensDirectoryFolder] = []
    var screensConnect: [ScreensDirectoryFolder] = []

    var count: Int { tailscale.count + screensConnect.count }
    var isValid: Bool {
        Directory.allCases.allSatisfy { directory in
            let folders = self[directory]
            return Set(folders.map(\.id)).count == folders.count && folders.allSatisfy(\.isValid)
        }
    }

    subscript(directory: Directory) -> [ScreensDirectoryFolder] {
        get { directory == .tailscale ? tailscale : screensConnect }
        set {
            if directory == .tailscale { tailscale = newValue }
            else { screensConnect = newValue }
        }
    }

    mutating func addMissing(from incoming: Self) {
        for directory in Directory.allCases {
            let known = Set(self[directory].map(\.id))
            self[directory].append(contentsOf: incoming[directory].filter { !known.contains($0.id) })
        }
    }
}
