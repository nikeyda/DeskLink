import XCTest
@testable import DeskLink

final class LibrarySyncTests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
    @MainActor func testLocalDocumentsSelectionIsIdentifiedAfterSyncAndRelaunch() async throws {
        let documents = URL.documentsDirectory
        let selected = documents.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let state = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: selected)
            try? FileManager.default.removeItem(at: state)
        }
        XCTAssertEqual(ReplicaFolder.location(of: documents), .localDocuments)
        XCTAssertNil(ReplicaFolder.location(of: state))
        let settings = state.appending(path: "sync.json")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = LibrarySync(settings: settings, defaults: defaults)
        try sync.select(selected)
        await sync.refresh(ConnectionLibrary(file: state.appending(path: "library.json")))
        XCTAssertNil(sync.error)
        XCTAssertEqual(sync.folderLocation, .localDocuments)
        XCTAssertEqual(LibrarySync(settings: settings, defaults: defaults).folderLocation, .localDocuments)
    }
    #endif

    func testOfflineConnectionsAddOnceAndDoNotOverwriteAConcurrentRename() throws {
        let a = UUID(), b = UUID()
        let prototype = Computer(name: "Workspace", endpoint: try Endpoint(address: "sorting.fixture.invalid"))
        let baseline = LibraryArchive(computers: [prototype])
        var laptop = LibraryReplica()
        try laptop.record(from: LibraryArchive(), to: baseline, writer: a)
        var tablet = laptop
        var first = prototype, second = prototype
        first.name = "Studio"
        first.recordConnection(at: Date(timeIntervalSince1970: 100), writer: a)
        second.recordConnection(at: Date(timeIntervalSince1970: 200), writer: b)
        second.recordConnection(at: Date(timeIntervalSince1970: 300), writer: b)
        try laptop.record(from: baseline, to: LibraryArchive(computers: [first]), writer: a)
        try tablet.record(from: baseline, to: LibraryArchive(computers: [second]), writer: b)
        var merged = laptop
        merged.merge(tablet)
        merged.merge(tablet)
        tablet.merge(laptop)
        XCTAssertEqual(merged, tablet)
        let item = try XCTUnwrap(merged.archive.computers.first)
        XCTAssertEqual(item.name, first.name)
        XCTAssertEqual(item.totalConnections, 3)
        XCTAssertEqual(item.lastConnected, second.lastConnected)
    }

    func testMacAndIPadPreserveDifferentDisplayChoicesAfterOfflineEdits() throws {
        let first = UUID(), second = UUID()
        var computer = Computer(name: "Desk", endpoint: try Endpoint(address: "screen.invalid"))
        computer.quality = .lossless
        let initial = LibraryArchive(computers: [computer])
        let previous = computer.display(for: .iPad)
        XCTAssertEqual(previous.quality, .lossless)
        var laptop = LibraryReplica()
        try laptop.record(from: LibraryArchive(), to: initial, writer: first)
        var tablet = laptop
        var mac = computer, iPad = computer
        let large = DesktopDisplayPreferences(quality: .adaptive, layout: .virtualPair, matchWindow: true,
                                              fixedDesktop: DesktopDimensions(width: 1920, height: 1080))
        let portable = DesktopDisplayPreferences(quality: .adaptive, matchWindow: true, smoothVideo: false)
        mac.setDisplay(large, for: .mac)
        iPad.setDisplay(portable, for: .iPad)
        iPad.name = "Studio"
        try laptop.record(from: initial, to: LibraryArchive(computers: [mac]), writer: first)
        try tablet.record(from: initial, to: LibraryArchive(computers: [iPad]), writer: second)
        laptop.merge(tablet)
        tablet.merge(laptop)
        XCTAssertEqual(laptop.archive, tablet.archive)
        var updated = try XCTUnwrap(laptop.archive.computers.first)
        XCTAssertEqual(updated.name, "Studio")
        XCTAssertEqual(updated.display(for: .mac), large)
        XCTAssertEqual(updated.display(for: .iPad), portable)
        updated.setDisplay(previous, for: .iPad)
        try tablet.record(from: tablet.archive, to: LibraryArchive(computers: [updated]), writer: second)
        laptop.merge(try LibraryReplica.decode(JSONEncoder().encode(tablet)))
        XCTAssertEqual(laptop.archive.computers.first?.display(for: .iPad), previous)
        XCTAssertEqual(laptop.archive.computers.first?.display(for: .mac), large)
        var deleted = laptop
        try deleted.record(from: deleted.archive, to: LibraryArchive(), writer: first)
        var other = updated
        other.setDisplay(portable, for: .iPad)
        try tablet.record(from: tablet.archive, to: LibraryArchive(computers: [other]), writer: second)
        deleted.merge(tablet)
        XCTAssertTrue(deleted.archive.computers.isEmpty)
    }

    @MainActor func testFolderSyncExchangesToolbarAndPointerSettingsWithoutChangingDeviceDecisions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shared = root.appending(path: "Shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSuite = UUID().uuidString, secondSuite = UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer { first.removePersistentDomain(forName: firstSuite); second.removePersistentDomain(forName: secondSuite) }
        let a = LibrarySync(settings: root.appending(path: "a/sync.json"), defaults: first)
        let b = LibrarySync(settings: root.appending(path: "b/sync.json"), defaults: second)
        let bookA = ConnectionLibrary(file: root.appending(path: "a/book.json"))
        let bookB = ConnectionLibrary(file: root.appending(path: "b/book.json"))
        try a.select(shared)
        try b.select(shared)
        first.set("floating", forKey: "toolbar.style")
        first.set(true, forKey: "credentials.synchronize")
        first.set(false, forKey: "connection.files")
        await a.refresh(bookA)
        await b.refresh(bookB)
        XCTAssertNil(a.error)
        XCTAssertNil(b.error)
        XCTAssertEqual(second.string(forKey: "toolbar.style"), "floating")
        XCTAssertNil(second.object(forKey: "credentials.synchronize"))
        XCTAssertNil(second.object(forKey: "connection.files"))
        second.set(1.75, forKey: "pointer.speed")
        first.set(true, forKey: "library.listLayout")
        await a.refresh(bookA)
        await b.refresh(bookB)
        await a.refresh(bookA)
        XCTAssertEqual(first.double(forKey: "pointer.speed"), 1.75)
        XCTAssertEqual(second.bool(forKey: "library.listLayout"), true)
        second.removeObject(forKey: "toolbar.style")
        await b.refresh(bookB)
        await a.refresh(bookA)
        XCTAssertNil(first.object(forKey: "toolbar.style"))
        XCTAssertFalse(a.preferencesChanged)
    }

    func testTwoWritersMergeOfflineEditsAndKeepDeletedRecordsDeleted() throws {
        let first = UUID(), second = UUID()
        var a = Computer(name: "Desk", endpoint: try Endpoint(address: "first.invalid:5909"))
        a.folder = "Lab"
        let b = Computer(name: "Spare", endpoint: try Endpoint(address: "second.invalid"))
        let initial = LibraryArchive(folders: ["Lab"], computers: [a, b])
        var one = LibraryReplica()
        try one.record(from: LibraryArchive(), to: initial, writer: first)
        var two = one
        var renamed = a
        renamed.name = "Desk 2"
        try one.record(from: initial, to: LibraryArchive(folders: ["Lab"], computers: [renamed, b]), writer: first)
        let independent = LibraryArchive(folders: ["Lab"], computers: [a])
        try two.record(from: initial, to: independent, writer: second)
        var left = one, right = two
        left.merge(two)
        right.merge(one)
        XCTAssertEqual(left, right)
        XCTAssertEqual(left.archive.computers, [renamed])
        let roundTrip = try LibraryReplica.decode(JSONEncoder().encode(left))
        var stale = LibraryReplica()
        try stale.record(from: LibraryArchive(), to: initial, writer: first)
        stale.merge(roundTrip)
        XCTAssertEqual(stale.archive, left.archive)
    }

    func testCoordinatedFolderPersistsBothWritersAndPreservesUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID()
        var first = LibraryReplica()
        let item = Computer(name: "Test", endpoint: try Endpoint(address: "unit.invalid"))
        try first.record(from: LibraryArchive(), to: LibraryArchive(computers: [item]), writer: a)
        _ = try ReplicaFolder.exchange(in: root, writer: a, pending: first)
        let folder = root.appending(path: "DeskLink")
        let unrelated = folder.appending(path: "Notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        var second = try ReplicaFolder.exchange(in: root, writer: b, pending: LibraryReplica())
        XCTAssertEqual(second.archive.computers, [item])
        var edit = item
        edit.name = "Renamed"
        edit.folder = "Work"
        try second.record(from: second.archive, to: LibraryArchive(folders: ["Work"], computers: [edit]), writer: b)
        _ = try ReplicaFolder.exchange(in: root, writer: b, pending: second)
        let next = try ReplicaFolder.exchange(in: root, writer: a, pending: first)
        XCTAssertEqual(next.archive.computers, [edit])
        XCTAssertEqual(next.archive.folders, ["Work"])
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        let mine = folder.appending(path: a.uuidString + ".desklink")
        let before = try Data(contentsOf: mine)
        try Data("invalid".utf8).write(to: folder.appending(path: UUID().uuidString + ".desklink"))
        XCTAssertThrowsError(try ReplicaFolder.exchange(in: root, writer: a, pending: next))
        XCTAssertEqual(try Data(contentsOf: mine), before)
    }

    @MainActor func testFolderRenameAndDeletePreserveItsConnections() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = ConnectionLibrary(file: root.appending(path: "library.json"))
        var entry = Computer(endpoint: try Endpoint(address: "unit.invalid"))
        entry.folder = "Lab"
        XCTAssertTrue(book.save(entry))
        XCTAssertTrue(book.addFolder("Existing"))
        XCTAssertFalse(book.renameFolder("Lab", to: "Existing"))
        XCTAssertTrue(book.renameFolder("Lab", to: "Desk"))
        XCTAssertEqual(book.archive.computers.first?.folder, "Desk")
        XCTAssertTrue(book.removeFolder("Desk"))
        XCTAssertEqual(book.archive.computers.first?.id, entry.id)
        XCTAssertNil(book.archive.computers.first?.folder)
    }
}
