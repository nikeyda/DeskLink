import SwiftUI
import CoreImage
import ImageIO
import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor
final class DisconnectWindowTests: XCTestCase {
    func testClosingWindowSendsSavedActionBeforeClosingSocket() async throws {
        for (action, point) in [(VNCDisconnectAction.topLeft, CGPoint.zero), (.topRight, CGPoint(x: 159, y: 0)),
                                (.bottomLeft, CGPoint(x: 0, y: 95)), (.bottomRight, CGPoint(x: 159, y: 95))] {
            try await closeWindow(action: action, expectedPoint: point)
        }
        try await closeWindow(action: .controlAltDelete, expectedKeys: [0xffe3, 0xffe9, 0xffff])
        try await closeWindow(action: .lockScreen, apple: true, expectedKeys: [0xffe3, 0xffeb, 0x71])
        try await closeWindow(action: .logOutUser, apple: true, expectedKeys: [0xffe1, 0xffeb, 0x71])
        try await closeWindow(action: nil)
    }

    func testRemovingObservationAndBackgroundViewsSendsNoDisconnectCommand() async throws {
        try await closeWindow(action: .controlAltDelete, observing: true)
        try await closeWindow(action: .bottomRight, phase: .background)
    }

    func testForegroundDisconnectSavesTheRemoteImageAndBackgroundCloseSkipsIt() async throws {
        try await closeWindow(action: .topLeft, expectedPoint: .zero, saveScreenshot: true)
        try await closeWindow(action: nil, observing: true, saveScreenshot: true)
        try await closeWindow(action: nil, phase: .background, saveScreenshot: true)
    }

    private func closeWindow(action: VNCDisconnectAction?, apple: Bool = false, observing: Bool = false,
                             phase: ScenePhase = .active, expectedPoint: CGPoint? = nil,
                             expectedKeys: [Int] = [], saveScreenshot: Bool = false) async throws {
        let peerHost = ProcessInfo.processInfo.environment["DESKLINK_DISCONNECT_HOST"] ?? "127.0.0.1"
        let authority = peerHost.contains(":") ? "[\(peerHost)]" : peerHost
        guard let peerPort = ProcessInfo.processInfo.environment["DESKLINK_DISCONNECT_PEER"].flatMap(UInt16.init),
              let baseURL = URL(string: "http://\(authority):\(peerPort)") else {
            throw XCTSkip("Run script/disconnect_peer.py and pass its port as DESKLINK_DISCONNECT_PEER.")
        }
        var create = URLRequest(url: baseURL.appending(path: apple ? "apple" : "standard"))
        create.httpMethod = "POST"
        let (created, _) = try await URLSession.shared.data(for: create)
        let peer = try JSONDecoder().decode(Peer.self, from: created)
        let status = baseURL.appending(path: peer.id.uuidString.lowercased())
        let run = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: run))
        let directory = FileManager.default.temporaryDirectory.appending(path: run, directoryHint: .isDirectory)
        let library = ConnectionLibrary(file: directory.appending(path: "library.json"))
        let pasteboard = UIPasteboard.withUniqueName()
        defer {
            UIPasteboard.remove(withName: pasteboard.name)
            defaults.removePersistentDomain(forName: run)
            try? FileManager.default.removeItem(at: directory)
        }
        var computer = Computer(endpoint: try Endpoint(address: "\(authority):\(peer.port)"))
        computer.disconnectAction = action
        computer.savesDisconnectScreenshot = saveScreenshot ? true : nil
        computer.viewOnly = observing
        computer.automaticallySharesClipboard = false
        XCTAssertTrue(library.save(computer))
        let request = SessionRequest(computer: computer, password: "", rememberPassword: false)
        let session = SessionScreen(request: request, library: library, preferences: defaults, pasteboard: pasteboard) { _ in }
            .environment(AppLock(defaults: defaults))
            .environment(\.scenePhase, phase)
            .defaultAppStorage(defaults)
        #if targetEnvironment(macCatalyst)
        let content = AnyView(session.environment(MacMonitorWindows()))
        #else
        let content = AnyView(session)
        #endif
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let initial = try await receipt(from: status) { $0.frames > 0 }
        if saveScreenshot && phase != .background {
            // The peer records its send before UIKit presents the decoded frame.
            let deadline = ContinuousClock.now + .seconds(5)
            while library.archive.computers.first?.lastConnected == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertNotNil(library.archive.computers.first?.lastConnected)
            try await Task.sleep(for: .milliseconds(150))
        }
        // Removing the connected SwiftUI view is the window-close path. It has
        // to deliver any configured command while its transport is still alive.
        host.rootView = AnyView(EmptyView())
        let final = try await receipt(from: status) { $0.closed }
        let keys = Array(final.keys.dropFirst(initial.keys.count))
        let points = Array(final.pointers.dropFirst(initial.pointers.count))
        XCTAssertEqual(keys, expectedKeys + expectedKeys.reversed().map { -$0 })
        XCTAssertEqual(points, expectedPoint.map { [[0, Int($0.x), Int($0.y)]] } ?? [])
        let saved = saveScreenshot && phase != .background
        if saved {
            let deadline = ContinuousClock.now + .seconds(4)
            while library.previews[computer.id] == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            let preview = try XCTUnwrap(library.previews[computer.id])
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(preview.url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 160)
            XCTAssertEqual(image.height, 96)
            let context = CIContext()
            let expected = [[31, 89, 165], [241, 183, 69], [52, 174, 146], [223, 102, 88]]
            for (index, color) in expected.enumerated() {
                let point = CGRect(x: index % 2 == 0 ? 20 : 120, y: index < 2 ? 75 : 20, width: 1, height: 1)
                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 4,
                               bounds: point, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                XCTAssertEqual(pixel.prefix(3).map(Int.init), color)
            }
            let reopened = ConnectionLibrary(file: directory.appending(path: "library.json"))
            XCTAssertEqual(reopened.previews[computer.id]?.url, preview.url)
            if observing { reopened.clearPreview(for: computer.id) }
            else { computer.savesDisconnectScreenshot = false; XCTAssertTrue(reopened.save(computer)) }
            XCTAssertNil(reopened.previews[computer.id])
            XCTAssertFalse(FileManager.default.fileExists(atPath: preview.url.path))
        } else {
            XCTAssertNil(library.previews[computer.id])
        }
        let receipt = XCTAttachment(string: "frames=\(final.frames) closed=\(final.closed) keys=\(keys) pointers=\(points)")
        receipt.name = "\(action?.rawValue ?? "none")-\(observing ? "observe" : "control")-\(phase)"
        receipt.lifetime = .keepAlways
        add(receipt)
    }

    private struct Peer: Decodable { let id: UUID; let port: UInt16 }
    private struct Receipt: Decodable {
        let frames: Int
        let closed: Bool
        let keys: [Int]
        let pointers: [[Int]]
        let error: String?
    }

    private func receipt(from url: URL, until condition: (Receipt) -> Bool) async throws -> Receipt {
        let stop = ContinuousClock.now + .seconds(8)
        repeat {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try JSONDecoder().decode(Receipt.self, from: data)
            if let error = result.error {
                throw NSError(domain: "DisconnectWindowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            if condition(result) { return result }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < stop
        throw URLError(.timedOut)
    }
}
