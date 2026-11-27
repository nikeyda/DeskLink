import RFBProtocol
@testable import RFBTransport
import UIKit
import UserNotifications
import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor final class ClipboardNotificationTests: XCTestCase {
    func testManualSendWaitsForTheWireAndReportsFailureWithoutChangingThePasteboard() async throws {
        let peer = ClipboardNoticePeer()
        var config = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        config.transportProvider = { _, _ in peer }
        let session = VNCSession(configuration: config)
        let board = UIPasteboard.withUniqueName()
        let fixture = "clipboard notice fixture"
        let remote = "remote notice fixture"
        defer { UIPasteboard.remove(withName: board.name) }
        try await connect(session, to: peer)
        defer { session.disconnect() }
        let controller = VNCClipboardSynchronizer(session: session, pasteboard: board)
        defer { controller.invalidate() }
        var results: [VNCManualClipboardResult] = []
        controller.onManualTransferResult = { results.append($0) }

        board.string = fixture
        controller.sendClipboard()
        try await waitUntil { await peer.attemptedWrites == 1 }
        XCTAssertTrue(results.isEmpty)
        await peer.releaseWrite()
        try await waitUntil { results == [.sent] }
        let uploaded = await peer.uploaded
        XCTAssertEqual(uploaded, [ClientMessage.clientCutText(fixture).serialize()])

        await peer.rejectNextWrite()
        controller.sendClipboard()
        try await waitUntil { results == [.sent, .sendFailed] }
        XCTAssertEqual(board.string, fixture)

        await peer.publish(remote)
        try await waitUntil { controller.hasRemoteClipboard }
        XCTAssertEqual(board.string, fixture)
        XCTAssertEqual(results, [.sent, .sendFailed])
        controller.getClipboard()
        XCTAssertEqual(board.string, remote)
        XCTAssertEqual(results, [.sent, .sendFailed, .received])
    }

    func testExtendedClipboardAnnouncementReportsThatTheContentsAreAvailable() async throws {
        let peer = ClipboardNoticePeer()
        var configuration = VNCConfiguration(enableHighPerformanceMode: false, videoQualityMode: .standard)
        configuration.transportProvider = { _, _ in peer }
        let session = VNCSession(configuration: configuration)
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        try await connect(session, to: peer)
        defer { session.disconnect() }
        let controller = VNCClipboardSynchronizer(session: session, pasteboard: board)
        defer { controller.invalidate() }
        await peer.releaseWrite()
        try await peer.advertiseNotifyOnly()
        try await waitUntil { session.supportsRemoteClipboardRequest }

        var results: [VNCManualClipboardResult] = []
        controller.onManualTransferResult = { results.append($0) }
        board.string = "extended clipboard fixture"
        controller.sendClipboard()
        try await waitUntil { results == [.advertised] }
        let last = await peer.uploaded.last
        XCTAssertEqual(last, try ExtendedClipboardProtocol.clientMessage(.notify(.text)))
    }

    func testNotificationRequiresPermissionPreferenceAndUnlockedApp() async throws {
        let suite = "ClipboardNoticeTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var requests: [UNNotificationRequest] = []
        let label = "Isolated Desktop"
        for result: VNCManualClipboardResult in [.sent, .advertised, .received, .sendFailed, .receiveFailed] {
            await ClipboardNotifications.post(result, computer: label, preferences: preferences, canPresent: { true },
                                               authorization: { .authorized }, deliver: { requests.append($0) })
        }
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(Set(requests.map(\.content.body)).count, 5)
        for request in requests {
            XCTAssertTrue(request.identifier.hasPrefix(ClipboardNotifications.requestPrefix))
            XCTAssertTrue(request.content.body.contains(label))
            XCTAssertTrue(request.content.userInfo.isEmpty)
            XCTAssertTrue(request.content.attachments.isEmpty)
        }
        await ClipboardNotifications.post(.received, computer: label, preferences: preferences, canPresent: { true },
                                           authorization: { .denied }, deliver: { _ in XCTFail("Permission denied") })
        await ClipboardNotifications.post(.received, computer: label, preferences: preferences, canPresent: { false },
                                           authorization: { XCTFail("Application is locked"); return .authorized },
                                           deliver: { _ in XCTFail("Application is locked") })
        await ClipboardNotifications.post(.received, computer: label, preferences: preferences, canPresent: { true },
                                           authorization: {
            preferences.set(false, forKey: ClipboardNotifications.preference)
            return .authorized
        }, deliver: { _ in XCTFail("User switched notifications off") })
        await ClipboardNotifications.post(.received, computer: label, preferences: preferences, canPresent: { true },
                                           authorization: { XCTFail("App preference is off"); return .authorized },
                                           deliver: { _ in XCTFail("App preference is off") })
    }

    #if targetEnvironment(simulator)
    func testSimulatorNotificationCenterDeliversTheClipboardNotice() async throws {
        let center = UNUserNotificationCenter.current()
        let authorized = try await center.requestAuthorization(options: [.alert, .provisional])
        XCTAssertTrue(authorized)
        let suite = "ClipboardNoticeSimulator." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let label = "Clipboard Notice " + UUID().uuidString
        var requestID: String?
        await ClipboardNotifications.post(.received, computer: label, preferences: preferences, canPresent: { true },
                                           deliver: { request in
            requestID = request.identifier
            try await center.add(request)
        })
        let id = try XCTUnwrap(requestID)
        defer { center.removeDeliveredNotifications(withIdentifiers: [id]) }
        try await waitUntil {
            await center.deliveredNotifications().contains {
                $0.request.identifier == id && $0.request.content.body.contains(label)
            }
        }
    }
    #endif

    private func connect(_ session: VNCSession, to peer: ClipboardNoticePeer) async throws {
        do {
            try await session.connect(credentials: .init(host: "notice.fixture.invalid", port: 5900, password: "", username: nil))
            try await waitUntil { session.connectionState.isConnected }
        } catch {
            let reads = await peer.requestedReads
            let writes = await peer.outboundTypes
            XCTFail("Clipboard fixture handshake, read sizes \(reads), client command bytes \(writes), error \(error)")
            throw error
        }
    }

    private func waitUntil(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await ready()) {
            if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ClipboardNoticePeer: RFBConnection {
    private var input = Data("RFB 003.008\n".utf8) + Data([
        1, 1, 0, 0, 0, 0,
        0, 160, 0, 96,
        32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
        0, 0, 0, 4, 84, 101, 115, 116,
    ])
    private var blocked = true
    private var reject = false
    private var closed = false
    private(set) var attemptedWrites = 0
    private(set) var uploaded: [Data] = []
    private(set) var requestedReads: [Int] = []
    private(set) var outboundTypes: [UInt8] = []

    func connect() async throws {}
    func isOnLocalNetwork() async -> Bool { true }

    func read(exactly count: Int) async throws -> Data {
        requestedReads.append(count)
        while input.count < count {
            guard !closed else { throw VNCProtocolError.connectionClosed }
            try await Task.sleep(for: .milliseconds(5))
        }
        let data = Data(input.prefix(count))
        input.removeFirst(count)
        return data
    }

    func read(upTo count: Int) async throws -> Data {
        while input.isEmpty {
            guard !closed else { throw VNCProtocolError.connectionClosed }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await read(exactly: min(count, input.count))
    }

    func send(_ data: Data) async throws {
        if let type = data.first { outboundTypes.append(type) }
        guard data.first == 6, data.count >= 8 else { return }
        attemptedWrites += 1
        while blocked && !closed { try await Task.sleep(for: .milliseconds(5)) }
        if reject || closed {
            reject = false
            throw URLError(.networkConnectionLost)
        }
        uploaded.append(data)
    }

    func releaseWrite() { blocked = false }
    func rejectNextWrite() { reject = true }

    func publish(_ text: String) {
        let content = Data(text.utf8)
        input.append(Data([3, 0, 0, 0, 0, 0, 0, UInt8(content.count)]))
        input.append(content)
    }

    func advertiseNotifyOnly() throws {
        var caps = try ExtendedClipboardProtocol.clientMessage(.caps(.text, [.notify, .request], maximumSizes: [1: 0]))
        caps[0] = 3
        input.append(caps)
    }

    func close() async { closed = true }
    func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {}
}
