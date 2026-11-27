#if targetEnvironment(macCatalyst)
import Foundation

@MainActor
enum MacApplication {
    private enum ActivationPolicy: Int {
        // NSApplicationActivationPolicy uses NSInteger.
        case regular = 0
        case accessory = 1
    }

    static var shared: NSObject? {
        // These AppKit APIs are public on Mac, but AppKit cannot be imported by Catalyst.
        (NSClassFromString("NSApplication") as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
    }

    static func setDockHidden(_ hidden: Bool) -> Bool {
        let selector = NSSelectorFromString("setActivationPolicy:")
        guard let app = shared, app.responds(to: selector), let method = app.method(for: selector) else { return false }
        let policy: ActivationPolicy = hidden ? .accessory : .regular
        typealias SetPolicy = @convention(c) (AnyObject, Selector, Int) -> Bool
        return unsafeBitCast(method, to: SetPolicy.self)(app, selector, policy.rawValue)
    }

    static var isDockHidden: Bool {
        shared?.value(forKey: "activationPolicy") as? Int == ActivationPolicy.accessory.rawValue
    }
}

@MainActor
final class MacDockPolicyObservation: NSObject {
    private let application: NSObject
    private let onChange: () -> Void

    init?(onChange: @escaping () -> Void) {
        guard let running = (NSClassFromString("NSRunningApplication") as? NSObject.Type)?
            .perform(NSSelectorFromString("currentApplication"))?.takeUnretainedValue() as? NSObject else { return nil }
        application = running
        self.onChange = onChange
        super.init()
        application.addObserver(self, forKeyPath: "activationPolicy", options: [.new], context: nil)
    }

    isolated deinit {
        application.removeObserver(self, forKeyPath: "activationPolicy")
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                          change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "activationPolicy" else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        Task { @MainActor [weak self] in self?.onChange() }
    }
}
#endif
