import LocalAuthentication
import XCTest
@testable import DeskLink

@MainActor
final class AppLockTests: XCTestCase {
    func testPasswordSendHasIndependentDeviceAuthentication() async throws {
        let domain = "DeskLinkPasswordPrivacy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let gate = AppLock(defaults: defaults) { _, _ in true }
        await gate.setPasswordProtection(true)
        XCTAssertTrue(gate.passwordProtection)
        XCTAssertFalse(gate.enabled)
        let denied = AppLock(defaults: defaults) { _, _ in false }
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
        let denied = AppLock(defaults: defaults) { _, _ in false }
        await denied.setEnabled(true)
        XCTAssertFalse(denied.enabled)
        let gate = AppLock(defaults: defaults) { _, _ in true }
        await gate.setEnabled(true)
        XCTAssertTrue(gate.enabled)
        XCTAssertFalse(gate.locked)
        gate.lock()
        XCTAssertTrue(gate.locked)
        let reopened = AppLock(defaults: defaults) { _, _ in false }
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

    func testAutomaticUnlockOffersBiometricsOnceAndLeavesManualAuthenticationAvailable() async throws {
        let domain = "DeskLinkAutomaticUnlock." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var policies: [LAPolicy] = []
        var cancelBiometrics = true
        let gate = AppLock(defaults: defaults) { _, policy in
            policies.append(policy)
            if policy == .deviceOwnerAuthenticationWithBiometrics && cancelBiometrics { throw LAError(.userCancel) }
            return true
        }

        await gate.unlockAutomatically()
        XCTAssertTrue(policies.isEmpty)
        await gate.setEnabled(true)
        XCTAssertEqual(policies, [.deviceOwnerAuthentication])
        gate.lock()
        await gate.unlockAutomatically()
        await gate.unlockAutomatically()
        XCTAssertEqual(policies, [.deviceOwnerAuthentication, .deviceOwnerAuthenticationWithBiometrics])
        XCTAssertTrue(gate.locked)
        XCTAssertFalse(gate.authenticating)
        XCTAssertNil(gate.error)

        await gate.unlock()
        XCTAssertEqual(policies.last, .deviceOwnerAuthentication)
        XCTAssertFalse(gate.locked)
        gate.lock()
        cancelBiometrics = false
        await gate.unlockAutomatically()
        XCTAssertEqual(policies.last, .deviceOwnerAuthenticationWithBiometrics)
        XCTAssertEqual(policies.count, 4)
        XCTAssertFalse(gate.locked)
    }

    func testBackgroundInvalidatesAnInFlightAutomaticUnlock() async throws {
        let domain = "DeskLinkInterruptedUnlock." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "privacy.deviceAuthentication")
        let (started, signal) = AsyncStream<Void>.makeStream()
        var reply: CheckedContinuation<Bool, Never>?
        var attempts = 0
        let gate = AppLock(defaults: defaults) { _, policy in
            XCTAssertEqual(policy, .deviceOwnerAuthenticationWithBiometrics)
            attempts += 1
            if attempts > 1 { return true }
            return await withCheckedContinuation {
                reply = $0
                signal.yield()
            }
        }

        let first = Task { await gate.unlockAutomatically() }
        var activity = started.makeAsyncIterator()
        await activity.next()
        await gate.unlockAutomatically()
        XCTAssertEqual(attempts, 1)
        gate.lock()
        try XCTUnwrap(reply).resume(returning: true)
        await first.value
        XCTAssertTrue(gate.locked)

        await gate.unlockAutomatically()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(gate.locked)
    }
}
