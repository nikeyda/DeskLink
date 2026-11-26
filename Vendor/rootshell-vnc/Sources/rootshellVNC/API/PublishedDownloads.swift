import Darwin
import Foundation

/// Only completed items marked by the receiver belong to its download history.
struct PublishedDownloads: Sendable {
    let directory: URL
    private static let marker = "org.rootshell.vnc.download"

    func contains(_ item: URL, owner: UUID? = nil) -> Bool {
        guard item.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              isDirectory(directory) else { return false }
        guard let owner else {
            return getxattr(item.path, Self.marker, nil, 0, 0, XATTR_NOFOLLOW) == MemoryLayout<uuid_t>.size
        }
        var identifier = owner.uuid
        let read = withUnsafeMutableBytes(of: &identifier) {
            getxattr(item.path, Self.marker, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        return read == MemoryLayout.size(ofValue: identifier) && owner == UUID(uuid: identifier)
    }

    func items() -> [URL] {
        guard isDirectory(directory) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { contains($0) }
    }

    func publish(_ item: URL, owner: UUID) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard isDirectory(directory) else { throw CocoaError(.fileWriteInvalidFileName) }
        try checkLinks(in: item)
        var identifier = owner.uuid
        let status = withUnsafeBytes(of: &identifier) {
            setxattr(item.path, Self.marker, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // The staging and public directories are on the same app-container volume.
        // Files may add the same name after it was selected; the rename never replaces it.
        while true {
            let target = VNCFileTransferController.uniqueURL(in: directory, name: item.lastPathComponent)
            if renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            let error = errno
            guard error == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A link in a shared document must keep pointing inside that document after the move.
    private func checkLinks(in item: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        let safeRoot = item.resolvingSymlinksInPath().standardizedFileURL.path
        func check(_ url: URL) throws {
            guard try url.resourceValues(forKeys: keys).isSymbolicLink == true else { return }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let destination = url.deletingLastPathComponent().appendingPathComponent(target)
            let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
            guard url != item, !target.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: destination.path),
                  resolved == safeRoot || resolved.hasPrefix(safeRoot + "/") else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        try check(item)
        if isDirectory(item) {
            var failure: Error?
            guard let children = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys),
                options: [], errorHandler: { _, error in failure = error; return false }) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let child as URL in children { try check(child) }
            if let failure { throw failure }
        }
    }
}
