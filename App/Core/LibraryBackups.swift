import Foundation

struct LibraryBackup: Identifiable, Equatable {
    let id: UUID
    let created: Date
    let computers: Int
    let folders: Int
}

struct LibraryBackups {
    let directory: URL
    static let limit = 10

    init(library: URL) {
        directory = library.deletingPathExtension().appendingPathExtension("backups")
    }

    func list() throws -> [LibraryBackup] {
        try locations().compactMap { item in
            guard let archive = try? read(item.id) else { return nil }
            return LibraryBackup(id: item.id, created: item.date, computers: archive.computers.count, folders: archive.folderCount)
        }
    }

    func read(_ id: UUID) throws -> LibraryArchive {
        let file = url(for: id)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        return try LibraryArchive.read(Data(contentsOf: file))
    }

    func capture(_ data: Data) throws {
        let previous = try locations()
        if let newest = previous.first, (try? Data(contentsOf: url(for: newest.id))) == data { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: UUID()), options: .atomic)
        for old in previous.dropFirst(Self.limit - 1) {
            try? FileManager.default.removeItem(at: url(for: old.id))
        }
    }

    func preserveUnreadablePrimary(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "unreadable-" + UUID().uuidString + ".data"), options: .atomic)
    }

    private func url(for id: UUID) -> URL { directory.appending(path: id.uuidString + ".json") }

    private func locations() throws -> [(id: UUID, date: Date)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try items.compactMap { item -> (id: UUID, date: Date)? in
            guard item.pathExtension == "json", let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                  item.lastPathComponent == url(for: id).lastPathComponent else { return nil }
            let values = try item.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true, let date = values.contentModificationDate else { return nil }
            return (id, date)
        }.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
    }
}
