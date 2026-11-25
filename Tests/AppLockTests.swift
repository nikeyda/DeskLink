import XCTest
@testable import DeskLink

@MainActor
final class AppLockTests: XCTestCase {
    func testPasswordSendHasIndependentDeviceAuthentication() async throws {
        let domain = "DeskLinkPasswordPrivacy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let gate = AppLock(defaults: defaults) { _ in true }
        await gate.setPasswordProtection(true)
        XCTAssertTrue(gate.passwordProtection)
        XCTAssertFalse(gate.enabled)
        let denied = AppLock(defaults: defaults) { _ in false }
        let approved = await denied.approvePasswordSend()
        XCTAssertFalse(approved)
        await denied.setPasswordProtection(false)
        XCTAssertTrue(denied.passwordProtection)
        await gate.setEnabled(true)
        gate.lock()
        let locked = await gate.approvePasswordSend()
        XCTAssertFalse(locked)
    }

    func testLockNeedsSuccessfulDeviceAuthenticationAndSurvivesRelaunch() async throws {
        let domain = "DeskLinkPrivacyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let denied = AppLock(defaults: defaults) { _ in false }
        await denied.setEnabled(true)
        XCTAssertFalse(denied.enabled)
        let gate = AppLock(defaults: defaults) { _ in true }
        await gate.setEnabled(true)
        XCTAssertTrue(gate.enabled)
        XCTAssertFalse(gate.locked)
        gate.lock()
        XCTAssertTrue(gate.locked)
        let reopened = AppLock(defaults: defaults) { _ in false }
        XCTAssertTrue(reopened.locked)
        await reopened.unlock()
        XCTAssertTrue(reopened.locked)
        await reopened.setEnabled(false)
        XCTAssertTrue(reopened.enabled)
        await gate.unlock()
        XCTAssertFalse(gate.locked)
        await gate.setEnabled(false)
        XCTAssertFalse(gate.enabled)
        XCTAssertFalse(AppLock(defaults: defaults).locked)
    }
}
