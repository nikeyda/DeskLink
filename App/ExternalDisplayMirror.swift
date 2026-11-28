#if !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import rootshellVNC

@available(iOS 27, *)
struct ExternalDisplayMirror: UIViewControllerRepresentable {
    let session: VNCSession
    let privacy: AppLock
    let enabled: Bool
    let availabilityChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> MirrorController {
        MirrorController(content: MirrorContent(session: session, privacy: privacy))
    }

    func updateUIViewController(_ controller: MirrorController, context: Context) {
        controller.availabilityChanged = availabilityChanged
        controller.updateOutputRequest(enabled)
    }

    static func dismantleUIViewController(_ controller: MirrorController, coordinator: ()) {
        controller.availabilityChanged = nil
        if let registration = controller.registration { controller.unregisterSceneAccessory(registration) }
        controller.registration = nil
    }

    @MainActor final class MirrorContent: NSObject {
        weak var session: VNCSession?
        let privacy: AppLock
        init(session: VNCSession, privacy: AppLock) { self.session = session; self.privacy = privacy }
    }

    final class MirrorController: UIViewController {
        let content: MirrorContent
        var registration: UISceneAccessoryRegistration?
        var availabilityChanged: ((Bool) -> Void)?
        private var outputRequested = false
        private var lastAvailable: Bool?

        init(content: MirrorContent) { self.content = content; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            // On iPhone, AirPlay mirrors the device using the system controls.
            guard UIDevice.current.userInterfaceIdiom == .pad else { return }
            let configuration = UISceneConfiguration()
            configuration.delegateClass = DeskLinkExternalScene.self
            registration = registerSceneAccessory(.externalNonInteractive(sceneConfiguration: configuration, userInfo: content))
            registration?.isEnabled = false
        }

        func updateOutputRequest(_ enabled: Bool) {
            outputRequested = enabled
            loadViewIfNeeded()
            updateOutput()
        }

        override func updateProperties() {
            super.updateProperties()
            updateOutput()
        }

        private func updateOutput() {
            let available = registration?.isAvailable == true && view.window?.windowScene?.screen == UIScreen.main
            let enabled = available && outputRequested
            if let registration, registration.isEnabled != enabled {
                registration.isEnabled = enabled
            }
            guard available != lastAvailable else { return }
            lastAvailable = available
            Task { @MainActor [weak self] in
                guard let self, lastAvailable == available else { return }
                availabilityChanged?(available)
            }
        }
    }
}

@available(iOS 27, *)
final class DeskLinkExternalScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard session.role == .windowExternalDisplayNonInteractive, let external = scene as? UIWindowScene,
              let content = options.sceneAccessoryUserInfo as? ExternalDisplayMirror.MirrorContent,
              let desktop = content.session else { return }
        let output = UIWindow(windowScene: external)
        output.isUserInteractionEnabled = false
        output.rootViewController = UIHostingController(rootView: MirroredDesktop(session: desktop, privacy: content.privacy))
        window = output
        output.isHidden = false
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

private struct MirroredDesktop: View {
    let session: VNCSession
    let privacy: AppLock

    var body: some View {
        ZStack {
            Color.black
            if !privacy.locked, session.connectionState.isConnected, session.hasPresentedCurrentPicture {
                ObservedPicture(session: session, showsPlaceholder: false)
            }
        }.ignoresSafeArea()
    }
}
#endif
