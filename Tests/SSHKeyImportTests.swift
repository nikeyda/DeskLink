import CryptoKit
import Security
import SwiftUI
import XCTest
@testable import DeskLink

@MainActor
final class SSHKeyImportTests: XCTestCase {
    func testInvalidReplacementKeepsTheAcceptedKey() throws {
        let original = P256.Signing.PrivateKey().pemRepresentation
        var selected: String?
        let selection = Binding(get: { selected }, set: { selected = $0 })
        var draft = SSHKeyImportDraft()
        try draft.stage(original, filename: "original.pem", into: selection)

        XCTAssertThrowsError(try draft.stage("Invalid key contents", filename: nil, into: selection))
        XCTAssertNil(draft.protectedKey)
        XCTAssertEqual(selected, original)
    }

    func testProtectedReplacementCanBeRejectedCancelledAndRetried() throws {
        guard let encrypted = ProcessInfo.processInfo.environment["DESKLINK_SSH_IMPORT_PROTECTED"] else {
            throw XCTSkip("Provide a synthetic key encrypted with fixture-key-password.")
        }
        let original = P256.Signing.PrivateKey().pemRepresentation
        var selected: String? = original
        let selection = Binding(get: { selected }, set: { selected = $0 })
        var draft = SSHKeyImportDraft()
        try draft.stage(encrypted, filename: "private.pem", into: selection)
        let replacement = try XCTUnwrap(draft.protectedKey)
        XCTAssertEqual(replacement.filename, "private.pem")
        XCTAssertEqual(selected, original)

        XCTAssertThrowsError(try replacement.opened(with: "wrong-passphrase")) { error in
            XCTAssertEqual((error as NSError).code, Int(errSecAuthFailed))
        }
        XCTAssertEqual(selected, original)
        XCTAssertNotNil(draft.protectedKey)

        draft.discard()
        XCTAssertNil(draft.protectedKey)
        XCTAssertEqual(selected, original)
        let unlocked = try replacement.opened(with: "fixture-key-password")
        XCTAssertFalse(draft.accept(unlocked, into: selection))
        XCTAssertEqual(selected, original)

        try draft.stage(encrypted, filename: nil, into: selection)
        let retry = try XCTUnwrap(draft.protectedKey)
        XCTAssertNil(retry.filename)
        XCTAssertEqual(try retry.opened(with: "fixture-key-password"), unlocked)
        XCTAssertNotEqual(unlocked, original)
        XCTAssertTrue(draft.accept(unlocked, into: selection))
        XCTAssertNil(draft.protectedKey)
        XCTAssertEqual(selected, unlocked)
    }
}
