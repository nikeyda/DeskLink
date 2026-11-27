#if targetEnvironment(macCatalyst)
import XCTest
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
}
#endif
