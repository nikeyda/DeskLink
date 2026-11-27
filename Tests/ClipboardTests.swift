import UIKit
import XCTest
import Observation
import RFBProtocol
@testable import DeskLink
@testable import RFBTransport
@testable import rootshellVNC

@MainActor final class ClipboardTests: XCTestCase {
    private final class PermissionClipboard: VNCClipboardProviding {
        var changeCount = 0
        var allowsAutomaticRead = true
        let remoteWrites = VNCClipboardRemoteWrites()
        var offeredType = ClipboardType.utf8PlainText
        var permittedContent: ClipboardContent?
        var writtenContent: ClipboardContent?
        var reads = 0

        func hasTransferableContent(for support: ClipboardContentSupport) -> Bool {
            support.accepts(offeredType)
        }

        func readContent(for support: ClipboardContentSupport) -> ClipboardContent? {
            reads += 1
            return permittedContent
        }

        func write(_ content: ClipboardContent) {
            writtenContent = content
            changeCount += 1
        }
    }

    func testGeneralPasteboardRequiresManualSendOnMobile() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertFalse(VNCSystemClipboard().allowsAutomaticRead)
        #else
        XCTAssertTrue(VNCSystemClipboard().allowsAutomaticRead)
        #endif
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        XCTAssertTrue(VNCSystemClipboard(pasteboard: board).allowsAutomaticRead)
    }

    func testManualReceiveReportsRichContentOnlyAfterWritingIt() {
        let board = PermissionClipboard()
        var results: [VNCManualClipboardResult] = []
        let controller = VNCClipboardSynchronizer(clipboard: board, canSend: { true },
            send: { _ in }, canRequestRemoteClipboard: { true },
            observesApplicationLifecycle: false, automaticallyMonitors: false)
        defer { controller.invalidate() }
        controller.onManualTransferResult = { result in
            if result == .received { XCTAssertNotNil(board.writtenContent) }
            results.append(result)
        }

        let rich = ClipboardContent(items: [[.init(type: ClipboardType.png, data: Data([1, 2, 3]))]])
        controller.getClipboard()
        controller.handleClipboardEvent(.requestStarted(11, changeNotice: false))
        controller.handleClipboardEvent(.reply(11, rich))
        XCTAssertEqual(board.writtenContent, rich)
        XCTAssertEqual(results, [.received])

        controller.getClipboard()
        controller.handleClipboardEvent(.requestStarted(12, changeNotice: false))
        controller.handleClipboardEvent(.reply(12, nil))
        XCTAssertEqual(results, [.received, .receiveFailed])

        controller.getClipboard()
        controller.handleClipboardEvent(.manualRequestFailed)
        XCTAssertEqual(results, [.received, .receiveFailed, .receiveFailed])
    }

    func testManualReceiveRefreshesSendAvailabilityWhenSharingIsOff() async {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let controller = VNCClipboardSynchronizer(clipboard: VNCSystemClipboard(pasteboard: board), canSend: { true },
            send: { _ in }, observesApplicationLifecycle: false, automaticallyMonitors: false)
        defer { controller.invalidate() }
        let availabilityChanged = expectation(description: "Send action refreshes after a manual receive")
        withObservationTracking {
            XCTAssertFalse(controller.canSendClipboard)
        } onChange: {
            availabilityChanged.fulfill()
        }
        controller.receiveRemoteClipboardText("manual clipboard fixture")
        XCTAssertFalse(controller.canSendClipboard)
        controller.getClipboard()
        await fulfillment(of: [availabilityChanged], timeout: 2)
        XCTAssertTrue(controller.canSendClipboard)
        XCTAssertFalse(controller.sharedClipboardEnabled)
    }

    func testExpiredManualReceiveCannotWriteItsLateAppleReply() async throws {
        let board = PermissionClipboard()
        let controller = VNCClipboardSynchronizer(clipboard: board, canSend: { true },
            send: { _ in }, manualReceiveTimeout: .milliseconds(30), canRequestRemoteClipboard: { true },
            observesApplicationLifecycle: false, automaticallyMonitors: false)
        defer { controller.invalidate() }
        let expired = expectation(description: "Manual receive times out")
        controller.onManualTransferResult = { result in
            XCTAssertEqual(result, .receiveFailed)
            expired.fulfill()
        }
        controller.getClipboard()
        controller.handleClipboardEvent(.requestStarted(23, changeNotice: false))
        await fulfillment(of: [expired], timeout: 2)
        controller.handleClipboardEvent(.reply(23, .text("late fixture")))
        XCTAssertNil(board.writtenContent)
    }

    func testManualOnlyPasteboardDoesNotReadAfterDenialOrForegrounding() {
        let board = PermissionClipboard()
        board.allowsAutomaticRead = false
        var support = ClipboardContentSupport.plainText
        var sent: [ClipboardContent] = []
        let controller = VNCClipboardSynchronizer(clipboard: board, canSend: { true },
            send: { sent.append($0) }, contentSupport: { support },
            observesApplicationLifecycle: false, automaticallyMonitors: true)
        defer { controller.invalidate() }
        controller.sharedClipboardEnabled = true

        board.changeCount += 1
        controller.sendClipboard() // Simulate a denied paste permission request.
        XCTAssertEqual(board.reads, 1)
        board.changeCount += 1
        controller.localClipboardDidChange()
        controller.applicationWillResignActive()
        board.changeCount += 1
        controller.applicationDidBecomeActive()
        support = .all
        controller.clipboardCapabilitiesDidChange()
        XCTAssertEqual(board.reads, 1)
        XCTAssertTrue(sent.isEmpty)

        controller.receiveRemoteClipboardContent(.text("remote copy"))
        XCTAssertEqual(board.writtenContent, .text("remote copy"))
        board.permittedContent = .text("manual copy")
        controller.sendClipboard()
        XCTAssertEqual(board.reads, 2)
        XCTAssertEqual(sent, [.text("manual copy")])
    }

    func testDeclinedAutomaticReadIsNotRepeatedWhenServerAddsFormats() {
        let board = PermissionClipboard()
        var support = ClipboardContentSupport.plainText
        var sent: [ClipboardContent] = []
        let controller = VNCClipboardSynchronizer(clipboard: board, canSend: { true },
            send: { sent.append($0) }, contentSupport: { support },
            observesApplicationLifecycle: false, automaticallyMonitors: false)
        defer { controller.invalidate() }
        controller.sharedClipboardEnabled = true
        board.changeCount += 1
        controller.localClipboardDidChange()
        XCTAssertEqual(board.reads, 1)
        support = .all
        controller.clipboardCapabilitiesDidChange()
        controller.localClipboardDidChange()
        XCTAssertEqual(board.reads, 1)
        XCTAssertTrue(sent.isEmpty)

        board.permittedContent = .text("manual retry")
        controller.sendClipboard()
        XCTAssertEqual(sent, [.text("manual retry")])
        board.changeCount += 1
        board.permittedContent = .text("next copy")
        controller.localClipboardDidChange()
        XCTAssertEqual(sent.last, .text("next copy"))
        XCTAssertNil(board.writtenContent)
    }

    func testRichOnlyCopyIsReadWhenServerCanReceiveIt() {
        let board = PermissionClipboard()
        board.offeredType = ClipboardType.png
        let image = ClipboardContent(items: [[.init(type: ClipboardType.png, data: Data([1, 2, 3]))]])
        board.permittedContent = image
        var support = ClipboardContentSupport.plainText
        var sent: [ClipboardContent] = []
        let controller = VNCClipboardSynchronizer(clipboard: board, canSend: { true },
            send: { sent.append($0) }, contentSupport: { support },
            observesApplicationLifecycle: false, automaticallyMonitors: false)
        defer { controller.invalidate() }
        controller.sharedClipboardEnabled = true
        board.changeCount += 1
        controller.localClipboardDidChange()
        XCTAssertEqual(board.reads, 0)
        support = .all
        controller.clipboardCapabilitiesDidChange()
        XCTAssertEqual(board.reads, 1)
        XCTAssertEqual(sent, [image])
    }

    func testAppleClipboardKeepsURLRichTextAndImageRepresentations() throws {
        let name = UIPasteboard.Name("local.nikey.desklink.tests." + UUID().uuidString)
        let board = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let bridge = VNCSystemClipboard(pasteboard: board)
        let address = try XCTUnwrap(URL(string: "https://example.invalid/desk?tab=2"))
        let rich = Data(#"{\rtf1\ansi\b DeskLink}"#.utf8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2)).pngData { renderer in
            UIColor.systemBlue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        }
        board.items = [[ClipboardType.url: address], [ClipboardType.rtf: rich], [ClipboardType.png: image]]
        let outbound = try XCTUnwrap(bridge.readContent(for: .all))
        XCTAssertEqual(outbound.plainText, address.absoluteString)
        let scrap = AppleClipboardProtocol.pack(outbound)
        let received = try AppleClipboardProtocol.unpack(scrap)
        XCTAssertEqual(received.items.count, 3)
        board.items = []
        bridge.write(received)
        XCTAssertEqual(board.url, address)
        XCTAssertEqual(board.data(forPasteboardType: ClipboardType.rtf, inItemSet: IndexSet(integer: 1))?.first, rich)
        XCTAssertEqual(board.data(forPasteboardType: ClipboardType.png, inItemSet: IndexSet(integer: 2))?.first, image)
        let fallback = try XCTUnwrap(bridge.readContent(for: .plainText))
        XCTAssertEqual(fallback, .text(address.absoluteString))
    }

    func testSingleItemKeepsURLBoldTextAndPNGAfterWireCompression() throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let url = try XCTUnwrap(URL(string: "https://example.invalid/grouped-item"))
        let styled = NSAttributedString(string: "Grouped", attributes: [.font: UIFont.boldSystemFont(ofSize: 14)])
        let rich = try styled.data(from: NSRange(location: 0, length: styled.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "clipboard-pixels", withExtension: "plist")
            ?? Bundle(for: Self.self).url(forResource: "clipboard-pixels", withExtension: "plist", subdirectory: "Fixtures"))
        let images = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: file))
        let png = try XCTUnwrap(images["mac"])
        board.setItems([[ClipboardType.url: url, ClipboardType.rtf: rich, ClipboardType.png: png]], options: [.localOnly: true])
        let bridge = VNCSystemClipboard(pasteboard: board)
        let content = try XCTUnwrap(bridge.readContent(for: .all))
        let packet = try AppleClipboardProtocol.packedMessage(content)
        let size = try XCTUnwrap(AppleClipboardProtocol.uint32BE(packet, at: 8))
        let compressed = packet.dropFirst(AppleClipboardProtocol.packedScrapHeaderSize)
        XCTAssertEqual(AppleClipboardProtocol.uint32BE(packet, at: 12), UInt32(compressed.count))
        let decoded = try AppleClipboardProtocol.unpackContent(compressed: Data(compressed), uncompressedSize: Int(size))
        board.items = []
        bridge.write(decoded)
        XCTAssertEqual(board.numberOfItems, 1)
        XCTAssertEqual(board.url, url)
        let received = try XCTUnwrap(board.data(forPasteboardType: ClipboardType.rtf))
        let text = try NSAttributedString(data: received, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(text.string, "Grouped")
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(board.data(forPasteboardType: ClipboardType.png), png)
    }

    func testAppleScreenSharingURLPropertyListPastesAsANativeURL() throws {
        let expected = try XCTUnwrap(URL(string: "https://example.invalid/mac/clipboard"))
        let binary = try PropertyListSerialization.data(fromPropertyList: [expected.absoluteString, ""], format: .binary, options: 0)
        let content = ClipboardContent(items: [[.init(type: ClipboardType.url, data: binary)]])
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let received = try AppleClipboardProtocol.unpack(AppleClipboardProtocol.pack(content))
        VNCSystemClipboard(pasteboard: board).write(received)
        XCTAssertEqual(board.url, expected)
        let provider = try XCTUnwrap(board.itemProviders.first)
        XCTAssertTrue(provider.canLoadObject(ofClass: NSURL.self))
    }

    func testOnlyTheActiveWindowSendsAutomaticChanges() throws {
        let name = UIPasteboard.Name("local.nikey.desklink.tests." + UUID().uuidString)
        let board = try XCTUnwrap(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let bridge = VNCSystemClipboard(pasteboard: board)
        var left: [String] = [], right: [String] = []
        func controller(_ send: @escaping (VNCClipboardContent) -> Void) -> VNCClipboardSynchronizer {
            VNCClipboardSynchronizer(clipboard: bridge, canSend: { true }, send: send,
                                     observesApplicationLifecycle: false, automaticallyMonitors: false)
        }
        let first = controller { if let value = $0.plainText { left.append(value) } }
        let second = controller { if let value = $0.plainText { right.append(value) } }
        defer { first.invalidate(); second.invalidate() }
        first.sharedClipboardEnabled = true
        second.sharedClipboardEnabled = true
        second.setHostWindowActive(false)
        board.string = "first window"
        first.localClipboardDidChange()
        second.localClipboardDidChange()
        first.setHostWindowActive(false)
        second.setHostWindowActive(true)
        first.localClipboardDidChange()
        second.localClipboardDidChange()
        board.string = "second window"
        first.localClipboardDidChange()
        second.localClipboardDidChange()
        XCTAssertEqual(left, ["first window"])
        XCTAssertEqual(right, ["second window"])
    }

    func testUIKitWindowFocusRoutesBothClipboardDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.keyWindow
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let bridge = VNCSystemClipboard(pasteboard: board)
        var sent = [0: [String](), 1: [String]()]
        var focused: [Int: Bool] = [:]
        var windows: [UIWindow] = []
        var controllers: [VNCClipboardSynchronizer] = []
        defer {
            controllers.forEach { $0.invalidate() }
            windows.forEach { $0.isHidden = true }
            original?.makeKey()
        }
        for index in 0..<2 {
            let controller = VNCClipboardSynchronizer(clipboard: bridge, canSend: { true }, send: { content in
                if let value = content.plainText { sent[index, default: []].append(value) }
            }, observesApplicationLifecycle: false, automaticallyMonitors: false)
            controller.setHostWindowActive(false)
            controller.sharedClipboardEnabled = true
            controllers.append(controller)
            let window = UIWindow(windowScene: scene)
            let root = UIViewController()
            window.rootViewController = root
            let tracker = SessionWindowFocus.Tracker(frame: .zero)
            tracker.changed = { active in
                focused[index] = active
                controller.setHostWindowActive(active)
            }
            root.view.addSubview(tracker)
            windows.append(window)
        }
        for (turn, active) in [0, 1, 0].enumerated() {
            let other = 1 - active
            windows[active].makeKeyAndVisible()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(3)
            while (focused[active] != true || focused[other] == true) && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(windows[active].isKeyWindow)
            XCTAssertEqual(focused[active], true)
            XCTAssertNotEqual(focused[other], true)
            board.string = "local-\(turn)"
            controllers.forEach { $0.localClipboardDidChange() }
            controllers[active].receiveRemoteClipboardText("active-\(turn)")
            controllers[other].receiveRemoteClipboardText("background-\(turn)")
            XCTAssertEqual(board.string, "active-\(turn)")
        }
        XCTAssertEqual(sent[0], ["local-0", "local-2"])
        XCTAssertEqual(sent[1], ["local-1"])
    }

    func testViewerPasswordIsSeparateFromTheOSAccountPassword() {
        let plain = VNCCredentials(host: "fixture.invalid", password: "viewer", username: "fixture")
        XCTAssertNil(plain.userPassword(for: .vncAuthentication))
        XCTAssertNil(plain.userPassword(for: .vencrypt))
        XCTAssertNil(plain.userPassword(for: nil))
        let authenticated = VNCCredentials(host: "fixture.invalid", password: "account", username: "fixture", tunnelUserPassword: "tunnel")
        XCTAssertEqual(authenticated.userPassword(for: .macAuthentication), "account")
        XCTAssertEqual(authenticated.userPassword(for: .vncAuthentication), "tunnel")
    }
}
