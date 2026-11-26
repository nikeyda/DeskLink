import CoreImage
import CoreMedia
@testable import RFBRendering
import rootshellVNC
import XCTest
import os

final class MediaPlaybackTests: XCTestCase {
    @MainActor
    func testHighPerformanceCloseWaitsForManualRetryAndStandardCloseRecovers() async throws {
        #if targetEnvironment(macCatalyst)
        guard let port = ProcessInfo.processInfo.environment["DESKLINK_CLOSE_PEER_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("Start the loopback test peer with --close-check and specify its port.")
        }
        #else
        let peer = LocalTestDisplay()
        let port = try await peer.start()
        defer { peer.stop() }
        #endif
        var configuration = VNCConfiguration()
        configuration.reconnectionPolicy.isEnabled = true
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        var connections = 0
        session.onServerClipboardText = { if $0 == "DeskLink clipboard fixture" { connections += 1 } }
        func wait(until condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(35))
            }
        }
        func endRemoteTransport() {
            #if targetEnvironment(macCatalyst)
            session.sendClipboardText("DeskLink end sharing")
            #else
            peer.dropCurrentConnection()
            #endif
        }
        try await session.connect(credentials: VNCCredentials(host: "127.0.0.1", port: port, password: ""))
        try await wait { connections == 1 }
        // The peer supplies a real TCP close. Set the negotiated mode independently
        // so the test isolates recovery policy without requiring an HEVC encoder.
        session.isHighPerformanceMode = true
        endRemoteTransport()
        try await wait { session.connectionState == .disconnected }
        XCTAssertNil(session.lastReconnectTrigger)
        XCTAssertTrue(session.retryConnection())
        try await wait { connections == 2 }
        XCTAssertEqual(session.lastReconnectTrigger, .manual)
        XCTAssertFalse(session.isHighPerformanceMode)
        endRemoteTransport()
        try await wait { connections == 3 }
        XCTAssertEqual(session.lastReconnectTrigger, .transportEnded)
    }

    private struct Frame: Sendable {
        let width: Int
        let height: Int
        let rgb: [UInt8]
    }

    private func packets(named name: String) throws -> [Data] {
        let bundle = Bundle(for: Self.self)
        let file = try XCTUnwrap(bundle.url(forResource: name, withExtension: "plist") ??
                                 bundle.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"))
        return try PropertyListDecoder().decode([Data].self, from: Data(contentsOf: file))
    }

    @MainActor
    func testAACELDStereoStartsTheRemoteAudioRendererAndAdvancesItsClock() async throws {
        // Core Audio encoded digital silence at 48 kHz with 480 frames per access unit.
        let packets = try packets(named: "aac-eld-silence")
        let timing = OSAllocatedUnfairLock(initialState: [AppleRemoteAudioPlaybackTiming]())
        let player = try AppleRemoteAudioPlayer { position in timing.withLock { $0.append(position) } }
        defer { player.stop() }
        XCTAssertFalse(player.diagnosticsSnapshot().isRunning)
        for packet in packets {
            XCTAssertTrue(AppleRemoteAudioPlayer.canHandleRTPPacket(packet))
            player.enqueueRTPPacket(packet)
            try await Task.sleep(for: .milliseconds(10))
        }
        let health = player.diagnosticsSnapshot()
        XCTAssertTrue(health.isRunning)
        XCTAssertFalse(health.rendererFailed)
        let times = timing.withLock { $0 }
        let first = try XCTUnwrap(times.first)
        let last = try XCTUnwrap(times.last)
        XCTAssertEqual(first.ssrc, 97_235)
        XCTAssertEqual(first.rtpTimestamp, 10_000)
        XCTAssertEqual(last.rtpTimestamp, 10_000 + 27 * 480)
        XCTAssertGreaterThan(last.hostTimeNanos, first.hostTimeNanos)
    }

    @MainActor
    func testIndependentHEVCStreamDecodesBothColorsAndPreservesDimensions() async throws {
        // x265 encoded three red and three blue 128 × 96 pictures with independent IDRs.
        // The fixture contains complete RFC 7798 packets, including parameter sets.
        let packets = try packets(named: "hevc-red-blue")
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        let manager = VideoStreamManager()
        let context = CIContext()
        manager.startStream(streamID: 97_234, width: 128, height: 96, usesDecodingOrderNumbers: false,
                            numberOfTiles: 1) { buffer, _ in
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cvPixelBuffer: buffer), toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: 64, y: 48, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let frame = Frame(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                              rgb: Array(rgba.prefix(3)))
            frames.withLock { $0.append(frame) }
        }
        defer { manager.stopStream() }
        XCTAssertNil(manager.decodedMediaSubtype)
        for packet in packets {
            XCTAssertNil(manager.feedRTPData(packet).errorDescription)
        }
        let deadline = ContinuousClock.now + .seconds(8)
        while frames.withLock({ $0.count }) < 6 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let result = frames.withLock { $0 }
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(manager.decodeProgress.decoderOutputCount, 6)
        XCTAssertEqual(manager.decodedMediaSubtype, kCMVideoCodecType_HEVC)
        for (index, frame) in result.enumerated() {
            XCTAssertEqual(frame.width, 128)
            XCTAssertEqual(frame.height, 96)
            XCTAssertGreaterThan(frame.rgb[index < 3 ? 0 : 2], 180)
            XCTAssertLessThan(frame.rgb[1], 65)
            XCTAssertLessThan(frame.rgb[index < 3 ? 2 : 0], 65)
        }
        manager.stopStream()
        XCTAssertNil(manager.decodedMediaSubtype)
    }
}
