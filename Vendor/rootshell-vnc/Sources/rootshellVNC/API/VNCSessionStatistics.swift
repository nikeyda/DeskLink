import Foundation
import RFBTransport

/// Point-in-time session statistics combining transport traffic with
/// decode-side progress. Obtain via ``VNCSession/currentStatistics()``.
public struct VNCSessionStatistics: Sendable, Equatable {
    public enum AudioPlayback: String, Codable, Sendable {
        case disabled, unavailable, waiting, playing, failed
    }

    /// Wire-level traffic and negotiated-mode counters.
    public let transport: TransportStatistics

    // Video decode pipeline (High Performance mode), summed across displays.
    public let framesSubmitted: UInt64
    public let framesDecoded: UInt64
    public let decodedVideoCodec: UInt32?
    public let audioPlayback: AudioPlayback?
    public let lossGapsDetected: Int
    public let framesDroppedWhileGated: Int

    public let capturedAt: Date
}
