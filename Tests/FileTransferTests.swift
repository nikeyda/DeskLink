import UniformTypeIdentifiers
import XCTest
@testable import RFBTransport
@testable import rootshellVNC

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
        let controller = VNCFileTransferController(downloadStore: store)
        controller.updateSupport(upload: true, download: true)
        let reply = Wire.DragOutReply(handle: 3, paths: ["/Fixture/资料"], dragImagePNG: nil)
        controller.dragOutTarget = CGRect(x: 100, y: 100, width: 50, height: 50)
        controller.observePointer(buttonMask: 1, x: 20, y: 20)
        controller.observePointer(buttonMask: 1, x: 50, y: 50)
        controller.handle(reply)
        XCTAssertTrue(controller.showsDragOutTarget)
        controller.observePointer(buttonMask: 1, x: 120, y: 120)
        XCTAssertTrue(controller.remoteDragOverTarget)
        controller.observePointer(buttonMask: 0, x: 120, y: 120)
        controller.handle(reply)
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
        XCTAssertEqual(item.byteCount, Int64(data.count))
        XCTAssertEqual(controller.transfers.first?.fractionCompleted, 1)
        let saved = try temporaryFolder().appending(path: item.name)
        try FileManager.default.moveItem(at: item.url, to: saved)
        store.downloadWasMoved(item)
        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: saved.appending(path: "样本.txt")), data)
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
