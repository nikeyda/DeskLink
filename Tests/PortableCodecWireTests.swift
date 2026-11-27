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

    func testImportedScreensColorDepthIsSentInTheFramebufferHandshake() async throws {
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "screens-generic", withExtension: "json")
            ?? bundle.url(forResource: "screens-generic", withExtension: "json", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let entries = try XCTUnwrap(source["screens"] as? [[String: Any]])
        for (depth, bits) in [(3, UInt8(8)), (1, 16), (2, 32)] {
            var document = source
            var entry = try XCTUnwrap(entries.first)
            entry["colorDepth"] = depth
            entry["authenticationMethod"] = DesktopAuthentication.unauthenticated.rawValue
            entry["users"] = []
            document["screens"] = [entry]
            let archive = try ScreensArchive.convert(JSONSerialization.data(withJSONObject: document))
            let computer = try XCTUnwrap(archive.computers.first)
            let peer = CodecHandshakePeer(local: true)
            var config = computer.configuration
            config.transportProvider = { _, _ in peer }
            let session = VNCSession(configuration: config)
            defer { session.disconnect() }
            try await session.connect(credentials: VNCCredentials(host: computer.endpoint.host, port: computer.endpoint.port,
                                                                   password: "", username: nil))
            let requested = await peer.requestedBitsPerPixel
            XCTAssertEqual(requested, bits)
        }
    }

    func testExplicitDesktopAuthenticationIsHonoredOnTheWire() async throws {
        for (method, expected) in [(DesktopAuthentication.unauthenticated, SecurityType.none), (.vncPassword, .vncAuthentication)] {
            var computer = Computer(endpoint: try Endpoint(address: "authentication.fixture.invalid"))
            computer.authentication = method
            let peer = CodecHandshakePeer(local: true, offered: [.none, .vncAuthentication], accepts: expected)
            var config = computer.configuration
            config.transportProvider = { _, _ in peer }
            let session = VNCSession(configuration: config)
            try await session.connect(credentials: VNCCredentials(host: computer.endpoint.host, port: computer.endpoint.port,
                                                                   password: "fixture", username: nil))
            let packets = await peer.writes
            XCTAssertEqual(packets.dropFirst().first, Data([expected.rawValue]))
            if method == .vncPassword {
                // OpenSSL DES against the fixture challenge using the bit-reversed password.
                let response = Data([182, 205, 254, 172, 16, 166, 164, 86, 181, 213, 58, 22, 68, 167, 164, 117])
                XCTAssertEqual(packets.dropFirst(2).first, response)
            }
            else { XCTAssertEqual(packets.dropFirst(2).first, Data([1])) }
            session.disconnect()
        }

        let peer = CodecHandshakePeer(local: true)
        var computer = Computer(endpoint: try Endpoint(address: "authentication.fixture.invalid"))
        computer.authentication = .vncPassword
        var config = computer.configuration
        config.transportProvider = { _, _ in peer }
        let session = VNCSession(configuration: config)
        do {
            try await session.connect(credentials: VNCCredentials(host: computer.endpoint.host, port: computer.endpoint.port,
                                                                   password: "fixture", username: nil))
            XCTFail("A password-only connection must not fall back to unauthenticated access.")
        } catch let error as VNCError {
            guard case .authenticationFailed = error else { return XCTFail("Unexpected connection error: \(error)") }
        }
        let refusedWrites = await peer.writes
        XCTAssertEqual(refusedWrites, [Data("RFB 003.008\n".utf8)])
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

    private var input: Data
    private(set) var encodings = Set<Int32>()
    private(set) var requestedBitsPerPixel: UInt8?
    private(set) var writes: [Data] = []

    init(local: Bool, offered: [SecurityType] = [.none], accepts: SecurityType = .none) {
        self.local = local
        var input = Data("RFB 003.008\n".utf8)
        input.append(UInt8(offered.count))
        input.append(contentsOf: offered.map(\.rawValue))
        if accepts == .vncAuthentication { input.append(contentsOf: 0..<16) }
        input.append(contentsOf: [
            0, 0, 0, 0, // Successful SecurityResult.
            0, 160, 0, 96, // Framebuffer geometry.
            32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
            0, 0, 0, 4, 84, 101, 115, 116 // Server name: Test.
        ])
        self.input = input
    }

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
        writes.append(data)
        let bytes = [UInt8](data)
        // SetPixelFormat and SetEncodings may be issued in one write.
        let offset = bytes.count >= 20 && bytes[0] == 0 ? 20 : 0
        if offset != 0 { requestedBitsPerPixel = bytes[4] }
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
