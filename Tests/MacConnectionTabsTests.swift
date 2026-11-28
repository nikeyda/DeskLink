#if targetEnvironment(macCatalyst)
import XCTest
import UIKit
@testable import DeskLink

final class MacConnectionTabsTests: XCTestCase {
    func testSystemTabPreferenceUsesTheRequestingWindowsDisplayMode() {
        let rule = MacConnectionTabs.system
        XCTAssertEqual(rule.collectionBehavior(systemPreference: .always, fullScreen: false), .preferred)
        XCTAssertEqual(rule.collectionBehavior(systemPreference: .manual, fullScreen: true), .disallowed)
        XCTAssertEqual(rule.collectionBehavior(systemPreference: .inFullScreen, fullScreen: false), .disallowed)
        XCTAssertEqual(rule.collectionBehavior(systemPreference: .inFullScreen, fullScreen: true), .preferred)
        XCTAssertEqual(rule.collectionBehavior(systemPreference: nil, fullScreen: false), .automatic)
    }

    func testSeparateWindowsOverrideTheSystemTabPreference() {
        for preferred in [MacApplication.TabPreference.always, .inFullScreen, .manual] {
            XCTAssertEqual(MacConnectionTabs.never.collectionBehavior(systemPreference: preferred, fullScreen: true), .disallowed)
        }
    }

    @MainActor
    func testFullScreenCommandOnlyUsesTheCapturedKeyWindow() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.keyWindow
        let detached = MacWindowSceneSource()
        XCTAssertFalse(detached.toggleFullScreen { _ in
            XCTFail("The detached source has no target.")
            return true
        })

        let windows = (0...1).map { _ in UIWindow(windowScene: scene) }
        let sources = (0...1).map { _ in MacWindowSceneSource() }
        defer {
            windows.forEach { $0.isHidden = true }
            original?.makeKey()
        }
        for (index, window) in windows.enumerated() {
            let root = UIViewController()
            window.rootViewController = root
            root.view.addSubview(MacWindowSceneCapture.CaptureView(source: sources[index], title: "Full Screen Fixture"))
            root.view.addSubview(SessionWindowFocus.Tracker(frame: .zero))
        }

        for active in [0, 1, 0] {
            windows[active].makeKeyAndVisible()
            let background = 1 - active
            let expected = scene.isFullScreen
            sources[active].refreshFullScreen()
            XCTAssertEqual(sources[active].isFullScreen, expected)
            XCTAssertFalse(sources[background].toggleFullScreen { _ in
                XCTFail("The background source must never act on the key window.")
                return true
            })
            var requested = false
            XCTAssertTrue(sources[active].toggleFullScreen { target in
                requested = true
                XCTAssertTrue(target === windows[active])
                return true
            })
            XCTAssertTrue(requested)
            XCTAssertEqual(sources[active].isFullScreen, expected, "Action delivery must not change native state.")
        }
    }
}
#endif
