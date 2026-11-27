#if targetEnvironment(macCatalyst)
import Foundation

@MainActor
final class MacLibraryStartup: NSObject {
    static let preference = "mac.hideLibraryAtLaunch"
    private static let windowUpdated = Notification.Name("NSWindowDidUpdateNotification")

    private enum State {
        case waitingForLibrary, waitingForWindow, hidden, finished
    }

    private var state: State

    init(defaults: UserDefaults) {
        state = defaults.bool(forKey: Self.preference) ? .waitingForLibrary : .finished
        super.init()
        if state == .waitingForLibrary {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidUpdate),
                                                   name: Self.windowUpdated, object: nil)
        }
    }

    func libraryAppeared(openingRequestedContent: Bool) {
        if openingRequestedContent {
            openRequestedContent()
        } else if state == .waitingForLibrary {
            state = .waitingForWindow
        }
    }

    func openRequestedContent() {
        if state == .hidden, let app = Self.application, app.value(forKey: "hidden") as? Bool == true {
            app.perform(NSSelectorFromString("unhide:"), with: nil)
        }
        finish(with: .finished)
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard state == .waitingForWindow, let window = notification.object as? NSObject,
              Self.isVisibleMainWindow(window), let app = Self.application,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return }
        guard windows.filter({ Self.isVisibleMainWindow($0) }).count == 1 else {
            finish(with: .finished)
            return
        }

        // Keep the scene alive so macOS can still deliver a URL or file open.
        finish(with: .hidden)
        app.perform(NSSelectorFromString("hide:"), with: nil)
    }

    private func finish(with state: State) {
        NotificationCenter.default.removeObserver(self, name: Self.windowUpdated, object: nil)
        self.state = state
    }

    private static var application: NSObject? {
        // These AppKit APIs are public on Mac, but AppKit cannot be imported by Catalyst.
        (NSClassFromString("NSApplication") as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
    }

    private static func isVisibleMainWindow(_ window: NSObject) -> Bool {
        window.value(forKey: "visible") as? Bool == true &&
            window.value(forKey: "canBecomeMainWindow") as? Bool == true
    }
}
#endif
