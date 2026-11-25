import Foundation
import Observation

enum ReplicaFolder {
    static func bookmark(for folder: URL) throws -> Data {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        #if targetEnvironment(macCatalyst)
        return try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    static func exchange(bookmark: Data, writer: UUID, pending: LibraryReplica) throws -> (LibraryReplica, Data) {
        var stale = false
        #if targetEnvironment(macCatalyst)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = .withoutImplicitStartAccessing
        #endif
        let folder = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try (exchange(in: folder, writer: writer, pending: pending), stale ? self.bookmark(for: folder) : bookmark)
    }

    static func exchange(in folder: URL, writer: UUID, pending: LibraryReplica) throws -> LibraryReplica {
        let directory = folder.appending(path: "DeskLink", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey])
        let mine = directory.appending(path: writer.uuidString + ".desklink")
        var previous: LibraryReplica?
        var result = pending
        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".desklink.icloud") {
                let basename = String(name.dropFirst().dropLast(".icloud".count))
                if UUID(uuidString: String(basename.dropLast(".desklink".count))) != nil {
                    try fm.startDownloadingUbiquitousItem(at: directory.appending(path: basename))
                    if basename == mine.lastPathComponent { throw URLError(.resourceUnavailable) }
                }
                continue
            }
            guard url.pathExtension == "desklink", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            let resource = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isSymbolicLinkKey])
            guard resource.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if resource.ubiquitousItemDownloadingStatus == .notDownloaded {
                try fm.startDownloadingUbiquitousItem(at: url)
                if name == mine.lastPathComponent { throw URLError(.resourceUnavailable) }
                continue
            }
            var read: Result<LibraryReplica, Error>?
            var coordination: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordination) { file in
                read = Result { try LibraryReplica.decode(Data(contentsOf: file)) }
            }
            if let coordination { throw coordination }
            guard let read else { throw CocoaError(.fileReadUnknown) }
            let received = try read.get()
            result.merge(received)
            if name == mine.lastPathComponent { previous = received }
        }
        if previous != result {
            let data = try JSONEncoder().encode(result)
            var write: Result<Void, Error>?
            var coordination: NSError?
            NSFileCoordinator().coordinate(writingItemAt: mine, options: .forReplacing, error: &coordination) { file in
                write = Result { try data.write(to: file, options: .atomic) }
            }
            if let coordination { throw coordination }
            guard let write else { throw CocoaError(.fileWriteUnknown) }
            try write.get()
        }
        return result
    }
}

@MainActor @Observable
final class LibrarySync {
    private struct Pair: Codable {
        var bookmark: Data
        let writer: UUID
        let name: String
        var replica = LibraryReplica()
        var baseline = LibraryArchive()
        var baselinePreferences: [String: PreferenceValue]?
        var lastSync: Date?
    }

    private let settings: URL
    private let defaults: UserDefaults
    private var pair: Pair?
    private var anotherPass = false
    private(set) var running = false
    var error: String?
    var folderName: String? { pair?.name }
    var lastSync: Date? { pair?.lastSync }

    var preferencesChanged: Bool {
        guard let pair else { return false }
        return SyncedPreference.snapshot(defaults) != (pair.baselinePreferences ?? [:])
    }

    init(settings: URL = URL.applicationSupportDirectory.appending(path: "DeskLink/sync.json"), defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        do {
            pair = try JSONDecoder().decode(Pair.self, from: Data(contentsOf: settings))
        } catch let problem as CocoaError where problem.code == .fileReadNoSuchFile {
        } catch { self.error = error.localizedDescription }
    }

    func select(_ url: URL) throws {
        let new = try Pair(bookmark: ReplicaFolder.bookmark(for: url), writer: UUID(), name: url.lastPathComponent)
        try save(new)
        pair = new
        error = nil
    }

    func stop() throws {
        if FileManager.default.fileExists(atPath: settings.path) { try FileManager.default.removeItem(at: settings) }
        pair = nil
        anotherPass = false
        error = nil
    }

    func refresh(_ library: ConnectionLibrary) async {
        guard pair != nil, library.canSync else { return }
        if running { anotherPass = true; return }
        running = true
        defer { running = false }
        repeat {
            anotherPass = false
            guard var checkpoint = pair else { return }
            let original = library.archive
            let originalPreferences = SyncedPreference.snapshot(defaults)
            do {
                var pending = checkpoint.replica
                try pending.record(from: checkpoint.baseline, to: original, writer: checkpoint.writer)
                try pending.recordPreferences(from: checkpoint.baselinePreferences ?? [:], to: originalPreferences, writer: checkpoint.writer)
                let bookmark = checkpoint.bookmark, writer = checkpoint.writer
                let (received, refreshed) = try await Task.detached(priority: .utility) {
                    try ReplicaFolder.exchange(bookmark: bookmark, writer: writer, pending: pending)
                }.value
                guard pair?.writer == writer else { continue }
                var merged = received
                if original != library.archive {
                    try merged.record(from: original, to: library.archive, writer: writer)
                    anotherPass = true
                }
                let next = merged.archive
                let currentPreferences = SyncedPreference.snapshot(defaults)
                if currentPreferences != originalPreferences {
                    try merged.recordPreferences(from: originalPreferences, to: currentPreferences, writer: writer)
                    anotherPass = true
                }
                guard library.applySync(next) else { throw CocoaError(.fileWriteUnknown) }
                SyncedPreference.apply(merged.preferenceValues, to: defaults)
                checkpoint.baselinePreferences = SyncedPreference.snapshot(defaults)
                checkpoint.baseline = next
                checkpoint.replica = merged
                checkpoint.bookmark = refreshed
                checkpoint.lastSync = .now
                try save(checkpoint)
                pair = checkpoint
                error = nil
            } catch {
                if pair?.writer == checkpoint.writer { self.error = error.localizedDescription }
            }
        } while anotherPass
    }

    private func save(_ state: Pair) throws {
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: settings, options: .atomic)
    }
}
