import RFBProtocol
import RFBTransport
import XCTest
@testable import DeskLink
import rootshellVNC

@MainActor
final class PortableCodecWireTests: XCTestCase {
    private let qualityEncodings = Set(Int32(-32)...Int32(-23))

    func testStandardHandshakeHonorsDisabledCodecsAndJPEGDependency() async throws {
        let baseline = try await advertised(disabling: [])
        XCTAssertTrue(baseline.isSuperset(of: [7, 16, -239, -240, 0]))
        XCTAssertEqual(baseline.intersection(qualityEncodings), [-29])

        let filtered = try await advertised(disabling: [7, 16, -239, 0])
        XCTAssertTrue(filtered.isDisjoint(with: [7, 16, -239, -240, 0]))
        XCTAssertTrue(filtered.isDisjoint(with: qualityEncodings))
        XCTAssertTrue(filtered.isSuperset(of: [-224, 6, 1, -223, -308]))
    }

    func testTightJPEGQualityAdvertisesEachLevelAndHonorsCompressionScope() async throws {
        for level in 0...9 {
            let encodings = try await advertised(quality: FramebufferQuality(compression: .always, tightJPEGQuality: level))
            XCTAssertEqual(encodings.intersection(qualityEncodings), [Int32(-32 + level)])
        }
        let remoteOnly = FramebufferQuality(compression: .remoteOnly, tightJPEGQuality: 9)
        let local = try await advertised(quality: remoteOnly, local: true)
        XCTAssertTrue(local.isDisjoint(with: qualityEncodings))
        let remote = try await advertised(quality: remoteOnly, local: false)
        XCTAssertEqual(remote.intersection(qualityEncodings), [-23])
        let disabled = try await advertised(quality: FramebufferQuality(compression: .never, tightJPEGQuality: 9))
        XCTAssertTrue(disabled.isDisjoint(with: qualityEncodings))
    }

    private func advertised(disabling codes: [Int32] = [], quality: FramebufferQuality = FramebufferQuality(compression: .always),
                            local: Bool = false) async throws -> Set<Int32> {
        let peer = CodecHandshakePeer(local: local)
        var computer = Computer(endpoint: try Endpoint(address: "codec-wire.fixture.invalid"))
        computer.framebufferQuality = quality
        computer.disabledVNCCodecs = codes
        var config = computer.configuration
        config.transportProvider = { _, _ in peer }
        let session = VNCSession(configuration: config)
        try await session.connect(credentials: VNCCredentials(host: computer.endpoint.host, port: computer.endpoint.port,
                                                               password: "", username: nil))
        let encodings = await peer.encodings
        session.disconnect()
        return encodings
    }
}

private actor CodecHandshakePeer: RFBConnection {
    let local: Bool

    private var input = Data("RFB 003.008\n".utf8) + Data([
        1, 1, 0, 0, 0, 0, // None authentication with a successful result.
        0, 160, 0, 96, // Framebuffer geometry.
        32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
        0, 0, 0, 4, 84, 101, 115, 116 // Server name: Test.
    ])
    private(set) var encodings = Set<Int32>()

    init(local: Bool) { self.local = local }

    func isOnLocalNetwork() async -> Bool { local }

    func connect() async throws {}

    func read(exactly count: Int) async throws -> Data {
        guard input.count >= count else { throw VNCProtocolError.connectionClosed }
        let bytes = Data(input.prefix(count))
        input.removeFirst(count)
        return bytes
    }

    func read(upTo maxCount: Int) async throws -> Data {
        guard !input.isEmpty else { throw VNCProtocolError.connectionClosed }
        return try await read(exactly: min(maxCount, input.count))
    }

    func send(_ data: Data) async throws {
        let bytes = [UInt8](data)
        // SetPixelFormat and SetEncodings may be issued in one write.
        let offset = bytes.count >= 20 && bytes[0] == 0 ? 20 : 0
        guard bytes.count >= offset + 4, bytes[offset] == 2 else { return }
        let start = offset + 4
        let end = start + 4 * (Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3]))
        guard bytes.count >= end else { return }
        encodings = Set(stride(from: start, to: end, by: 4).map { index in
            Int32(bitPattern: bytes[index..<index + 4].reduce(0) { ($0 << 8) | UInt32($1) })
        })
    }

    func close() async {}
    func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {}
}
