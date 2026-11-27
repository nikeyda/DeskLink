import XCTest
import UIKit
import AVFoundation
import CoreImage
import ImageIO
import RFBProtocol
@testable import rootshellVNC
@testable import DeskLink

@MainActor final class MonitorWindowTests: XCTestCase {
    private func buffer(_ bgra: UInt32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let start = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
        for y in 0..<16 {
            let row = start.advanced(by: y * CVPixelBufferGetBytesPerRow(result)).assumingMemoryBound(to: UInt32.self)
            for x in 0..<32 { row[x] = bgra }
        }
        return result
    }

    func testExportedPNGCropsOneMonitorAndKeepsTheNativeVideoPixels() throws {
        let left = CGRect(x: 0, y: 4, width: 16, height: 8)
        let right = CGRect(x: 16, y: 0, width: 16, height: 8)
        let stream = VNCPresentedFrame.surfaces([
            .init(pixelBuffer: try buffer(0xff0000ff), region: left),
            .init(pixelBuffer: try buffer(0xffff0000), region: right),
        ])
        func decoded(_ screen: RemoteScreenshot) throws -> CGImage {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(screen.data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyDPIWidth as String] as? Double, 72)
            XCTAssertEqual(properties[kCGImagePropertyDPIHeight as String] as? Double, 72)
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let context = CIContext()
        func pixel(_ image: CGImage, x: Int, yFromTop: Int) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: x, y: image.height - 1 - yFromTop, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return rgba
        }
        let all = try decoded(RemoteScreenshot(frame: stream))
        XCTAssertEqual(all.width, 64)
        XCTAssertEqual(all.height, 24)
        XCTAssertEqual(pixel(all, x: 8, yFromTop: 2), [0, 0, 0, 255])
        XCTAssertEqual(pixel(all, x: 8, yFromTop: 16), [0, 0, 255, 255])
        XCTAssertEqual(pixel(all, x: 48, yFromTop: 4), [255, 0, 0, 255])
        let childScreenshot = try RemoteScreenshot(frame: stream, region: right)
        let child = try decoded(childScreenshot)
        XCTAssertEqual(child.width, 32)
        XCTAssertEqual(child.height, 16)
        XCTAssertEqual(pixel(child, x: 1, yFromTop: 1), [255, 0, 0, 255])
        let attachment = XCTAttachment(data: childScreenshot.data, uniformTypeIdentifier: "public.png")
        attachment.name = "Remote screenshot native pixels"
        attachment.lifetime = .keepAlways
        add(attachment)
        let standardCrop = CGRect(x: 0, y: 8, width: 32, height: 16)
        let standard = try decoded(RemoteScreenshot(frame: .image(all), region: standardCrop))
        XCTAssertEqual(standard.width, 32)
        XCTAssertEqual(standard.height, 16)
        XCTAssertEqual(pixel(standard, x: 1, yFromTop: 1), [0, 0, 255, 255])
        XCTAssertThrowsError(try RemoteScreenshot(frame: .image(all), region: .init(x: 99, y: 99, width: 2, height: 2)))
    }

    func testVideoPlacementCropsTheCombinedStreamAndExcludesOtherVirtualDisplays() {
        let left = CGRect(x: 0, y: 20, width: 100, height: 80)
        let right = CGRect(x: 100, y: 0, width: 160, height: 120)
        let desired = CGSize(width: 320, height: 300)
        let combined = left.union(right)
        let cropped = VideoMonitorPlacement(regions: [combined], crop: right, view: desired)
        XCTAssertEqual(cropped.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(cropped.frame(for: combined), CGRect(x: -200, y: 0, width: 520, height: 240))
        let virtual = VideoMonitorPlacement(regions: [left, right], crop: right, view: desired)
        XCTAssertNil(virtual.frame(for: left))
        XCTAssertEqual(virtual.frame(for: right), CGRect(x: 0, y: 0, width: 320, height: 240))
    }

    func testSelectingVirtualDisplayUsesItsOwnPictureAndGlobalInputOrigin() async throws {
        let session = VNCSession(configuration: .init(enableHighPerformanceMode: true, displaySizingMode: .matchClient,
                                                       displayMode: .twoVirtualDisplays))
        session.framebufferWidth = 64
        session.framebufferHeight = 16
        session.isHighPerformanceMode = true
        session.setVideoDisplayCount(2)
        XCTAssertEqual(session.selectableMonitorIDs, [1, 2])
        XCTAssertEqual(session.selectedMonitor, .all)
        XCTAssertEqual(session.windowMonitorRegion(for: 2), CGRect(x: 32, y: 0, width: 32, height: 16))
        XCTAssertNil(session.windowMonitorRegion(for: 3))
        let selected = try await session.selectMonitor(.display(2))
        XCTAssertTrue(selected)
        XCTAssertEqual(session.presentedFramebufferRegion, CGRect(x: 32, y: 0, width: 32, height: 16))
        session.secondaryVideoBandRenderer.setScreenSize(width: 32, height: 16)
        session.secondaryVideoBandRenderer.setBands([1: try buffer(0xffff0000)])
        XCTAssertTrue(session.isPresentingPicture)
        guard case let .surfaces(visible) = session.presentedFrame else { return XCTFail("The right display is ready") }
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.region, CGRect(x: 0, y: 0, width: 32, height: 16))
        let all = try await session.selectMonitor(.all)
        XCTAssertTrue(all)
        XCTAssertNil(session.presentedFrame)
        session.videoBandRenderer.setScreenSize(width: 32, height: 16)
        session.videoBandRenderer.setBands([2: try buffer(0xff0000ff)])
        guard case let .surfaces(both) = session.presentedFrame else { return XCTFail("Both displays are ready") }
        XCTAssertEqual(both.map(\.region.minX), [0, 32])
        session.setVideoDisplayCount(1)
        XCTAssertTrue(session.selectableMonitorIDs.isEmpty)
    }

    func testTwoVideoLayersReceiveTheSamePixelsAndRespectSuspendAndReset() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let renderer = VideoBandLayerRenderer()
        renderer.setScreenSize(width: 32, height: 16)
        renderer.configureExpectedBandCount(1)
        let first = VideoBandMirror(), second = VideoBandMirror()
        for (index, target) in [first, second].enumerated() {
            target.layer.frame = CGRect(x: index * 32, y: 0, width: 32, height: 16)
            target.display.frame = target.layer.bounds
            host.view.layer.addSublayer(target.layer)
        }
        renderer.attach(first)
        renderer.setBands([1: try buffer(0xffff0000)])
        renderer.attach(second)
        let context = CIContext()
        func red(_ target: VideoBandMirror) -> UInt8? {
            guard let frame = target.display.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cvPixelBuffer: frame), toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return rgba[0]
        }
        func matches(_ condition: @MainActor () -> Bool) async -> Bool {
            let until = ContinuousClock.now + .seconds(4)
            repeat {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(40))
            } while ContinuousClock.now < until
            return false
        }
        let firstFrame = await matches { [first, second].allSatisfy { (red($0) ?? 0) > 200 } }
        XCTAssertTrue(firstFrame, "Both separately hosted video layers must display the red frame")
        renderer.setPresentationSuspended(true)
        renderer.setBands([1: try buffer(0xff0000ff)])
        XCTAssertGreaterThan(red(first) ?? 0, 200)
        renderer.setPresentationSuspended(false)
        let nextFrame = await matches { [first, second].allSatisfy { (red($0) ?? 255) < 30 } }
        XCTAssertTrue(nextFrame)
        renderer.setPresentationSuspended(true)
        let third = VideoBandMirror()
        third.layer.frame = CGRect(x: 64, y: 0, width: 32, height: 16)
        third.display.frame = third.layer.bounds
        host.view.layer.addSublayer(third.layer)
        renderer.attach(third)
        XCTAssertNil(red(third))
        renderer.setPresentationSuspended(false)
        let resumed = await matches { (red(third) ?? 255) < 30 }
        XCTAssertTrue(resumed, "A window opened while suspended should receive the retained picture on resume")
        renderer.reset()
        let cleared = await matches { [first, second, third].allSatisfy { red($0) == nil } }
        XCTAssertTrue(cleared)
    }

    func testNewFramesPreserveEachWindowsCropThroughSuspendAndResume() throws {
        let renderer = StandardFramebufferLayerRenderer()
        let left = StandardFramebufferLayerTarget()
        let right = StandardFramebufferLayerTarget()
        let canvas = CGRect(x: 0, y: 0, width: 160, height: 80)
        let leftHalf = CGRect(x: 0, y: 0, width: 80, height: 80)
        let rightHalf = CGRect(x: 80, y: 0, width: 80, height: 80)
        renderer.attachTarget(left, cropRegion: leftHalf, brightnessGain: 1)
        renderer.attachTarget(right, cropRegion: rightHalf, brightnessGain: 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: canvas.size, format: format).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(leftHalf)
            UIColor.red.setFill()
            ctx.fill(rightHalf)
        }.cgImage)

        func crop(of target: StandardFramebufferLayerTarget) throws -> CGRect {
            try XCTUnwrap(target.containerLayer.sublayers?.first(where: { $0.contents != nil })).contentsRect
        }
        let expectedLeft = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        let expectedRight = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        renderer.present(image: image, cropRegion: canvas)
        XCTAssertEqual(try crop(of: left), expectedLeft)
        XCTAssertEqual(try crop(of: right), expectedRight)
        renderer.setPresentationSuspended(true)
        renderer.present(image: image, cropRegion: leftHalf)
        renderer.setPresentationSuspended(false)
        XCTAssertEqual(try crop(of: left), expectedLeft)
        XCTAssertEqual(try crop(of: right), expectedRight)
    }

    func testWindowCoordinatesUseTheCombinedRemoteCanvas() async throws {
        var computer = Computer(endpoint: try Endpoint(address: "window.fixture.invalid"))
        computer.layout = .combined
        let session = VNCSession(configuration: computer.configuration)
        session.framebufferWidth = 250
        session.framebufferHeight = 130
        let left = RFBScreenLayout(id: 71, x: 0, y: 10, width: 100, height: 80, flags: 0)
        let right = RFBScreenLayout(id: 6, x: 100, y: 0, width: 150, height: 130, flags: 0)
        await session.updateRemoteDisplayRegions([left, right])
        XCTAssertEqual(session.standardMonitorRegion(for: 71), CGRect(x: 0, y: 10, width: 100, height: 80))
        XCTAssertEqual(session.standardMonitorRegion(for: 6), CGRect(x: 100, y: 0, width: 150, height: 130))
        XCTAssertNil(session.standardMonitorRegion(for: 8))
        _ = try await session.selectMonitor(.display(71))
        XCTAssertNil(session.standardMonitorRegion(for: 6))
        session.isHighPerformanceMode = true
        XCTAssertTrue(session.standardWindowMonitorIDs.isEmpty)
    }

    #if targetEnvironment(macCatalyst)
    func testClosingOneMonitorPersistsTheOthersAndDisconnectPreservesRestoration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        let computer = Computer(endpoint: try Endpoint(address: "window.fixture.invalid"))
        XCTAssertTrue(library.save(computer))
        let windows = MacMonitorWindows()
        let connection = UUID()
        let first = MonitorWindowID(connection: connection, display: 2)
        let second = MonitorWindowID(connection: connection, display: 3)
        windows.set(.init(session: VNCSession(configuration: computer.configuration), computer: computer, library: library,
                          primary: 1, children: [2, 3], observing: false), for: connection)
        windows.focus(second, active: true)
        windows.focus(first, active: false)
        XCTAssertEqual(windows.groups[connection]?.focusedChild, 3)
        windows.setObserving(true, for: connection)
        XCTAssertEqual(windows.groups[connection]?.observing, true)
        windows.closed(first)
        XCTAssertEqual(windows.groups[connection]?.children, [3])
        XCTAssertEqual(windows.remove(connection), [3])
        windows.closed(second)
        let stored = try XCTUnwrap(ConnectionLibrary(file: file).existingComputer(matching: computer))
        XCTAssertEqual(stored.display(for: .mac).windowedMonitors, [3])
        XCTAssertNil(stored.display(for: .iPad).windowedMonitors)
        library.rememberMonitor(.display(1), for: computer)
        XCTAssertNil(library.existingComputer(matching: computer)?.display(for: .mac).windowedMonitors)
    }
    #endif
}
