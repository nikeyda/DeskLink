import UniformTypeIdentifiers
import XCTest
@testable import RFBTransport
@testable import rootshellVNC
@testable import DeskLink

@MainActor
final class FileTransferTests: XCTestCase {
    typealias Wire = AppleFileTransferProtocol

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DeskLink-transfer-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func receive(_ messages: [Wire.ServerMessage], in controller: VNCFileTransferController) {
        for message in messages { controller.handle(message, acknowledge: { _ in }) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderValueNotFound) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func receiveFile(named name: String, bytes: Data, session: UInt32,
                             in controller: VNCFileTransferController) async throws -> VNCFileTransfer {
        let id = controller.startDownload(paths: ["/Fixture/" + name], dragImage: nil)
        receive([.item(session: session, .init(kind: .file, name: name, level: 0, dataSize: UInt64(bytes.count))),
                 .fileData(session: session, bytes), .end(session: session, status: 0)], in: controller)
        try await waitUntil { controller.transfers.first(where: { $0.id == id })?.isActive == false }
        return try XCTUnwrap(controller.transfers.first(where: { $0.id == id }))
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func testDownloadTargetRequiresContinuousDwellAndShowsReadinessWhileStationary() async throws {
        let controller = VNCFileTransferController()
        controller.updateSupport(upload: false, download: true)
        let reply = Wire.DragOutReply(handle: 3, paths: ["/Fixture/sample.txt"], dragImagePNG: nil)
        let second = Wire.DragOutReply(handle: 4, paths: ["/Fixture/other.txt"], dragImagePNG: nil)
        let rect = CGRect(x: 150, y: 200, width: 200, height: 56)
        controller.dragOutTarget = rect

        func enterTarget() {
            controller.observePointer(buttonMask: 1, x: 250, y: 275)
            controller.observePointer(buttonMask: 1, x: 250, y: 235)
            controller.handle(reply)
        }

        func release() { controller.observePointer(buttonMask: 0, x: 250, y: 235) }

        enterTarget()
        XCTAssertTrue(controller.showsDragOutTarget)
        XCTAssertFalse(controller.remoteDragOverTarget)
        release()
        XCTAssertEqual(controller.dragStatistics.downloadRequests, 0)

        enterTarget()
        try await waitUntil { controller.remoteDragOverTarget }
        controller.handle(reply)
        XCTAssertTrue(controller.remoteDragOverTarget, "Repeated announcements for the same files must not restart dwell")
        controller.observePointer(buttonMask: 1, x: 250, y: 260)
        XCTAssertTrue(controller.showsDragOutTarget)
        XCTAssertFalse(controller.remoteDragOverTarget)
        controller.observePointer(buttonMask: 1, x: 250, y: 235)
        XCTAssertFalse(controller.remoteDragOverTarget)
        try await waitUntil { controller.remoteDragOverTarget }
        controller.dragOutTarget = rect.offsetBy(dx: 3, dy: 0)
        XCTAssertFalse(controller.remoteDragOverTarget)
        try await waitUntil { controller.remoteDragOverTarget }
        controller.handle(second)
        XCTAssertEqual(controller.remoteDraggedNames, ["other.txt"])
        XCTAssertFalse(controller.remoteDragOverTarget)
        try await waitUntil { controller.remoteDragOverTarget }
        release()
        XCTAssertEqual(controller.dragStatistics.downloadRequests, 1)
        XCTAssertFalse(controller.remoteDragOverTarget)
        XCTAssertFalse(controller.showsDragOutTarget)
    }

    private final class BackgroundRuntime: VNCFileTransferBackgroundRuntime {
        let cancel: @MainActor () -> Void
        var progress: Double?
        var completions: [Bool] = []

        init(cancel: @escaping @MainActor () -> Void) { self.cancel = cancel }

        func updateProgress(_ fraction: Double?) { progress = fraction }
        func finish(success: Bool) { completions.append(success) }
    }

    func testBackgroundTransferReportsProgressAndCancelsOnlyItsOwnFile() async throws {
        let store = VNCDownloadStore(root: try temporaryFolder())
        let controller = VNCFileTransferController(downloadStore: store)
        var runtimes: [UUID: BackgroundRuntime] = [:]
        controller.makeBackgroundRuntime = { transfer, cancel in
            let runtime = BackgroundRuntime(cancel: cancel)
            runtimes[transfer.id] = runtime
            return runtime
        }

        let first = controller.startDownload(paths: ["/Fixture/payload.txt"], dragImage: nil)
        let firstRuntime = try XCTUnwrap(runtimes[first])
        let second = controller.startDownload(paths: ["/Fixture/retry.txt"], dragImage: nil)
        let secondRuntime = try XCTUnwrap(runtimes[second])
        XCTAssertTrue(controller.hasTransfersInProgress)

        receive([.summary(session: 1, .init(totalBytes: 4, fileCount: 1, folderCount: 0)),
                 .item(session: 1, .init(kind: .file, name: "payload.txt", level: 0, dataSize: 4))], in: controller)
        try await waitUntil { firstRuntime.progress == 0 }
        // The download writer coalesces progress reports within 100 ms.
        try await Task.sleep(for: .milliseconds(125))
        receive([.fileData(session: 1, Data([1, 2]))], in: controller)
        try await waitUntil { firstRuntime.progress == 0.5 }
        firstRuntime.cancel()
        XCTAssertEqual(controller.transfers.first?.state, .cancelled)
        XCTAssertEqual(firstRuntime.completions, [false])
        XCTAssertTrue(controller.hasTransfersInProgress)

        let expected = Data([11, 22, 33, 44])
        receive([.item(session: 2, .init(kind: .file, name: "retry.txt", level: 0, dataSize: 4)),
                 .fileData(session: 2, expected), .end(session: 2, status: 0)], in: controller)
        try await waitUntil { secondRuntime.completions == [true] }
        XCTAssertFalse(controller.hasTransfersInProgress)
        let file = try XCTUnwrap(controller.transfers.last?.localURLs.first)
        XCTAssertEqual(try Data(contentsOf: file), expected)
        firstRuntime.cancel()
        XCTAssertEqual(firstRuntime.completions, [false])
    }

    func testReceiveArchiveForSystemFiles() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DESKLINK_FILES_FIXTURE"], let id = UUID(uuidString: raw) else {
            throw XCTSkip("Requires a matching archive identifier for the system Files check.")
        }
        var computer = Computer(name: "Files " + id.uuidString, endpoint: try Endpoint(address: "files.fixture.invalid"))
        computer.id = id
        let bytes = try LibraryArchive(computers: [computer]).encoded()
        let name = "DeskLink-" + id.uuidString + ".desklink"
        let controller = VNCFileTransferController()
        controller.updateSupport(upload: false, download: true)
        let result = try await receiveFile(named: name, bytes: bytes, session: 1, in: controller)
        XCTAssertEqual(result.state, .completed)
        let url = try XCTUnwrap(result.localURLs.first)
        XCTAssertEqual(url.standardizedFileURL.path, URL.documentsDirectory.appending(path: "Downloads/" + name).standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    func testDesktopDownloadTargetStillAcceptsImmediateRelease() {
        let controller = VNCFileTransferController()
        controller.updateSupport(upload: false, download: true)
        controller.dragOutTarget = CGRect(x: 150, y: 200, width: 200, height: 56)
        controller.observePointer(buttonMask: 1, x: 250, y: 275)
        controller.observePointer(buttonMask: 1, x: 250, y: 235)
        controller.handle(Wire.DragOutReply(handle: 3, paths: ["/Fixture/sample.txt"], dragImagePNG: nil))
        XCTAssertTrue(controller.remoteDragOverTarget)
        controller.observePointer(buttonMask: 0, x: 250, y: 235)
        XCTAssertEqual(controller.dragStatistics.downloadRequests, 1)
    }
    #endif

    func testPublishedDownloadsKeepNamesAndBytesAcrossRelaunchAndClearingHistory() async throws {
        let privateRoot = try temporaryFolder()
        let publicRoot = try temporaryFolder().appending(path: "Downloads", directoryHint: .isDirectory)
        let store = VNCDownloadStore(root: privateRoot)
        store.publishCompletedDownloads(in: publicRoot)
        let controller = VNCFileTransferController(downloadStore: store)
        controller.updateSupport(upload: false, download: true)
        let name = "测试报告.txt"
        let id = controller.startDownload(paths: ["/Fixture/" + name], dragImage: nil)
        receive([.item(session: 1, .init(kind: .file, name: name, level: 0, dataSize: 3)),
                 .fileData(session: 1, Data([1]))], in: controller)
        await store.refresh()
        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicRoot.appending(path: name).path))
        receive([.fileData(session: 1, Data([2, 3])), .end(session: 1, status: 0)], in: controller)
        try await waitUntil { controller.transfers.first?.state == .completed }
        let first = try XCTUnwrap(controller.transfers.first?.localURLs.first)
        XCTAssertEqual(first.path, publicRoot.appending(path: name).path)
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        await store.refresh()
        let oldListing = try XCTUnwrap(store.downloads.first(where: { $0.url.path == first.path }))
        let second = try await receiveFile(named: name, bytes: Data([4, 5]), session: 2, in: controller)
        XCTAssertEqual(second.state, .completed)
        let duplicate = try XCTUnwrap(second.localURLs.first)
        XCTAssertEqual(duplicate.lastPathComponent, "测试报告 2.txt")
        XCTAssertEqual(try Data(contentsOf: duplicate), Data([4, 5]))
        let mine = publicRoot.appending(path: "手动存入.txt")
        try Data([7]).write(to: mine)
        // Moving the first in Files frees its name. Removing its old row must preserve the new transfer.
        let renamed = publicRoot.appending(path: "我已改名.txt")
        try FileManager.default.moveItem(at: first, to: renamed)
        let third = try await receiveFile(named: name, bytes: Data([6]), session: 3, in: controller)
        XCTAssertEqual(third.localURLs.first?.path, first.path)
        controller.remove(id)
        XCTAssertEqual(try Data(contentsOf: first), Data([6]))
        // A confirmation sheet may still be showing the original item after Files renamed it.
        await store.delete(oldListing)
        XCTAssertEqual(try Data(contentsOf: first), Data([6]))
        controller.clearFinished()
        XCTAssertTrue(controller.transfers.isEmpty)
        let reopened = VNCDownloadStore(root: privateRoot)
        reopened.publishCompletedDownloads(in: publicRoot)
        await reopened.refresh()
        XCTAssertEqual(Set(reopened.downloads.map(\.name)), [name, duplicate.lastPathComponent, renamed.lastPathComponent])
        await reopened.delete(try XCTUnwrap(reopened.downloads.first(where: { $0.name == name })))
        XCTAssertEqual(try Data(contentsOf: duplicate), Data([4, 5]))
        await reopened.deleteAll()
        XCTAssertEqual(try Data(contentsOf: mine), Data([7]))
        XCTAssertTrue(reopened.downloads.isEmpty)
    }

    func testInterruptedIncomingDataStaysPrivateAndPublicationFailureRemainsRecoverable() async throws {
        let privateRoot = try temporaryFolder()
        let legacyFolder = privateRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try Data([8]).write(to: legacyFolder.appending(path: "旧版.txt"))
        let store = VNCDownloadStore(root: privateRoot)
        let blocked = try temporaryFolder().appending(path: "Downloads")
        try Data([0]).write(to: blocked)
        store.publishCompletedDownloads(in: blocked)
        let abandoned = store.makeFolder().appending(path: "未完成.bin")
        try Data([0]).write(to: abandoned)
        let controller = VNCFileTransferController(downloadStore: store)
        controller.updateSupport(upload: false, download: true)
        let file = try await receiveFile(named: "留存.bin", bytes: Data([3, 4]), session: 1, in: controller)
        guard case .failed = file.state else { return XCTFail("The Files destination was unavailable") }
        let recovered = try XCTUnwrap(file.localURLs.first)
        XCTAssertEqual(try Data(contentsOf: recovered), Data([3, 4]))
        let reopened = VNCDownloadStore(root: privateRoot)
        reopened.publishCompletedDownloads(in: blocked)
        await reopened.refresh()
        XCTAssertEqual(Set(reopened.downloads.map(\.name)), ["旧版.txt", "留存.bin"])
        XCTAssertEqual(try Data(contentsOf: blocked), Data([0]))
    }

    func testFilesDropStagesUnicodeNamesAndBytesIncludingAnEmptyFile() async throws {
        let source = try temporaryFolder()
        let staging = try temporaryFolder()
        let items: [(String, Data)] = [("文件-Δ.bin", Data((0..<65539).map { UInt8(truncatingIfNeeded: $0) })), ("空.bin", Data())]
        let providers = try items.map { name, bytes in
            let url = source.appending(path: name)
            try bytes.write(to: url)
            let provider = NSItemProvider()
            provider.suggestedName = name
            provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
            return provider
        }
        let result = await VNCFileTransferController.stage(providers, into: staging)
        XCTAssertTrue(result.failedNames.isEmpty)
        XCTAssertEqual(result.staged.map(\.lastPathComponent), items.map(\.0))
        XCTAssertEqual(try result.staged.map { try Data(contentsOf: $0) }, items.map(\.1))
    }

    func testRemoteDragDeliversFolderAndFileToDownloadListThenMovesThem() async throws {
        let store = VNCDownloadStore(root: try temporaryFolder())
        let publicRoot = try temporaryFolder().appending(path: "Downloads", directoryHint: .isDirectory)
        store.publishCompletedDownloads(in: publicRoot)
        let controller = VNCFileTransferController(downloadStore: store)
        controller.updateSupport(upload: true, download: true)
        let reply = Wire.DragOutReply(handle: 3, paths: ["/Fixture/资料"], dragImagePNG: nil)
        controller.dragOutTarget = CGRect(x: 100, y: 100, width: 50, height: 50)
        controller.observePointer(buttonMask: 1, x: 20, y: 20)
        controller.observePointer(buttonMask: 1, x: 50, y: 50)
        controller.handle(reply)
        XCTAssertTrue(controller.showsDragOutTarget)
        controller.observePointer(buttonMask: 1, x: 120, y: 120)
        try await waitUntil { controller.remoteDragOverTarget }
        controller.observePointer(buttonMask: 0, x: 120, y: 120)
        controller.handle(reply)
        XCTAssertEqual(controller.dragStatistics.remoteDrags, 1)
        XCTAssertEqual(controller.dragStatistics.fileAnnouncements, 1)
        XCTAssertEqual(controller.dragStatistics.downloadRequests, 1)
        XCTAssertEqual(controller.dragStatistics.downloadReplies, 1)
        XCTAssertEqual(controller.transfers.first?.name, "资料")
        let data = Data("一份完整的测试文件\nΔ\t✅".utf8)
        receive([
            .summary(session: 1, .init(totalBytes: UInt64(data.count), fileCount: 1, folderCount: 1)),
            .item(session: 1, .init(kind: .folder, name: "资料", level: 0)),
            .item(session: 1, .init(kind: .file, name: "样本.txt", level: 1, dataSize: UInt64(data.count))),
            .fileData(session: 1, data.prefix(5))
        ], in: controller)
        await store.refresh()
        XCTAssertTrue(store.downloads.isEmpty)
        receive([.fileData(session: 1, Data(data.dropFirst(5))), .end(session: 1, status: 0)], in: controller)
        try await waitUntil { controller.transfers.first?.state == .completed }
        try await waitUntil { store.downloads.count == 1 }
        let item = try XCTUnwrap(store.downloads.first)
        XCTAssertEqual(item.name, "资料")
        XCTAssertEqual(item.url.standardizedFileURL.path, publicRoot.appending(path: "资料").standardizedFileURL.path)
        XCTAssertEqual(item.byteCount, Int64(data.count))
        XCTAssertEqual(controller.transfers.first?.fractionCompleted, 1)
        let saved = try temporaryFolder().appending(path: item.name)
        try FileManager.default.moveItem(at: item.url, to: saved)
        store.downloadWasMoved(item)
        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: saved.appending(path: "样本.txt")), data)
    }

    func testDownloadTargetFitsVisibleDesktopAndLeavesRoomToStartDragging() throws {
        let visible = CGRect(x: 52, y: 60, width: 220, height: 390)
        for anchor in [CGPoint(x: 54, y: 62), CGPoint(x: 268, y: 444), CGPoint(x: 150, y: 230)] {
            let rect = try XCTUnwrap(VNCDragOutTargetView.targetFrame(in: visible, near: anchor))
            XCTAssertTrue(visible.contains(rect))
            XCTAssertFalse(rect.contains(anchor))
            XCTAssertLessThan(abs(rect.midY - anchor.y), rect.height)
        }
        let top = try XCTUnwrap(VNCDragOutTargetView.targetFrame(in: visible, near: nil))
        XCTAssertEqual(top.midX, visible.midX)
        XCTAssertEqual(top.minY, visible.minY + 16)
        XCTAssertNil(VNCDragOutTargetView.targetFrame(in: .zero, near: .zero))
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func testMovingAwayOrDismissingPreventsOnlyThisDragFromDownloading() {
        let controller = VNCFileTransferController()
        controller.updateSupport(upload: false, download: true)
        let reply = Wire.DragOutReply(handle: 3, paths: ["/Fixture/sample.txt"], dragImagePNG: nil)
        let rect = CGRect(x: 150, y: 200, width: 200, height: 56)
        controller.dragOutTarget = rect
        for explicitDismissal in [true, false] {
            controller.observePointer(buttonMask: 1, x: 250, y: 275)
            controller.observePointer(buttonMask: 1, x: 250, y: 250)
            controller.handle(reply)
            XCTAssertEqual(controller.remoteDragAnchor, CGPoint(x: 250, y: 275))
            XCTAssertTrue(controller.showsDragOutTarget)
            if explicitDismissal { controller.dismissDragOutTarget() }
            else { controller.observePointer(buttonMask: 1, x: 700, y: 275) }
            controller.handle(reply)
            controller.observePointer(buttonMask: 1, x: 250, y: 235)
            XCTAssertFalse(controller.showsDragOutTarget)
            XCTAssertFalse(controller.remoteDragOverTarget)
            controller.observePointer(buttonMask: 0, x: 250, y: 235)
            controller.handle(reply)
            XCTAssertTrue(controller.transfers.isEmpty)
            XCTAssertNil(controller.remoteDragAnchor)
        }
        XCTAssertEqual(controller.dragStatistics.remoteDrags, 2)
        XCTAssertEqual(controller.dragStatistics.downloadRequests, 0)
        controller.transportDidEnd()
        XCTAssertEqual(controller.dragStatistics.remoteDrags, 0)
        XCTAssertEqual(controller.dragStatistics.fileAnnouncements, 0)
    }
    #endif

    func testSuspendingNewTransfersPreservesAnAcceptedDownloadAndCancelsAnUnfinishedDrag() async throws {
        let store = VNCDownloadStore(root: try temporaryFolder())
        let controller = VNCFileTransferController(downloadStore: store)
        let session = VNCSession(configuration: VNCConfiguration())
        controller.session = session
        controller.updateSupport(upload: true, download: true)
        let downloadID = controller.startDownload(paths: ["/Fixture/accepted.txt"], dragImage: nil)
        receive([.item(session: 1, .init(kind: .file, name: "accepted.txt", level: 0, dataSize: 4)),
                 .fileData(session: 1, Data([1, 2]))], in: controller)
        let local = try temporaryFolder().appending(path: "dropped.txt")
        try Data([5, 6]).write(to: local)
        let provider = NSItemProvider()
        provider.suggestedName = local.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
            completion(local, false, nil)
            return nil
        }
        XCTAssertTrue(controller.beginUploadDrag(names: [local.lastPathComponent], x: 20, y: 20))
        let uploadID = try XCTUnwrap(controller.transfers.last?.id)
        controller.dropUpload(itemProviders: [provider], x: 40, y: 40)
        XCTAssertTrue(controller.beginUploadDrag(names: ["not-dropped.txt"], x: 20, y: 20))
        XCTAssertEqual(controller.transfers.last?.state, .dragging)

        controller.setNewTransfersSuspended(true)
        XCTAssertFalse(controller.canUpload)
        XCTAssertFalse(controller.canDownload)
        XCTAssertEqual(controller.transfers.map(\.id), [downloadID, uploadID])
        XCTAssertEqual(controller.transfers.first?.state, .transferring)
        XCTAssertEqual(controller.transfers.last?.state, .preparing)
        XCTAssertFalse(controller.beginUploadDrag(names: ["blocked.txt"], x: 20, y: 20))
        controller.observePointer(buttonMask: 1, x: 20, y: 20)
        controller.handle(Wire.DragOutReply(handle: 1, paths: ["/Fixture/blocked.txt"], dragImagePNG: nil))
        XCTAssertFalse(controller.showsDragOutTarget)
        let unrequested = Wire.ServerMessage.item(session: 99, .init(kind: .file, name: "blocked.txt", level: 0, dataSize: 4))
        receive([unrequested, .fileData(session: 99, Data([5, 6, 7, 8])),
                 .fileData(session: 1, Data([3, 4])), .end(session: 1, status: 0)], in: controller)
        try await waitUntil { controller.transfers.first?.state == .completed }
        await store.refresh()
        try await waitUntil { store.downloads.count == 1 }
        let file = try XCTUnwrap(store.downloads.first?.url)
        XCTAssertEqual(file.lastPathComponent, "accepted.txt")
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3, 4]))

        controller.setNewTransfersSuspended(false)
        XCTAssertTrue(controller.canUpload)
        XCTAssertTrue(controller.canDownload)
        controller.cancel(uploadID)
        XCTAssertEqual(controller.transfers.last?.state, .cancelled)
        withExtendedLifetime(session) {}
    }

    func testExplicitlyDisablingTransfersStillCancelsAStartedTransferWhileSuspended() throws {
        let controller = VNCFileTransferController(downloadStore: VNCDownloadStore(root: try temporaryFolder()))
        controller.updateSupport(upload: true, download: true)
        let id = controller.startDownload(paths: ["/Fixture/cancelled.txt"], dragImage: nil)
        controller.setNewTransfersSuspended(true)
        controller.setAllowed(false)
        controller.setNewTransfersSuspended(false)
        XCTAssertFalse(controller.canUpload)
        XCTAssertFalse(controller.canDownload)
        XCTAssertEqual(controller.transfers.first?.id, id)
        XCTAssertEqual(controller.transfers.first?.state, .cancelled)
    }

    func testCancelledAndDisconnectedTransfersDiscardPartialFilesAndAllowAnotherDownload() async throws {
        let store = VNCDownloadStore(root: try temporaryFolder())
        let controller = VNCFileTransferController(downloadStore: store)
        let bytes = Data([1, 2, 3])
        for session: UInt32 in 1...3 {
            controller.updateSupport(upload: true, download: true)
            let id = controller.startDownload(paths: ["/Fixture/file.bin"], dragImage: nil)
            receive([
                .item(session: session, .init(kind: .file, name: "file.bin", level: 0, dataSize: 3)),
                .fileData(session: session, Data(bytes.prefix(1)))
            ], in: controller)
            switch session {
            case 1:
                controller.cancel(id)
                XCTAssertEqual(controller.transfers.last?.state, .cancelled)
            case 2:
                controller.transportDidEnd()
                guard case .failed = controller.transfers.last?.state else { return XCTFail("Disconnected download must report a failure") }
            default:
                receive([.fileData(session: session, Data(bytes.dropFirst())), .end(session: session, status: 0)], in: controller)
                try await waitUntil { controller.transfers.last?.state == .completed }
            }
            await store.refresh()
            if session < 3 { XCTAssertTrue(store.downloads.isEmpty) }
        }
        try await waitUntil { store.downloads.count == 1 }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.downloads.first).url), bytes)
    }

    func testIncompleteFileIsReportedAndDoesNotAppearAmongSavedDownloads() async throws {
        let store = VNCDownloadStore(root: try temporaryFolder())
        let controller = VNCFileTransferController(downloadStore: store)
        controller.startDownload(paths: ["/Fixture/document.txt"], dragImage: nil)
        receive([
            .item(session: 1, .init(kind: .file, name: "document.txt", level: 0, dataSize: 9)),
            .fileData(session: 1, Data("short".utf8)),
            .end(session: 1, status: 0)
        ], in: controller)
        try await waitUntil { controller.transfers.first?.isActive == false }
        guard case .failed = controller.transfers.first?.state else { return XCTFail("The agreed byte count was not received") }
        await store.refresh()
        XCTAssertTrue(store.downloads.isEmpty)
    }

    func testResourceForkAndDataForkRemainDistinctAfterDownload() async throws {
        let store = VNCDownloadStore(root: try temporaryFolder())
        let publicRoot = try temporaryFolder().appending(path: "Downloads", directoryHint: .isDirectory)
        store.publishCompletedDownloads(in: publicRoot)
        let controller = VNCFileTransferController(downloadStore: store)
        let data = Data("ordinary content".utf8)
        let resource = Data((0..<70003).map { UInt8(truncatingIfNeeded: $0) })
        controller.startDownload(paths: ["/Fixture/design.bin"], dragImage: nil)
        receive([
            .item(session: 1, .init(kind: .file, name: "design.bin", level: 0,
                                    dataSize: UInt64(data.count), resourceForkSize: UInt64(resource.count))),
            .fileData(session: 1, data + resource.prefix(29)),
            .fileData(session: 1, Data(resource.dropFirst(29))),
            .end(session: 1, status: 0)
        ], in: controller)
        try await waitUntil { controller.transfers.first?.isActive == false }
        let output = try XCTUnwrap(controller.transfers.first?.localURLs.first)
        XCTAssertEqual(output.standardizedFileURL.path, publicRoot.appending(path: "design.bin").standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: output), data)
        let fork = URL(filePath: output.path + "/..namedfork/rsrc")
        XCTAssertEqual(try Data(contentsOf: fork), resource)
    }

    func testUploadSendsResourceOnlyFilesAndSplitsResourceBytesAcrossChunks() async throws {
        let source = try temporaryFolder().appending(path: "仅资源.bin")
        try Data().write(to: source)
        let resource = Data((0..<72005).map { UInt8(truncatingIfNeeded: $0) })
        try resource.write(to: source.appending(path: "..namedfork/rsrc"))
        let plan = try UploadPlan.make([source])
        XCTAssertEqual(plan.first?.bytes, Int64(resource.count))
        let packets = PacketLog()
        try await UploadPlan.stream(plan, sessions: [1], destination: "/Fixture",
                                    send: { await packets.append($0) }, progress: { _ in })
        let encoded = await packets.values
        var payload = Data()
        var item: Wire.Item?
        var summary: Wire.Summary?
        var chunkSizes: [Int] = []
        for packet in encoded {
            XCTAssertEqual(packet.first, Wire.fileCopyMessageType)
            XCTAssertEqual(try Wire.fileCopyPayloadLength(prefix: Data(packet.prefix(6))), packet.count - 6)
            switch Wire.serverMessage(payload: Data(packet.dropFirst(6))) {
            case .summary(_, let value): summary = value
            case .item(_, let value): item = value
            case .fileData(_, let bytes):
                payload.append(bytes)
                chunkSizes.append(bytes.count)
            default: break
            }
        }
        XCTAssertEqual(summary?.totalBytes, UInt64(resource.count))
        XCTAssertEqual(item?.name, source.lastPathComponent)
        XCTAssertEqual(item?.dataSize, 0)
        XCTAssertEqual(item?.resourceForkSize, UInt64(resource.count))
        XCTAssertEqual(chunkSizes, [32768, 32768, resource.count - 65536])
        XCTAssertEqual(payload, resource)
    }
}

private actor PacketLog {
    private(set) var values: [Data] = []
    func append(_ packet: Data) { values.append(packet) }
}
