#if DEBUG && !targetEnvironment(macCatalyst)
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import DeskLink

@MainActor final class AppleClipboardPeerTests: XCTestCase {
    func testPeerRequiresTheURLBoldMarkerAndImageFromOneItem() throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "clipboard-pixels", withExtension: "plist")
            ?? Bundle(for: Self.self).url(forResource: "clipboard-pixels", withExtension: "plist", subdirectory: "Fixtures"))
        let pixels = try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: file))
        let image = try XCTUnwrap(pixels["mac"])
        let run = UUID()
        try AppleClipboardPeer.publish(board, role: "mac", run: run, png: image)
        XCTAssertTrue(try XCTUnwrap(AppleClipboardPeer.match(board, role: "mac", run: run, png: image)).complete)
        XCTAssertNil(AppleClipboardPeer.match(board, role: "ipad", run: run, png: try XCTUnwrap(pixels["ipad"])))
        let rich = try XCTUnwrap(board.data(forPasteboardType: UTType.rtf.identifier))
        let url = try XCTUnwrap(board.url)
        board.setItems([[UTType.url.identifier: url, UTType.rtf.identifier: rich], [UTType.png.identifier: image]], options: [.localOnly: true])
        XCTAssertFalse(try XCTUnwrap(AppleClipboardPeer.match(board, role: "mac", run: run, png: image)).complete)
    }
}
#endif
