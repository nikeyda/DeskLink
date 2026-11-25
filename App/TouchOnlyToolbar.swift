#if !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Leave mouse and trackpad events to the remote screen underneath the carousel.
struct TouchOnlyToolbar<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let move: (CGSize?) -> Void

    init(move: @escaping (CGSize?) -> Void, @ViewBuilder content: () -> Content) {
        self.move = move
        self.content = content()
    }

    func makeUIViewController(context: Context) -> Host {
        Host(content: content, move: move)
    }

    func updateUIViewController(_ viewController: Host, context: Context) {
        viewController.hosted.rootView = content
        viewController.move = move
    }

    final class Host: UIViewController {
        let hosted: UIHostingController<Content>
        var move: (CGSize?) -> Void

        init(content: Content, move: @escaping (CGSize?) -> Void) {
            hosted = UIHostingController(rootView: content)
            self.move = move
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let surface = ToolbarSurface()
            view = surface
            addChild(hosted)
            hosted.safeAreaRegions = []
            hosted.view.backgroundColor = .clear
            hosted.view.frame = surface.bounds
            hosted.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            surface.addSubview(hosted.view)
            hosted.didMove(toParent: self)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                     NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            pan.maximumNumberOfTouches = 1
            surface.addGestureRecognizer(pan)
        }

        @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let translation = recognizer.translation(in: view.window)
                move(CGSize(width: translation.x, height: translation.y))
            case .ended, .cancelled, .failed: move(nil)
            default: break
            }
        }
    }
}

private final class ToolbarSurface: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let event {
            if event.type == .hover || event.type == .scroll || event.type == .transform { return false }
            if event.allTouches?.contains(where: { $0.type == .indirect || $0.type == .indirectPointer }) == true ||
                !event.buttonMask.isEmpty { return false }
        }
        return UIBezierPath(ovalIn: bounds).contains(point)
    }
}
#endif
