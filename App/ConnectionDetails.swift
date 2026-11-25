import CoreMedia
import RFBTransport
import SwiftUI
import rootshellVNC

struct ConnectionReport: Identifiable, Codable, Equatable {
    let id: UUID
    let startedAt: Date
    let capturedAt: Date
    let version: String?
    let encryption: String
    let width: Int
    let height: Int
    let usesVideo: Bool
    let encodings: [String]
    let frames: UInt64
    let audioPackets: UInt64?
    let receiveRate: Double?
    let pointerEvents: UInt64
    let keyEvents: UInt64
    var videoCodec: UInt32?
    var audioPlayback: VNCSessionStatistics.AudioPlayback?

    func videoCodecLabel(historical: Bool) -> String {
        guard let videoCodec else { return historical ? "未记录视频编码" : "等待视频帧" }
        switch videoCodec {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        default:
            let bytes = withUnsafeBytes(of: videoCodec.bigEndian) { Array($0) }
            if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) { return String(decoding: bytes, as: UTF8.self) }
            return String(format: "0x%08X", videoCodec)
        }
    }

    var audioPlaybackLabel: String? {
        switch audioPlayback {
        case .disabled: "已关闭"
        case .unavailable: "未就绪"
        case .waiting: "等待播放"
        case .playing: "播放引擎已启动"
        case .failed: "播放失败"
        case nil: nil
        }
    }

    @MainActor
    static func capture(session: VNCSession, usesSSH: Bool, id: UUID, startedAt: Date) async -> Self? {
        guard session.connectionState.isConnected, let stats = await session.currentStatistics(),
              session.connectionState.isConnected else { return nil }
        let wire = stats.transport
        let encryption: String
        switch session.negotiatedContentEncryption {
        case .some(.tlsX509): encryption = usesSSH ? "SSH、TLS" : "TLS"
        case .some(.appleComCryption(_, _, let media)):
            let apple = media ? "Apple 屏幕共享加密、SRTP" : "Apple 屏幕共享加密"
            encryption = usesSSH ? "SSH、" + apple : apple
        case .some(.none): encryption = usesSSH ? "SSH" : "未加密"
        case nil: encryption = usesSSH ? "SSH" : "正在协商"
        }
        return Self(id: id, startedAt: startedAt, capturedAt: stats.capturedAt,
                    version: session.getDiagnostics().clientVersion?.description, encryption: encryption,
                    width: session.framebufferWidth, height: session.framebufferHeight,
                    usesVideo: wire.isHighPerformanceMode, encodings: wire.encodingUsage.map(\.encoding.displayName),
                    frames: wire.isHighPerformanceMode ? stats.framesDecoded : wire.framebufferUpdateCount,
                    audioPackets: wire.isHighPerformanceMode ? wire.audioPacketsReceived : nil,
                    receiveRate: wire.recentBitrateKbps, pointerEvents: wire.pointerEventsSent, keyEvents: wire.keyEventsSent,
                    videoCodec: stats.decodedVideoCodec, audioPlayback: stats.audioPlayback)
    }
}

struct ConnectionDetails: View {
    let report: ConnectionReport?
    var historical = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let report {
                    Section {
                        if historical { row("记录时间", report.capturedAt.formatted(date: .abbreviated, time: .standard), id: "date") }
                        if let version = report.version { row("协议", version, id: "protocol") }
                        row("传输加密", report.encryption, id: "encryption")
                        row("桌面像素", "\(report.width) × \(report.height)", id: "dimensions")
                    }
                    Section("画面与音频") {
                        if report.usesVideo {
                            row("视频编码", report.videoCodecLabel(historical: historical), id: "encoding")
                            row("已解码视频帧", String(report.frames), id: "frames")
                            if let packets = report.audioPackets { row("收到的音频包", String(packets), id: "audio") }
                            if let playback = report.audioPlaybackLabel { row("音频播放", playback, id: "audioPlayback") }
                        } else {
                            row("画面编码", report.encodings.isEmpty ? "等待画面" : report.encodings.joined(separator: "、"), id: "encoding")
                            row("画面更新次数", String(report.frames), id: "frames")
                        }
                        if let rate = report.receiveRate {
                            row(historical ? "记录时的接收速率" : "当前接收速率", "\(rate.formatted(.number.precision(.fractionLength(0)))) kb/s", id: "bitrate")
                        }
                    }
                    Section("已发送的输入") {
                        row("指针事件", String(report.pointerEvents), id: "pointer")
                        row("键盘事件", String(report.keyEvents), id: "keys")
                    }
                } else { ProgressView() }
            }
            .navigationTitle(historical ? "上次连接信息" : "连接信息")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("details.done")
                }
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String, id: String) -> some View {
        LabeledContent(label, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(verbatim: value))
            .accessibilityIdentifier("details." + id)
    }
}
