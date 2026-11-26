import Foundation
import Observation

/// A received file or folder still on this device.
public struct VNCStoredDownload: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// Space taken on disk, including a folder's contents.
    public let byteCount: Int64
    /// When the download started.
    public let date: Date?
    fileprivate let fileNumber: ino_t
}

/// The Screen Sharing downloads left on this device, whichever session made
/// them. Lists what is on disk now; downloads still in progress are left out
/// and never deleted.
@MainActor
@Observable
public final class VNCDownloadStore {
    public static let shared = VNCDownloadStore(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Screen Sharing Downloads", isDirectory: true))

    /// Newest first.
    public private(set) var downloads: [VNCStoredDownload] = []
    /// False until the first ``refresh()`` finishes.
    public private(set) var hasLoaded = false

    public var totalByteCount: Int64 {
        downloads.reduce(0) { $0 + $1.byteCount }
    }

    @ObservationIgnored let root: URL
    @ObservationIgnored private var published: PublishedDownloads?
    @ObservationIgnored private let controllers = NSHashTable<VNCFileTransferController>.weakObjects()
    @ObservationIgnored private var generation = 0
    /// A host has asked for the list, so changes are worth a reread.
    @ObservationIgnored private var isListed = false

    init(root: URL) {
        self.root = root
    }

    /// An app can expose completed downloads through its local Files provider.
    public func publishCompletedDownloads(in directory: URL) {
        published = PublishedDownloads(directory: directory)
    }

    // MARK: - Host actions

    /// Reads the folder again, so items the system removed drop out.
    public func refresh() async {
        isListed = true
        generation += 1
        let current = generation
        let folders = idleFolders()
        let published = published
        let found = await Task.detached(priority: .userInitiated) {
            Self.scan(folders, published: published)
        }.value
        guard current == generation else { return }
        if found != downloads { downloads = found }
        hasLoaded = true
    }

    /// Deletes one downloaded item from this device.
    public func delete(_ download: VNCStoredDownload) async {
        let url = download.url
        let folder = idleFolder(containing: url)
        let published = published
        await Task.detached {
            guard folder != nil || published?.contains(url) == true,
                  Self.fileNumber(at: url) == download.fileNumber else { return }
            try? FileManager.default.removeItem(at: url)
            if let folder { rmdir(folder.path) }
        }.value
        pruneControllers()
        await refresh()
    }

    /// Deletes every download that no transfer is still writing, along with
    /// empty folders earlier sessions left behind.
    public func deleteAll() async {
        let folders = idleFolders()
        let published = published
        await Task.detached {
            for folder in folders + (published?.items() ?? []) {
                try? FileManager.default.removeItem(at: folder)
            }
        }.value
        pruneControllers()
        await refresh()
    }

    /// The host moved an item elsewhere (for example Save to Files).
    public func downloadWasMoved(_ download: VNCStoredDownload) {
        if let folder = idleFolder(containing: download.url) {
            rmdir(folder.path)
        }
        downloads.removeAll { $0.url == download.url && $0.fileNumber == download.fileNumber }
        pruneControllers()
        contentsDidChange()
    }

    // MARK: - Transfer plumbing

    func register(_ controller: VNCFileTransferController) {
        controllers.add(controller)
    }

    /// A new folder for one download's items.
    func makeFolder() -> URL {
        let incoming = published == nil ? root : root.appending(path: "Incoming", directoryHint: .isDirectory)
        let folder = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func complete(_ urls: [URL], in folder: URL, owner: UUID) async -> (urls: [URL], error: String?) {
        guard let published else { return (urls, nil) }
        let privateFolder = root.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        return await Task.detached {
            // If Files cannot accept an item, the finished private copy stays available for Save.
            do { try FileManager.default.moveItem(at: folder, to: privateFolder) }
            catch { return (urls, error.localizedDescription) }
            var outputs: [URL] = []
            var failure: String?
            for url in urls {
                let source = privateFolder.appendingPathComponent(url.lastPathComponent)
                do { outputs.append(try published.publish(source, owner: owner)) }
                catch {
                    outputs.append(source)
                    if failure == nil { failure = error.localizedDescription }
                }
            }
            rmdir(privateFolder.path)
            return (outputs, failure)
        }.value
    }

    /// Removes one transfer's own files without removing their shared destination directory.
    func removeItems(_ urls: [URL], owner: UUID, keepingPublished: Bool = false) {
        for url in urls {
            let folder = idleFolder(containing: url)
            guard folder != nil || (!keepingPublished && published?.contains(url, owner: owner) == true) else { continue }
            try? FileManager.default.removeItem(at: url)
            if let folder { rmdir(folder.path) }
        }
        contentsDidChange()
    }

    func removeEmptyPrivateFolders(for urls: [URL]) {
        for url in urls {
            if let folder = idleFolder(containing: url) { rmdir(folder.path) }
        }
        contentsDidChange()
    }

    /// A session added or removed files; only reread if a host is listing them.
    /// A reread started during a scan supersedes that scan's result.
    func contentsDidChange() {
        guard isListed else { return }
        Task { await refresh() }
    }

    // MARK: - Helpers

    private func pruneControllers() {
        for controller in controllers.allObjects {
            controller.pruneMissingDownloads()
        }
    }

    private func foldersInUse() -> Set<String> {
        controllers.allObjects.reduce(into: Set<String>()) {
            $0.formUnion($1.activeDownloadFolders)
        }
    }

    /// Download folders no transfer is writing. Taken in one main-actor turn,
    /// so a download that starts later is never in the list.
    private func idleFolders() -> [URL] {
        let inUse = foldersInUse()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { UUID(uuidString: $0) != nil && !inUse.contains($0) }
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// The download folder holding `url`, if it is one of ours and idle.
    private func idleFolder(containing url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        let name = folder.lastPathComponent
        guard UUID(uuidString: name) != nil,
              folder.deletingLastPathComponent().resolvingSymlinksInPath().path
                  == root.resolvingSymlinksInPath().path,
              !foldersInUse().contains(name) else { return nil }
        return folder
    }

    private nonisolated static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
    ]

    private nonisolated static func scan(_ folders: [URL], published: PublishedDownloads?) -> [VNCStoredDownload] {
        let manager = FileManager.default
        var found: [VNCStoredDownload] = []
        var entries: [(URL, Date?)] = []
        for folder in folders {
            let date = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate
            let children = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(sizeKeys))) ?? []
            entries.append(contentsOf: children.map { ($0, date) })
        }
        for child in published?.items() ?? [] {
            let date = try? child.resourceValues(forKeys: [.creationDateKey]).creationDate
            entries.append((child, date))
        }
        for (child, date) in entries {
            guard let fileNumber = fileNumber(at: child) else { continue }
            let values = try? child.resourceValues(forKeys: sizeKeys)
            let isDirectory = values?.isDirectory == true
            var bytes = size(of: child, values: values)
            if isDirectory,
               let enumerator = manager.enumerator(
                   at: child, includingPropertiesForKeys: Array(sizeKeys)) {
                for case let item as URL in enumerator {
                    bytes += size(of: item, values: try? item.resourceValues(forKeys: sizeKeys))
                }
            }
            found.append(VNCStoredDownload(
                url: child,
                name: child.lastPathComponent,
                isDirectory: isDirectory,
                byteCount: bytes,
                date: date,
                fileNumber: fileNumber))
        }
        return found.sorted {
            let (a, b) = ($0.date ?? .distantPast, $1.date ?? .distantPast)
            return a != b ? a > b : $0.url.path < $1.url.path
        }
    }

    private nonisolated static func fileNumber(at url: URL) -> ino_t? {
        var information = stat()
        return lstat(url.path, &information) == 0 ? information.st_ino : nil
    }

    private nonisolated static func size(of url: URL, values: URLResourceValues?) -> Int64 {
        guard values?.isRegularFile == true else { return 0 }
        let resourceBytes = (try? FileResourceFork.size(of: url)) ?? 0
        return Int64(values?.fileSize ?? 0) + Int64(clamping: resourceBytes)
    }
}
