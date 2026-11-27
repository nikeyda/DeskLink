import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class AppLock {
    private let defaults: UserDefaults
    private let authenticate: @MainActor (LAContext, LAPolicy) async throws -> Bool
    private var context: LAContext?
    private var attemptedAutomaticUnlock = false
    private(set) var enabled: Bool
    private(set) var passwordProtection: Bool
    private(set) var locked: Bool
    private(set) var authenticating = false
    var error: String?

    init(defaults: UserDefaults = .standard, authenticate: @escaping @MainActor (LAContext, LAPolicy) async throws -> Bool = { context, policy in
        if policy == .deviceOwnerAuthenticationWithBiometrics {
            guard context.canEvaluatePolicy(policy, error: nil) else { return false }
            context.localizedFallbackTitle = ""
        }
        return try await context.evaluatePolicy(policy, localizedReason: "身份验证")
    }) {
        self.defaults = defaults
        self.authenticate = authenticate
        let initiallyEnabled = defaults.bool(forKey: "privacy.deviceAuthentication")
        enabled = initiallyEnabled
        #if targetEnvironment(macCatalyst)
        passwordProtection = defaults.bool(forKey: "privacy.passwordAuthentication")
        #else
        passwordProtection = defaults.object(forKey: "privacy.passwordAuthentication") as? Bool ?? true
        #endif
        locked = initiallyEnabled
    }

    func setEnabled(_ value: Bool) async {
        guard enabled != value, await verify() else { return }
        defaults.set(value, forKey: "privacy.deviceAuthentication")
        enabled = value
        locked = false
    }

    func lock() {
        context?.invalidate()
        context = nil
        authenticating = false
        attemptedAutomaticUnlock = false
        if enabled { locked = true }
    }

    func setPasswordProtection(_ value: Bool) async {
        guard passwordProtection != value, await verify() else { return }
        defaults.set(value, forKey: "privacy.passwordAuthentication")
        passwordProtection = value
    }

    func approvePasswordSend() async -> Bool {
        guard !locked else { return false }
        if passwordProtection { return await verify() }
        return true
    }

    func unlock() async {
        guard locked, await verify() else { return }
        locked = false
    }

    func unlockAutomatically() async {
        guard locked, !authenticating, !attemptedAutomaticUnlock else { return }
        attemptedAutomaticUnlock = true
        guard await verify(using: .deviceOwnerAuthenticationWithBiometrics) else { return }
        locked = false
    }

    private func verify(using policy: LAPolicy = .deviceOwnerAuthentication) async -> Bool {
        guard !authenticating else { return false }
        let attempt = LAContext()
        context = attempt
        authenticating = true
        error = nil
        defer {
            if context === attempt { context = nil; authenticating = false }
            attempt.invalidate()
        }
        do {
            let success = try await authenticate(attempt, policy)
            return context === attempt && success
        } catch {
            guard context === attempt, policy == .deviceOwnerAuthentication else { return false }
            let code = (error as? LAError)?.code
            if code != .userCancel && code != .appCancel && code != .systemCancel { self.error = error.localizedDescription }
            return false
        }
    }
}
