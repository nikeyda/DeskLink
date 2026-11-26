import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor final class RemoteBellTests: XCTestCase {
    func testRemoteBellPlaysOnlyWhenEnabled() async throws {
        #if targetEnvironment(macCatalyst)
        // The sandboxed Mac viewer connects out. Run script/test_desktop.py on
        // loopback with --bell-check, and pass its port in the test environment.
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_BELL_PEER_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Start the loopback bell test peer and specify its port.")
        }
        #else
        let peer = LocalTestDisplay()
        let port = try await peer.start()
        defer { peer.stop() }
        #endif
        var computer = Computer(endpoint: try Endpoint(address: "127.0.0.1", defaultPort: port))
        var config = computer.configuration
        let play = try XCTUnwrap(config.serverBellHandler)
        XCTAssertNotNil(RemoteBell.sound)
        var bells = 0
        config.serverBellHandler = { bells += 1; play() }
        let session = VNCSession(configuration: config)
        defer { session.disconnect() }
        var lastText = ""
        session.onServerClipboardText = { lastText = $0 }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: ""))
        try await waitForText("DeskLink clipboard fixture", current: { lastText })
        for enabled in [true, false] {
            if !enabled {
                computer.allowsRemoteBell = false
                let disabled = computer.configuration
                XCTAssertNil(disabled.serverBellHandler)
                session.configuration.serverBellHandler = disabled.serverBellHandler
            }
            // The clipboard marker follows Bell on the same ordered RFB stream.
            let marker = enabled ? "after audible bell" : "after muted bell"
            #if targetEnvironment(macCatalyst)
            session.sendClipboardText(marker)
            #else
            try await peer.ringBell()
            try await peer.publishClipboard(marker)
            #endif
            try await waitForText(marker, current: { lastText })
            XCTAssertEqual(bells, 1)
        }
    }

    private func waitForText(_ expected: String, current: () -> String) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while current() != expected {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
