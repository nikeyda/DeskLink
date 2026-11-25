import UIKit
import XCTest
import RFBProtocol
@testable import RFBTransport
@testable import rootshellVNC

@MainActor final class ClipboardTests: XCTestCase {
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
