import SwiftUI
import XCTest
@testable import DeskLink

@MainActor
final class DesktopPreviewTests: XCTestCase {
    func testLibraryShowsTheSavedPreviewAndRemovesItWhenCleared() async throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appending(path: id)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let library = ConnectionLibrary(file: directory.appending(path: "library.json"))
        let board = UIPasteboard.withUniqueName()
        defer {
            defaults.removePersistentDomain(forName: id)
            UIPasteboard.remove(withName: board.name)
            try? FileManager.default.removeItem(at: directory)
        }
        var computer = Computer(name: "工作室电脑", endpoint: try Endpoint(address: "studio.example.invalid"))
        computer.savesDisconnectScreenshot = true
        XCTAssertTrue(library.save(computer))
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 96)
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let chart = renderer.image { output in
            UIColor(red: 0.95, green: 0.05, blue: 0.83, alpha: 1).setFill()
            output.fill(bounds)
            UIColor(red: 0.03, green: 0.72, blue: 0.26, alpha: 1).setFill()
            output.fill(CGRect(x: 80, y: 0, width: 80, height: 96))
        }
        library.saveDisconnectScreenshot(for: computer, frame: .image(try XCTUnwrap(chart.cgImage)), region: nil)
        let content = LibraryWindow(library: library, preferences: defaults, pasteboard: board)
            .environment(library).environment(AppLock(defaults: defaults))
            .environment(TailnetDirectory(defaults: defaults))
            .environment(LibrarySync(settings: directory.appending(path: "sync.json"), defaults: defaults))
            .defaultAppStorage(defaults)
        #if targetEnvironment(macCatalyst)
        let host = UIHostingController(rootView: content.environment(MacMonitorWindows())
            .environment(MacAvailability(defaults: defaults)))
        #else
        let host = UIHostingController(rootView: content)
        #endif
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for visible in [true, false] {
            if !visible { try library.clearPreview(for: computer.id) }
            let deadline = ContinuousClock.now + .seconds(6)
            repeat {
                try await Task.sleep(for: .milliseconds(120))
                host.view.layoutIfNeeded()
                let shot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                if try containsChart(shot) == visible {
                    let attachment = XCTAttachment(image: shot)
                    attachment.name = visible ? "library-with-preview" : "library-after-clear"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    break
                }
                if ContinuousClock.now >= deadline { XCTFail("Unexpected preview visibility: " + String(visible)); return }
            } while true
        }
    }

    func testFailedDeletionKeepsThePreviewAndPreventsRebindingTheSavedConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let file = directory.appending(path: "library.json")
        let previews = file.deletingPathExtension().appendingPathExtension("previews")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: previews.path)
            try? FileManager.default.removeItem(at: directory)
        }
        var computer = Computer(name: "Preview Fixture", endpoint: try Endpoint(address: "old.fixture.invalid"))
        computer.savesDisconnectScreenshot = true
        XCTAssertTrue(ConnectionLibrary(file: file).save(computer))
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let image = previews.appending(path: computer.id.uuidString).appendingPathExtension("png")
        try Data([0x42]).write(to: image)
        let library = ConnectionLibrary(file: file)
        let original = try XCTUnwrap(library.previews[computer.id])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: previews.path)
        XCTAssertThrowsError(try library.clearPreview(for: computer.id))
        XCTAssertEqual(library.previews[computer.id], original)
        XCTAssertEqual(try Data(contentsOf: image), Data([0x42]))
        var replacement = computer
        replacement.endpoint = try Endpoint(address: "new.fixture.invalid")
        XCTAssertFalse(library.save(replacement))
        XCTAssertEqual(library.archive.computers.first?.endpoint, computer.endpoint)
        XCTAssertEqual(ConnectionLibrary(file: file).archive.computers.first?.endpoint, computer.endpoint)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: previews.path)
        try library.clearPreview(for: computer.id)
        try library.clearPreview(for: computer.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        let reopened = ConnectionLibrary(file: file)
        XCTAssertNil(reopened.previews[computer.id])
        XCTAssertEqual(reopened.archive.computers.first?.savesDisconnectScreenshot, true)
        XCTAssertTrue(reopened.save(replacement))
        XCTAssertEqual(ConnectionLibrary(file: file).archive.computers.first?.endpoint, replacement.endpoint)
    }

    private func containsChart(_ shot: UIImage) throws -> Bool {
        let image = try XCTUnwrap(shot.cgImage)
        let width = 480, height = max(1, 480 * image.height / image.width)
        let rowBytes = width * 4
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: rowBytes, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var magenta = 0, green = 0
        for i in Swift.stride(from: 0, to: rowBytes * height, by: 4) {
            if pixels[i] > 200 && pixels[i + 1] < 45 && pixels[i + 2] > 165 { magenta += 1 }
            if pixels[i] < 40 && pixels[i + 1] > 155 && pixels[i + 2] < 100 { green += 1 }
        }
        return magenta > 20 && green > 20
    }
}
