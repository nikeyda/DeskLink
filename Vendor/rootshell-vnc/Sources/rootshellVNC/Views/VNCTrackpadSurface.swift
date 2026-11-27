#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// A second touch surface for the same remote cursor and gesture state.
public struct VNCTrackpadSurface: UIViewRepresentable {
    let controls: VNCDesktopControls
    let holdDuration: TimeInterval

    public init(controls: VNCDesktopControls, holdDuration: TimeInterval) {
        self.controls = controls
        self.holdDuration = holdDuration
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let motion = coordinator.motion
        view.addGestureRecognizer(motion)

        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        view.addGestureRecognizer(scroll)

        for count in 1...2 {
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
            tap.numberOfTouchesRequired = count
            tap.require(toFail: motion)
            view.addGestureRecognizer(tap)
        }
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.motion.holdDuration = holdDuration
    }

    public func makeCoordinator() -> Coordinator { Coordinator(controls: controls) }

    public static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        view.gestureRecognizers?.forEach { $0.isEnabled = false }
    }

    @MainActor public final class Coordinator: NSObject {
        private let controls: VNCDesktopControls
        lazy var motion = DirectTouchGestureRecognizer(target: self, action: #selector(move(_:)))

        init(controls: VNCDesktopControls) {
            self.controls = controls
        }

        @objc private func move(_ recognizer: DirectTouchGestureRecognizer) {
            controls.inputSurface?.handleSeparateTrackpadMotion(recognizer)
        }

        @objc fileprivate func scroll(_ recognizer: UIPanGestureRecognizer) {
            controls.inputSurface?.handleSeparateTrackpadScroll(recognizer)
        }

        @objc fileprivate func tap(_ recognizer: UITapGestureRecognizer) {
            controls.clickTrackpad(recognizer.numberOfTouchesRequired == 1 ? .left : .right)
        }
    }
}
#endif
