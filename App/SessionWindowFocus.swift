import SwiftUI
import UIKit

/// iPad can keep two connection scenes in the foreground at once. Only the
/// most recently keyed application window participates in clipboard sharing.
struct SessionWindowFocus: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> Tracker {
        let view = Tracker()
        view.changed = changed
        return view
    }

    func updateUIView(_ view: Tracker, context: Context) { view.changed = changed }

    final class Tracker: UIView {
        private static weak var front: UIWindow?
        var changed: ((Bool) -> Void)?
        private var previous: Bool?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: UIWindow.didResignKeyNotification, object: nil)
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if Self.front == nil, let window, window.isKeyWindow { Self.front = window }
            report()
        }

        @objc private func keyChanged(_ notification: Notification) {
            guard let changedWindow = notification.object as? UIWindow,
                  changedWindow.windowScene?.session.role == .windowApplication else { return }
            if notification.name == UIWindow.didBecomeKeyNotification { Self.front = changedWindow }
            else if Self.front === changedWindow { Self.front = nil }
            report()
        }

        private func report() {
            let active = window != nil && window?.isKeyWindow == true && Self.front === window
            guard active != previous else { return }
            previous = active
            Task { @MainActor [weak self] in
                guard let self, previous == active else { return }
                changed?(active)
            }
        }
    }
}
