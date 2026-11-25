import Darwin
import Foundation

enum FileResourceFork {
    static func url(for file: URL) -> URL {
        URL(filePath: file.path + "/..namedfork/rsrc")
    }

    static func size(of file: URL) throws -> UInt64 {
        let count = getxattr(file.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        if count >= 0 { return UInt64(count) }
        let error = errno
        if error == ENOATTR || error == ENOTSUP { return 0 }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
    }

    static func create(for file: URL) throws -> FileHandle {
        let fd = Darwin.open(url(for: file).path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
