import XCTest
@testable import DeskLink

final class LinkFolderTests: XCTestCase {
    @MainActor func testLinkFoldersSurviveSavingRestartImportAndRenaming() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "library.json")
        let book = ConnectionLibrary(file: file)
        var nearby = Computer(name: "Nearby", endpoint: try Endpoint(address: "nearby.fixture.invalid"))
        nearby.saved = false
        book.recordSuccess(nearby)
        var link = Computer(name: "Link", endpoint: try Endpoint(address: "link.fixture.invalid"))
        link.saved = false
        link.openedFromLink = true
        book.recordSuccess(link)
        XCTAssertEqual(book.archive.computers.filter(\.isLink).map(\.id), [link.id])
        let vpnNode = ComputerEntity(id: UUID(), name: "Office", address: "100.64.0.22")
        XCTAssertEqual(book.archive.widgetComputers(including: [vpnNode, vpnNode]).map(\.id), [link.id, vpnNode.id])
        XCTAssertTrue(book.addFolder("工作室"))
        XCTAssertTrue(book.addFolder("工作室", in: .links))
        link.linkFolder = "工作室"
        XCTAssertTrue(book.save(link))
        link.saved = true
        link.folder = "工作室"
        XCTAssertTrue(book.save(link))
        let copy = book.archive.duplicate(of: link)
        XCTAssertFalse(copy.isLink)
        XCTAssertNil(copy.linkFolder)
        XCTAssertTrue(book.renameFolder("工作室", to: "临时桌面", in: .links))
        let reopened = ConnectionLibrary(file: file)
        let item = try XCTUnwrap(reopened.archive.computers.first(where: { $0.id == link.id }))
        XCTAssertEqual(item.folder, "工作室")
        XCTAssertEqual(item.linkFolder, "临时桌面")
        let second = ConnectionLibrary(file: root.appending(path: "other.json"))
        let bytes = try reopened.archive.encoded()
        XCTAssertEqual(try second.importArchive(bytes), ArchiveImportResult(connections: 2, folders: 2))
        XCTAssertEqual(try second.importArchive(bytes), ArchiveImportResult(duplicates: 2))
        XCTAssertTrue(second.removeFolder("临时桌面", in: .links))
        XCTAssertTrue(second.archive.folders(in: .links).isEmpty)
        XCTAssertEqual(second.archive.folders, ["工作室"])
        let remaining = try XCTUnwrap(second.archive.computers.first(where: { $0.id == link.id }))
        XCTAssertTrue(remaining.isLink)
        XCTAssertNil(remaining.linkFolder)
        XCTAssertEqual(remaining.folder, "工作室")
    }

    func testOldTemporaryEntriesAndOfflineFolderMerges() throws {
        let id = UUID(), writer = UUID(), other = UUID()
        var link = Computer(name: "Old link", endpoint: try Endpoint(address: "archive.fixture.invalid"))
        link.id = id
        link.saved = false
        link.openedFromLink = nil
        link.lastConnected = Date(timeIntervalSinceReferenceDate: 10)
        let baseline = try LibraryArchive.read(LibraryArchive(computers: [link]).encoded())
        XCTAssertTrue(try XCTUnwrap(baseline.computers.first).isLink)
        var first = baseline
        first.setFolders(["临时"], in: .links)
        first.computers[0].linkFolder = "临时"
        var second = baseline
        second.folders = ["临时"]
        var a = LibraryReplica()
        try a.record(from: LibraryArchive(), to: baseline, writer: writer)
        var b = a
        try a.record(from: baseline, to: first, writer: writer)
        try b.record(from: baseline, to: second, writer: other)
        a.merge(b)
        b.merge(a)
        XCTAssertEqual(a.archive, b.archive)
        XCTAssertEqual(a.archive.folders, ["临时"])
        XCTAssertEqual(a.archive.folders(in: .links), ["临时"])
        var removed = a.archive
        removed.setFolders([], in: .links)
        removed.computers[0].linkFolder = nil
        try a.record(from: b.archive, to: removed, writer: writer)
        b.merge(try LibraryReplica.decode(JSONEncoder().encode(a)))
        XCTAssertEqual(b.archive.folders, ["临时"])
        XCTAssertTrue(b.archive.folders(in: .links).isEmpty)
        XCTAssertTrue(try XCTUnwrap(b.archive.computers.first).isLink)
    }
}
