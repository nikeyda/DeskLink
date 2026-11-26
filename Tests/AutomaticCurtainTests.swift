import RFBProtocol
import RFBTransport
import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor
final class AutomaticCurtainTests: XCTestCase {
    func testAutomaticCurtainWaitsForAnEligibleDesktopAndLeavesManualRestoreInEffect() async throws {
        let note = "维护中 🔒"
        let (session, peer) = try await connect(message: note)
        defer { session.disconnect() }

        await peer.announceDesktop(flags: 0x16) // Login Window, curtain available, on console.
        try await waitUntil { session.supportsCurtainMode }
        try await Task.sleep(for: .milliseconds(100))
        let atLogin = await peer.requests
        XCTAssertTrue(atLogin.isEmpty)
        await peer.announceDesktop(flags: 0x04) // Display visible, curtain unavailable.
        try await waitUntil { !session.supportsCurtainMode }
        let unsupported = await peer.requests
        XCTAssertTrue(unsupported.isEmpty)

        await peer.announceDesktop(flags: 0x06)
        try await waitUntil { await peer.requests.count == 1 }
        let request = await peer.requests.first
        XCTAssertEqual(request, Data([12, 0, 0, 0, 0, UInt8(note.utf8.count)]) + Data(note.utf8))
        XCTAssertFalse(session.isCurtained)

        await peer.announceDesktop(flags: 0x02)
        try await waitUntil { session.isCurtained }
        session.setCurtainMode(false)
        try await waitUntil { await peer.requests.count == 2 }
        let restore = await peer.requests.last
        XCTAssertEqual(restore, Data([12, 0, 0, 1, 0, 0]))
        await peer.announceDesktop(flags: 0x06)
        try await waitUntil { !session.isCurtained }
        try await Task.sleep(for: .milliseconds(100))
        let final = await peer.requests
        XCTAssertEqual(final.count, 2)
    }

    func testAlreadyPrivateDesktopDoesNotGetAnotherCurtainRequest() async throws {
        let (session, peer) = try await connect(message: "")
        defer { session.disconnect() }
        await peer.announceDesktop(flags: 0x00) // Off-console desktop needs no curtain.
        try await waitUntil { session.isCurtained }
        await peer.announceDesktop(flags: 0x06)
        try await waitUntil { !session.isCurtained && session.supportsCurtainMode }
        try await Task.sleep(for: .milliseconds(100))
        let requests = await peer.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCurtainPreferenceCanBeSuspendedWhileTheSessionIsReadOnly() async throws {
        let (session, peer) = try await connect(message: nil)
        defer { session.disconnect() }
        await peer.announceDesktop(flags: 0x06)
        try await waitUntil { session.supportsCurtainMode }
        try await Task.sleep(for: .milliseconds(100))
        let readOnly = await peer.requests
        XCTAssertTrue(readOnly.isEmpty)

        session.configuration.automaticCurtainMessage = ""
        try await waitUntil { await peer.requests.count == 1 }
        let request = await peer.requests.first
        XCTAssertEqual(request, Data([12, 0, 0, 0, 0, 0]))
    }

    private func connect(message: String?) async throws -> (VNCSession, CurtainTestPeer) {
        let peer = CurtainTestPeer()
        var computer = Computer(endpoint: try Endpoint(address: "curtain.fixture.invalid"))
        computer.curtainsDisplayOnConnect = message == nil ? nil : true
        computer.curtainMessage = message
        var configuration = computer.configuration
        configuration.transportProvider = { _, _ in peer }
        let session = VNCSession(configuration: configuration)
        try await session.connect(credentials: VNCCredentials(host: computer.endpoint.host, password: ""))
        return (session, peer)
    }

    private func waitUntil(_ isReady: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !isReady() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A streaming loopback fixture with no access to any display or saved account.
private actor CurtainTestPeer: RFBConnection {
    private var buffer = Data("RFB 003.889\n".utf8) + Data([
        1, 1, 0, 0, 0, 0,
        0, 160, 0, 96, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
        0, 0, 0, 4, 84, 101, 115, 116
    ])
    private var readable: CheckedContinuation<Void, any Error>?
    private var closed = false
    private(set) var requests = [Data]()

    func connect() async throws {}

    func announceDesktop(flags: UInt8) {
        var metadata = [UInt8](repeating: 0, count: 22)
        metadata[1] = 20
        metadata[3] = 5
        metadata[19] = flags
        // One FramebufferUpdate rectangle, DisplayInfo2 metadata (1105).
        buffer.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 81] + metadata)
        let pending = readable
        readable = nil
        pending?.resume()
    }

    func read(exactly count: Int) async throws -> Data { try await read(minimum: count, maximum: count) }
    func read(upTo maxCount: Int) async throws -> Data { try await read(minimum: 1, maximum: maxCount) }

    private func read(minimum: Int, maximum: Int) async throws -> Data {
        while buffer.count < minimum {
            guard !closed else { throw VNCProtocolError.connectionClosed }
            try await withCheckedThrowingContinuation { readable = $0 }
        }
        let data = Data(buffer.prefix(maximum))
        buffer.removeFirst(data.count)
        return data
    }

    func send(_ data: Data) async throws {
        if data.first == 12, data.count >= 6 { requests.append(data) }
    }

    func close() async {
        closed = true
        let pending = readable
        readable = nil
        pending?.resume(throwing: VNCProtocolError.connectionClosed)
    }

    func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {}
}
