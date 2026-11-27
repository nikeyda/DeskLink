#if targetEnvironment(macCatalyst)
import XCTest
@testable import DeskLink

@MainActor
final class MacVNCLinkHandlerTests: XCTestCase {
    func testInstalledApplicationIdentityIsSeparateFromTheDisplayName() {
        let app = MacVNCLinkHandler.Application(at: Bundle.main.bundleURL)
        XCTAssertTrue(app.isTelescope)
        XCTAssertFalse(app.name.isEmpty)

        let unregisteredCopy = MacVNCLinkHandler.Application(at: URL(filePath: "/Telescope.app"))
        XCTAssertEqual(unregisteredCopy.name, "Telescope")
        XCTAssertFalse(unregisteredCopy.isTelescope)
    }

    func testRejectingAMissingApplicationLeavesTheDefaultUnchanged() async {
        let original = MacVNCLinkHandler.application()?.bundleIdentifier
        let scheme = "telescope-test-" + UUID().uuidString.lowercased()
        let url = URL(string: scheme + "://localhost")!
        let missing = URL.temporaryDirectory.appending(path: UUID().uuidString + ".app")
        XCTAssertNil(MacVNCLinkHandler.application(for: url))
        do {
            try await MacVNCLinkHandler.setDefault(applicationAt: missing, scheme: scheme)
            XCTFail("macOS unexpectedly accepted a missing application.")
        } catch {
            XCTAssertNotEqual((error as NSError).code, CocoaError.Code.featureUnsupported.rawValue)
        }
        XCTAssertNil(MacVNCLinkHandler.application(for: url))
        XCTAssertEqual(MacVNCLinkHandler.application()?.bundleIdentifier, original)
    }
}
#endif
