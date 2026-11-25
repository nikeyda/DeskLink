import Foundation
import RFBProtocol

/// Per-computer policies for standard framebuffer connections and conventional RFB fallbacks.
public struct FramebufferQuality: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        case always, remoteOnly, never

        public func applies(onLocalNetwork local: Bool) -> Bool {
            switch self {
            case .always: true
            case .remoteOnly: !local
            case .never: false
            }
        }
    }

    public var adaptive: Scope
    public var compression: Scope

    public init(adaptive: Scope = .always, compression: Scope = .never) {
        self.adaptive = adaptive
        self.compression = compression
    }

    /// TightVNC JPEG quality 4 is pseudo-encoding -32 + 4.
    static let tightJPEGLevelFour = Encoding.unknown(-28)
}

/// Apple Standard screen sharing expresses pointer input in native desktop pixels,
/// even when it sends a half-resolution framebuffer to the viewer.
enum AppleFramebufferScale {
    case native, half

    static let halfResolutionRequest: Data = {
        var message = Data([8, 0])
        withUnsafeBytes(of: Double(0.5).bitPattern.bigEndian) { message.append(contentsOf: $0) }
        return message
    }()

    func framebufferLength(_ native: UInt16) -> UInt16 {
        self == .half && native > 0 ? max(1, native / 2) : native
    }

    func nativeCoordinate(_ pixel: UInt16) -> UInt16 {
        self == .half ? UInt16(clamping: Int(pixel) * 2) : pixel
    }

    func framebufferDisplay(_ display: AppleDisplayInfo) -> AppleDisplayInfo {
        guard self == .half else { return display }
        func axis(_ origin: Int32, _ size: UInt32) -> (origin: Int32, size: UInt32) {
            // Transform shared boundaries together, including monitors left of the main display.
            let start = Int64(origin) >> 1
            let end = (Int64(origin) + Int64(size)) >> 1
            return (Int32(start), size > 0 ? max(1, UInt32(end - start)) : 0)
        }
        let x = axis(display.originX, display.width)
        let y = axis(display.originY, display.height)
        return AppleDisplayInfo(displayIndex: display.displayIndex, originX: x.origin, originY: y.origin,
                                width: x.size, height: y.size, flags: display.flags)
    }
}
