import Foundation
import XCTest
import rootshellVNC
@testable import DeskLink

final class PointerModeTests: XCTestCase {
    func testNewConnectionsInheritAndOlderConnectionsRetainTheirMode() throws {
        let suite = "TelescopePointerMode." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var computer = Computer(endpoint: try Endpoint(address: "pointer.fixture.invalid"))
        XCTAssertNil(computer.pointerModeOverride)
        XCTAssertEqual(computer.pointerMode(using: preferences), .direct)
        preferences.set("trackpad", forKey: SyncedPreference.pointerMode.rawValue)
        XCTAssertEqual(computer.pointerMode(using: preferences), .trackpad)

        let data = try LibraryArchive(computers: [computer]).encoded()
        XCTAssertNil(try LibraryArchive.read(data).computers.first?.pointerModeOverride)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try XCTUnwrap(envelope["computers"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["trackpad"] as? Bool, false)
        entries[0].removeValue(forKey: "inheritsPointerMode")
        for (trackpad, mode) in [(false, RemotePointerMode.direct), (true, .trackpad)] {
            entries[0]["trackpad"] = trackpad
            envelope["computers"] = entries
            let old = try LibraryArchive.read(JSONSerialization.data(withJSONObject: envelope))
            let restored = try XCTUnwrap(old.computers.first)
            XCTAssertEqual(restored.pointerModeOverride, mode)
            XCTAssertEqual(restored.pointerMode(using: preferences), mode)
        }

        computer.pointerModeOverride = .direct
        XCTAssertEqual(computer.pointerMode(using: preferences), .direct)
        computer.pointerModeOverride = nil
        XCTAssertEqual(computer.pointerMode(using: preferences), .trackpad)
        preferences.set("unknown", forKey: SyncedPreference.pointerMode.rawValue)
        XCTAssertEqual(computer.pointerMode(using: preferences), .direct)
    }
}
