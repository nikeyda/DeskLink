import UniformTypeIdentifiers
import XCTest
@testable import DeskLink

@MainActor
final class ArchiveExchangeTests: XCTestCase {
    private let originalID = UUID(uuidString: "EA5E2C8A-84E5-46F4-BF4C-331B2900677A")!
    private let copyID = UUID(uuidString: "0CF4D000-18F5-4C05-B59C-F454202EA9BE")!
    private let folder = "文稿往返"
    private let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func makeBook(_ name: String) -> ConnectionLibrary {
        ConnectionLibrary(file: work.appending(path: name + ".json"))
    }

    private func initialArchive() throws -> Data {
        let library = makeBook("initial")
        var studio = Computer(name: "摄影室", endpoint: try Endpoint(address: "studio.fixture.invalid:5937"))
        studio.id = originalID
        studio.folder = folder
        studio.favorite = true
        var display = studio.display(for: .mac)
        display.quality = .adaptive
        display.matchWindow = true
        display.fixedDesktop = DesktopDimensions(width: 1600, height: 1000)
        studio.setDisplay(display, for: .mac)
        XCTAssertTrue(library.save(studio))
        return try library.archive.encoded()
    }

    private func returnedArchive(from data: Data) throws -> Data {
        let tablet = makeBook("tablet")
        XCTAssertEqual(try tablet.importArchive(data), ArchiveImportResult(connections: 1, folders: 1))
        let studio = try XCTUnwrap(tablet.archive.computers.first)
        XCTAssertEqual(studio.id, originalID)
        XCTAssertTrue(studio.favorite)
        XCTAssertEqual(studio.folder, folder)
        XCTAssertEqual(studio.endpoint.port, 5937)
        XCTAssertEqual(studio.display(for: .mac).fixedDesktop, DesktopDimensions(width: 1600, height: 1000))
        var second = tablet.archive.duplicate(of: studio)
        second.id = copyID
        second.name = "iPad 摄影室"
        var display = second.display(for: .iPad)
        display.quality = .adaptive
        display.matchWindow = true
        display.fixedDesktop = DesktopDimensions(width: 1280, height: 800)
        second.setDisplay(display, for: .iPad)
        XCTAssertTrue(tablet.save(second))
        return try tablet.archive.encoded()
    }

    /// The integration run supplies the previous device's exported file bytes.
    private func openDocument(or generate: () throws -> Data) throws -> Data {
        let data: Data
        if let base64 = ProcessInfo.processInfo.environment["DESKLINK_ARCHIVE_BASE64"] {
            data = try XCTUnwrap(Data(base64Encoded: base64))
        } else { data = try generate() }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appending(path: "Transfer.desklink")
        try ArchiveDocument(data: data).data.write(to: file)
        return try ArchiveDocument(contentsOf: file).data
    }

    private func attach(_ data: Data, name: String) {
        let file = XCTAttachment(data: data, uniformTypeIdentifier: ArchiveDocument.type.identifier)
        file.name = name
        file.lifetime = .keepAlways
        add(file)
    }

    func testExportMacArchive() throws {
        defer { try? FileManager.default.removeItem(at: work) }
        XCTAssertTrue(ArchiveDocument.type.conforms(to: .json))
        XCTAssertEqual(ArchiveDocument.type.preferredFilenameExtension, "desklink")
        attach(try initialArchive(), name: "Mac.desklink")
    }

    func testImportMacDocumentAndExportIPadCopy() throws {
        defer { try? FileManager.default.removeItem(at: work) }
        let incoming = try openDocument(or: initialArchive)
        attach(try returnedArchive(from: incoming), name: "iPad.desklink")
    }

    func testReturnedDocumentPreservesMacEditsAndBothDisplayProfiles() throws {
        defer { try? FileManager.default.removeItem(at: work) }
        let book = makeBook("final")
        let initial = try initialArchive()
        _ = try book.importArchive(initial)
        var original = try XCTUnwrap(book.archive.computers.first)
        original.name = "Mac 本地名称"
        XCTAssertTrue(book.save(original))
        let incoming = try openDocument { try returnedArchive(from: initial) }
        XCTAssertEqual(try book.importArchive(incoming), ArchiveImportResult(connections: 1, duplicates: 1))
        XCTAssertEqual(try book.importArchive(incoming), ArchiveImportResult(duplicates: 2))
        let saved = makeBook("final").archive
        XCTAssertEqual(saved.computers.map(\.id), [originalID, copyID])
        XCTAssertEqual(saved.computers.first?.name, original.name)
        let copy = try XCTUnwrap(saved.computers.last)
        XCTAssertEqual(copy.name, "iPad 摄影室")
        XCTAssertEqual(copy.display(for: .mac).fixedDesktop, DesktopDimensions(width: 1600, height: 1000))
        XCTAssertEqual(copy.display(for: .iPad).fixedDesktop, DesktopDimensions(width: 1280, height: 800))
    }
}
