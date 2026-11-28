#if targetEnvironment(macCatalyst)
import XCTest
@testable import DeskLink

@MainActor
final class MacVNCLinkHandlerTests: XCTestCase {
    typealias Application = MacVNCLinkHandler.Application

    func testInstalledApplicationIdentityIsSeparateFromTheDisplayName() {
        let app = MacVNCLinkHandler.Application(at: Bundle.main.bundleURL)
        XCTAssertTrue(app.isTelescope)
        XCTAssertFalse(app.name.isEmpty)

        let unregisteredCopy = MacVNCLinkHandler.Application(at: URL(filePath: "/Telescope.app"))
        XCTAssertEqual(unregisteredCopy.name, "Telescope")
        XCTAssertFalse(unregisteredCopy.isTelescope)
    }

    func testUnregisteredSchemeHasNoHandler() {
        let scheme = "telescope-test-" + UUID().uuidString.lowercased()
        let url = URL(string: scheme + "://localhost")!
        XCTAssertNil(MacVNCLinkHandler.application(for: url))
    }

    func testPreviousApplicationIsRestorableAfterRelaunchAndMove() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try await model.makeDefault()
        XCTAssertTrue(model.application?.isTelescope == true)
        XCTAssertEqual(model.previousApplication?.bundleIdentifier, fixture.original.bundleIdentifier)

        let moved = try fixture.application(name: "Moved Viewer", identifier: fixture.originalID)
        fixture.workspace.available[fixture.originalID] = moved
        let reopened = fixture.model()
        XCTAssertEqual(reopened.previousApplication?.url, moved.url)
        try await reopened.restorePrevious()
        XCTAssertEqual(reopened.application?.bundleIdentifier, fixture.originalID)
        XCTAssertEqual(fixture.workspace.writes, [Bundle.main.bundleURL, moved.url])
        XCTAssertNil(reopened.previousApplication)
    }

    func testUnverifiedChangesKeepTheCurrentHandlerAndTheRestoreChoice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        fixture.workspace.appliesChanges = false
        do {
            try await model.makeDefault()
            XCTFail("A callback without a changed default must not succeed.")
        } catch { }
        XCTAssertEqual(model.application?.bundleIdentifier, fixture.originalID)
        XCTAssertNil(model.previousApplication)

        fixture.workspace.appliesChanges = true
        try await model.makeDefault()
        fixture.workspace.appliesChanges = false
        do {
            try await model.restorePrevious()
            XCTFail("The previous app must remain available after a failed restore.")
        } catch { }
        XCTAssertTrue(model.application?.isTelescope == true)
        XCTAssertEqual(model.previousApplication?.bundleIdentifier, fixture.originalID)
    }

    func testRestoreRespectsAnExternalChangeAndAnUninstalledPreviousApp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model()
        try await model.makeDefault()
        fixture.workspace.current = fixture.original
        do {
            try await model.restorePrevious()
            XCTFail("Restoring must respect changes made outside the settings window.")
        } catch { }
        XCTAssertEqual(model.application?.bundleIdentifier, fixture.originalID)
        XCTAssertNil(model.previousApplication)
        XCTAssertEqual(fixture.workspace.writes.count, 1)

        try await model.makeDefault()
        fixture.workspace.available[fixture.originalID] = nil
        model.refresh()
        XCTAssertNil(model.previousApplication)
        do {
            try await model.restorePrevious()
            XCTFail("An uninstalled previous app must not be selected.")
        } catch { }
        XCTAssertEqual(fixture.workspace.writes.count, 2)
        XCTAssertTrue(model.application?.isTelescope == true)
    }

    func testBuiltInScreenSharingIsAvailableWhenNoPreviousAppCanBeRestored() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let screenSharing = try fixture.application(name: "Screen Sharing", identifier: "com.apple.ScreenSharing")
        fixture.workspace.available["com.apple.ScreenSharing"] = screenSharing
        let model = fixture.model()
        try await model.makeDefault()
        fixture.workspace.available[fixture.originalID] = nil
        model.refresh()
        XCTAssertEqual(model.previousApplication?.url, screenSharing.url)
        try await model.restorePrevious()
        XCTAssertEqual(model.application?.url, screenSharing.url)
    }

    @MainActor private final class Workspace {
        var current: Application
        var available: [String: Application]
        var appliesChanges = true
        private(set) var writes = [URL]()

        init(original: Application, identifier: String) {
            current = original
            available = [identifier: original, "local.nikey.desklink": Application(at: Bundle.main.bundleURL)]
        }

        func select(_ url: URL) {
            writes.append(url)
            if appliesChanges, let selected = available.values.first(where: { $0.url == url }) { current = selected }
        }
    }

    @MainActor private struct Fixture {
        let directory: URL
        let domain: String
        let preferences: UserDefaults
        let originalID = "invalid.fixture.viewer"
        let original: Application
        let workspace: Workspace

        init() throws {
            domain = "Telescope-link-" + UUID().uuidString
            directory = URL.temporaryDirectory.appending(path: domain)
            preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
            original = try Self.makeApplication(in: directory, name: "Previous Viewer", identifier: originalID)
            workspace = Workspace(original: original, identifier: originalID)
        }

        func application(name: String, identifier: String) throws -> Application {
            try Self.makeApplication(in: directory, name: name, identifier: identifier)
        }

        func model() -> MacVNCLinkPreferencesModel {
            MacVNCLinkPreferencesModel(preferences: preferences, telescope: Application(at: Bundle.main.bundleURL),
                                       readDefault: { workspace.current },
                                       findApplication: { workspace.available[$0] },
                                       writeDefault: { workspace.select($0) })
        }

        func cleanUp() {
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }

        private static func makeApplication(in directory: URL, name: String, identifier: String) throws -> Application {
            let bundle = directory.appending(path: name + ".app")
            let contents = bundle.appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleName": name, "CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
            return Application(at: bundle)
        }
    }
}
#endif
