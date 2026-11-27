import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import rootshellVNC

struct RemoteScreenshot: FileDocument {
    static let readableContentTypes = [UTType.png]
    private static let renderer = CIContext()
    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = bytes
    }

    init(frame: VNCPresentedFrame, region: CGRect? = nil) throws {
        data = try Self.pngData(for: Self.image(from: frame, region: region))
    }

    static func image(from frame: VNCPresentedFrame, region: CGRect?) throws -> CGImage {
        switch frame {
        case .image(let desktop):
            if let region {
                let bounds = CGRect(x: 0, y: 0, width: desktop.width, height: desktop.height)
                guard bounds.contains(region), !region.isEmpty, let part = desktop.cropping(to: region.integral) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return part
            } else { return desktop }
        case .surfaces(let surfaces):
            return try Self.render(surfaces, region: region)
        }
    }

    nonisolated static func pngData(for image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Screenshots use one image pixel per point without resampling the remote framebuffer.
        let properties = [kCGImagePropertyDPIWidth as String: 72, kCGImagePropertyDPIHeight as String: 72]
        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }

    private static func render(_ surfaces: [VNCPresentedFrame.Surface], region: CGRect?) throws -> CGImage {
        guard !surfaces.isEmpty, surfaces.allSatisfy({ !$0.region.isEmpty }) else { throw CocoaError(.fileWriteUnknown) }
        let bounds = surfaces.reduce(CGRect.null) { $0.union($1.region) }
        let crop = region ?? bounds
        guard bounds.contains(crop), !crop.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let visible = surfaces.filter { $0.region.intersects(crop) }
        guard let scale = visible.map({ CGFloat(CVPixelBufferGetWidth($0.pixelBuffer)) / $0.region.width }).max()
        else { throw CocoaError(.fileWriteUnknown) }
        func pixels(_ logical: CGRect) -> CGRect {
            CGRect(x: (logical.minX - bounds.minX) * scale, y: (bounds.maxY - logical.maxY) * scale,
                   width: logical.width * scale, height: logical.height * scale)
        }
        var composed = CIImage(color: .black)
        for surface in visible {
            let source = CIImage(cvPixelBuffer: surface.pixelBuffer)
            let rect = pixels(surface.region)
            let placed = source.transformed(by: CGAffineTransform(scaleX: rect.width / source.extent.width,
                                                                   y: rect.height / source.extent.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            composed = placed.composited(over: composed)
        }
        guard let output = renderer.createCGImage(composed, from: pixels(crop).integral, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return output
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor @Observable
final class ScreenshotExport {
    var document: RemoteScreenshot?
    var showing = false
    var error: String?

    func capture(_ session: VNCSession, region: CGRect? = nil) {
        guard session.connectionState.isConnected else { return }
        guard let frame = session.presentedFrame else { error = "请等远程画面显示后重试。"; return }
        do {
            document = try RemoteScreenshot(frame: frame, region: region)
            showing = true
        } catch { self.error = error.localizedDescription }
    }
}

struct ScreenshotExporter: ViewModifier {
    @Bindable var export: ScreenshotExport

    func body(content: Content) -> some View {
        content
            .fileExporter(isPresented: $export.showing, document: export.document, contentTypes: [.png],
                          defaultFilename: "远程屏幕快照") { result in
                export.document = nil
                if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled {
                    export.error = failure.localizedDescription
                }
            } onCancellation: { export.document = nil }
            .alert("无法保存屏幕快照", isPresented: Binding(get: { export.error != nil }, set: { if !$0 { export.error = nil } })) {
                Button("关闭", role: .cancel) {}
            } message: { Text(verbatim: export.error ?? "") }
    }
}
