#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import rootshellVNC
@testable import DeskLink

@available(iOS 27, *)
@MainActor
final class ExternalDisplayMirrorTests: XCTestCase {
    func testOnlyIPadRegistersSeparateOutputAndItStaysOffWithoutAnEligibleScene() throws {
        let domain = "TelescopeExternalDisplay." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = VNCSession(configuration: VNCConfiguration())
        let content = ExternalDisplayMirror.MirrorContent(session: session, privacy: AppLock(defaults: defaults))
        let controller = ExternalDisplayMirror.MirrorController(content: content)
        defer { ExternalDisplayMirror.dismantleUIViewController(controller, coordinator: ()) }

        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.registration != nil, UIDevice.current.userInterfaceIdiom == .pad)
        XCTAssertNil(controller.view.window)
        controller.updateOutputRequest(true)
        XCTAssertFalse(controller.registration?.isEnabled ?? false)
        controller.updateOutputRequest(false)
        XCTAssertFalse(controller.registration?.isEnabled ?? false)
    }
}
#endif
