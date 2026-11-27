import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices
import Observation
import RFBProtocol
import RFBTransport
import rootshellVNC
import os

struct SSHSettings: Codable, Equatable, Sendable {
    var port: UInt16 = 22
    var username = ""
    var usesKey = false
    var keyName: String?
    var server: String?
    // A missing value in older libraries continues to require the tunnel on every network.
    var secureLocally: Bool?

    func sameDestination(as other: Self) -> Bool {
        port == other.port && username == other.username && usesKey == other.usesKey
            && keyName == other.keyName && server == other.server
    }
}

enum SSHProof: Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

struct HostFingerprint: Identifiable {
    enum Kind: String, CaseIterable { case ssh, tls, rsa }
    var id: String { "\(kind.rawValue).trusted." + host }
    let kind: Kind
    let host: String
    let fingerprint: String

    var displayAddress: String {
        guard let separator = host.lastIndex(of: ":"), host[..<separator].contains(":"),
              let address = try? Endpoint.hostOnly(String(host[..<separator])),
              let port = UInt16(host[host.index(after: separator)...]) else { return host }
        return "[\(address)]:\(port)"
    }
}

@MainActor @Observable
final class HostTrust {
    private(set) var prompt: HostFingerprint?
    private var response: CheckedContinuation<(accept: Bool, remember: Bool), Never>?
    private var cancelled = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func saved(in defaults: UserDefaults) -> [HostFingerprint] {
        var entries: [HostFingerprint] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let fingerprint = value as? String else { continue }
            for kind in HostFingerprint.Kind.allCases {
                let prefix = kind.rawValue + ".trusted."
                if key.hasPrefix(prefix) {
                    let host = String(key.dropFirst(prefix.count))
                    entries.append(HostFingerprint(kind: kind, host: host, fingerprint: fingerprint))
                    break
                }
            }
        }
        return entries.sorted { left, right in
            if left.host == right.host { return left.kind.rawValue < right.kind.rawValue }
            return left.host < right.host
        }
    }

    static func forget(_ identity: HostFingerprint, in defaults: UserDefaults) {
        if defaults.string(forKey: identity.id) == identity.fingerprint { defaults.removeObject(forKey: identity.id) }
    }

    func verify(host: String, port: UInt16, fingerprint: String, kind: HostFingerprint.Kind = .ssh) async -> Bool {
        guard !cancelled else { return false }
        let key = "\(kind.rawValue).trusted.\(host):\(port)"
        if let pinned = defaults.string(forKey: key) { return pinned == fingerprint }
        guard response == nil else { return false }
        let accepted = await withCheckedContinuation { continuation in
            response = continuation
            prompt = HostFingerprint(kind: kind, host: "\(host):\(port)", fingerprint: fingerprint)
        }
        guard accepted.accept && !cancelled else { return false }
        if let pinnedByAnotherWindow = defaults.string(forKey: key) { return pinnedByAnotherWindow == fingerprint }
        if accepted.remember { defaults.set(fingerprint, forKey: key) }
        return true
    }

    func verifyCertificate(_ certificate: VNCCertificateValidationRequest) async -> VNCCertificateValidationResult {
        guard let leaf = certificate.certificateChainDER.first, !leaf.isEmpty else { return .reject }
        let digest = Data(SHA256.hash(data: leaf)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let fingerprint = "SHA256:" + digest
        guard await verify(host: certificate.host, port: certificate.port, fingerprint: fingerprint, kind: .tls) else { return .reject }
        return defaults.string(forKey: "tls.trusted.\(certificate.host):\(certificate.port)") == fingerprint ? .acceptAndStore : .acceptOnce
    }

    func answer(_ accept: Bool, remember: Bool = true) {
        let pending = response
        response = nil
        prompt = nil
        pending?.resume(returning: (accept, remember))
    }

    func cancel() {
        cancelled = true
        answer(false)
    }
}

private final class ServerIdentity: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let verify: @Sendable (String) async -> Bool
    init(verify: @escaping @Sendable (String) async -> Bool) { self.verify = verify }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let parts = String(openSSHPublicKey: hostKey).split(separator: " ")
        guard parts.count >= 2, let wire = Data(base64Encoded: String(parts[1])) else {
            validationCompletePromise.fail(VNCProtocolError.sshHostIdentityRejected)
            return
        }
        let digest = Data(SHA256.hash(data: wire)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        Task {
            if await verify("SHA256:" + digest) { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(VNCProtocolError.sshHostIdentityRejected) }
        }
    }
}

private final class LoginProof: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    var proof: SSHProof?
    private var rsaAlgorithms: [NIOSSHRSAUserAuthentication] = [.sha512, .sha256]

    init(username: String, proof: SSHProof) { self.username = username; self.proof = proof }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        let advertised = Set(algorithms)
        let supported = rsaAlgorithms.filter { advertised.contains($0.rawValue) }
        if !supported.isEmpty { rsaAlgorithms = supported }
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let offer: NIOSSHUserAuthenticationOffer.Offer
        switch proof {
        case .password(let password) where availableMethods.contains(.password):
            offer = .password(.init(password: password))
            proof = nil
        case .privateKey(let key) where availableMethods.contains(.publicKey):
            if key.isRSA, let algorithm = rsaAlgorithms.first {
                rsaAlgorithms.removeFirst()
                offer = .privateKey(.init(privateKey: key, rsaAlgorithm: algorithm))
                if rsaAlgorithms.isEmpty { proof = nil }
            } else {
                offer = .privateKey(.init(privateKey: key))
                proof = nil
            }
        default:
            nextChallengePromise.fail(VNCProtocolError.sshAuthenticationFailed)
            return
        }
        nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: offer))
    }
}

/// Preserves byte order across NIO's event loop and the RFB decoder. The decoder
/// performs a single sequential read while the network can deliver many fragments.
final class SSHInput: Sendable {
    typealias FailureHandler = @Sendable (VNCProtocolError) -> Void
    private struct Read {
        let minimum: Int
        let maximum: Int
        let completion: CheckedContinuation<Data, Error>
    }
    private struct State {
        var bytes = ByteBuffer()
        var waiting: Read?
        var error: VNCProtocolError?
        var handler: FailureHandler?

        mutating func resumeIfReady() {
            guard let read = waiting else { return }
            if bytes.readableBytes >= read.minimum {
                let size = min(bytes.readableBytes, read.maximum)
                let data = bytes.readSlice(length: size).map { Data($0.readableBytesView) } ?? Data()
                if bytes.readableBytes == 0 { bytes.clear() }
                else if bytes.readerIndex > 1024 * 1024 { bytes.discardReadBytes() }
                waiting = nil
                read.completion.resume(returning: data)
            } else if let error {
                waiting = nil
                read.completion.resume(throwing: error)
            }
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func read(minimum: Int, maximum: Int) async throws -> Data {
        guard minimum >= 0, maximum >= minimum else { throw VNCProtocolError.connectionClosed }
        if maximum == 0 { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                guard state.waiting == nil else {
                    continuation.resume(throwing: URLError(.resourceUnavailable))
                    return
                }
                state.waiting = Read(minimum: minimum, maximum: maximum, completion: continuation)
                state.resumeIfReady()
            }
        }
    }

    func append(_ buffer: ByteBuffer) -> Bool {
        state.withLock { state in
            guard state.error == nil, buffer.readableBytes <= 96 * 1024 * 1024 - state.bytes.readableBytes else {
                return false
            }
            state.bytes.writeImmutableBuffer(buffer)
            state.resumeIfReady()
            return true
        }
    }

    func finish(_ error: VNCProtocolError, notify: Bool) {
        let callback: FailureHandler? = state.withLock { state in
            guard state.error == nil else { return nil }
            state.error = error
            state.resumeIfReady()
            return notify ? state.handler : nil
        }
        callback?(error)
    }

    func setHandler(_ handler: FailureHandler?) { state.withLock { $0.handler = handler } }

    var failure: VNCProtocolError? { state.withLock { $0.error } }
}

private final class DesktopChannel: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    let input: SSHInput
    init(input: SSHInput) { self.input = input }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case let .byteBuffer(bytes) = packet.data, input.append(bytes) else {
            input.finish(.ioError(URLError(.badServerResponse).localizedDescription), notify: true)
            context.close(promise: nil)
            return
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(.init(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }

    func channelInactive(context: ChannelHandlerContext) {
        input.finish(.connectionClosed, notify: true)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        input.finish(.ioError(error.localizedDescription), notify: true)
        context.close(promise: nil)
    }
}

private final class SSHFailureHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let input: SSHInput

    init(input: SSHInput) { self.input = input }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Pending child channels otherwise fail with a generic close error.
        if let error = error as? VNCProtocolError { input.finish(error, notify: false) }
        context.close(promise: nil)
    }
}

/// One authenticated SSH channel carries the selected desktop session.
actor DesktopSSH: RFBConnection {
    nonisolated let transportRoute: RFBTransportRoute = .ssh
    let host: String
    let desktopPort: UInt16
    let settings: SSHSettings
    let proof: SSHProof
    let trust: HostTrust
    private let input = SSHInput()
    private var parent: Channel?
    private var desktop: Channel?
    private var closed = false

    init(host: String, desktopPort: UInt16, settings: SSHSettings, proof: SSHProof, trust: HostTrust) {
        self.host = host
        self.desktopPort = desktopPort
        self.settings = settings
        self.proof = proof
        self.trust = trust
    }

    static func configureTransport(_ configuration: inout VNCConfiguration, settings: SSHSettings,
                                   proof: SSHProof?, trust: HostTrust) {
        if settings.secureLocally == false {
            configuration.preferredLocalConnection = { host, port in
                try await TCPConnection.connectIfLocal(host: host, port: port, allowsLoopback: settings.server == nil)
            }
        }
        configuration.transportProvider = { host, port in
            guard let proof else { throw VNCProtocolError.sshAuthenticationFailed }
            return DesktopSSH(host: host, desktopPort: port, settings: settings, proof: proof, trust: trust)
        }
    }

    func connect() async throws {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        let settings = settings, trust = trust, proof = proof, input = input
        let server = settings.server ?? host
        let desktopHost = settings.server == nil ? "127.0.0.1" : host
        let verifier = ServerIdentity { fingerprint in
            await trust.verify(host: server, port: settings.port, fingerprint: fingerprint)
        }
        let bootstrap = NIOTSConnectionBootstrap(group: .singleton)
            .connectTimeout(.seconds(12))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    var role = SSHClientConfiguration(userAuthDelegate: LoginProof(username: settings.username, proof: proof),
                                                      serverAuthDelegate: verifier)
                    if case .privateKey(let key) = proof {
                        role.acceptsServerExtensionInfo = key.isRSA
                    }
                    let pipeline = channel.pipeline.syncOperations
                    try pipeline.addHandler(NIOSSHHandler(role: .client(role), allocator: channel.allocator, inboundChildChannelInitializer: nil))
                    try pipeline.addHandler(SSHFailureHandler(input: input))
                }
            }
        let destinationPort = desktopPort
        do {
            let transport = try await bootstrap.connect(host: server, port: Int(settings.port)).get()
            guard !closed else { try? await transport.close(); throw VNCProtocolError.connectionClosed }
            parent = transport
            let child = try await transport.eventLoop.flatSubmit {
                let handler: NIOSSHHandler
                let address: SocketAddress
                do {
                    handler = try transport.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                } catch { return transport.eventLoop.makeFailedFuture(error) as EventLoopFuture<Channel> }
                let result = transport.eventLoop.makePromise(of: Channel.self)
                let service = SSHChannelType.DirectTCPIP(targetHost: desktopHost, targetPort: Int(destinationPort), originatorAddress: address)
                handler.createChannel(result, channelType: .directTCPIP(service)) { child, _ in
                    child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(DesktopChannel(input: input)) }
                }
                return result.futureResult
            }.get()
            guard !closed else { try? await child.close(); throw VNCProtocolError.connectionClosed }
            desktop = child
        } catch {
            if let parent { try? await parent.close() }
            if let failure = input.failure { throw failure }
            throw error
        }
    }

    func read(exactly count: Int) async throws -> Data { try await input.read(minimum: count, maximum: count) }
    func read(upTo count: Int) async throws -> Data { try await input.read(minimum: min(count, 1), maximum: count) }
    func send(_ data: Data) async throws {
        guard !closed, let desktop else { throw VNCProtocolError.connectionClosed }
        try await desktop.writeAndFlush(ByteBuffer(bytes: data)).get()
    }
    func setDisconnectHandler(_ handler: SSHInput.FailureHandler?) async { input.setHandler(handler) }
    func close() async {
        closed = true
        input.finish(.connectionClosed, notify: false)
        let connection = parent
        parent = nil
        desktop = nil
        try? await connection?.close()
    }
}
