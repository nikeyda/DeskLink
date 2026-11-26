#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class CloudDriveUITests: XCTestCase {
    func testExchangeWithMacThroughChosenICloudFolder() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let run = environment["DESKLINK_CLOUD_RUN"].flatMap(UUID.init(uuidString:)),
              let library = (environment["DESKLINK_CLOUD_CLIENT_LIBRARY"] ?? environment["DESKLINK_CLOUD_IPAD_LIBRARY"]).flatMap(UUID.init(uuidString:)),
              let computer = environment["DESKLINK_CLOUD_COMPUTER"].flatMap(UUID.init(uuidString:)),
              let phase = environment["DESKLINK_CLOUD_PHASE"], ["rename", "deletion"].contains(phase) else {
            throw XCTSkip("Requires the matching Mac and an explicitly selected iCloud test folder.")
        }
        let tag = String(run.uuidString.prefix(8))
        let folder = "Telescope-Test-" + tag
        let device = UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad"
        let renamed = device + " " + tag
        let witness = "Witness " + tag
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", library.uuidString]
        app.launch()
        let entry = app.buttons["library.computer." + computer.uuidString]
        let witnessEntry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "library.computer.", witness)).firstMatch

        func openSettings() throws {
            let more = app.buttons["library.more"]
            if !more.isHittable, app.staticTexts["所有连接"].firstMatch.isHittable {
                app.staticTexts["所有连接"].firstMatch.tap()
            }
            guard more.waitForExistence(timeout: 12) else { throw issue("The isolated library did not open.") }
            more.tap()
            app.buttons["设置"].firstMatch.tap()
        }
        func synchronize() throws {
            try openSettings()
            let refresh = app.buttons["立即同步"]
            if !refresh.exists {
                guard phase == "rename" else { throw issue("The selected sync folder was lost after relaunch.") }
                app.buttons["选择同步文件夹"].tap()
                try selectCloudFolder(folder, app: app)
            }
            let selected = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch
            guard refresh.waitForExistence(timeout: 10), selected.exists else { throw issue("The expected sync folder was not selected.") }
            let ready = NSPredicate(format: "enabled == true")
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: refresh)], timeout: 15) == .completed else {
                throw issue("The previous sync did not finish.")
            }
            refresh.tap()
            guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: refresh)], timeout: 30) == .completed else {
                throw issue("The manual sync did not finish.")
            }
            app.buttons["关闭"].firstMatch.tap()
        }

        if phase == "rename" {
            for _ in 0..<5 {
                try synchronize()
                if entry.waitForExistence(timeout: 12) { break }
            }
            XCTAssertTrue(entry.exists, "The Mac record did not reach the second device.")
            guard entry.exists else { return }
            if !entry.label.contains(renamed) {
                XCTAssertTrue(entry.label.contains("Mac " + tag))
                entry.press(forDuration: 0.8)
                app.buttons["编辑连接"].firstMatch.tap()
                let field = app.textFields["connection.name"]
                field.tap()
                field.typeKey("a", modifierFlags: .command)
                field.typeText(renamed)
                app.buttons["connection.submit"].tap()
                XCTAssertTrue(entry.waitForExistence(timeout: 5))
                XCTAssertTrue(entry.label.contains(renamed))
            }
            if !witnessEntry.exists {
                app.buttons["library.new"].tap()
                let field = app.textFields["connection.name"]
                field.tap()
                field.typeText(witness)
                let host = app.textFields["connection.host"]
                host.tap()
                host.typeText(device.lowercased() + "-" + tag.lowercased() + ".fixture.invalid")
                app.buttons["connection.submit"].tap()
            }
            XCTAssertTrue(witnessEntry.waitForExistence(timeout: 5))
            try synchronize()
        } else {
            for _ in 0..<5 {
                try synchronize()
                if !entry.exists { break }
                _ = entry.waitForNonExistence(timeout: 12)
            }
            XCTAssertFalse(entry.exists, "The Mac deletion did not reach the second device.")
            XCTAssertTrue(witnessEntry.exists, "The second record must survive the deletion.")
        }
    }

    private func selectCloudFolder(_ folder: String, app: XCUIApplication) throws {
        func named(_ labels: [String]) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
        }
        let grid = app.collectionViews["File View"].cells
        func item(_ name: String) -> XCUIElement {
            grid.containing(NSPredicate(format: "label == %@", name)).firstMatch
        }
        let locations = ["iCloud Drive", "iCloud 云盘", "iCloud雲碟", "iCloud 雲碟"]
        let location = app.cells.containing(NSPredicate(format: "label IN %@", locations)).firstMatch
        let sidebar = app.buttons["ToggleSideBar"]
        if !location.isHittable, sidebar.waitForExistence(timeout: 8), sidebar.isHittable { sidebar.tap() }
        let drive = location.isHittable ? location : named(locations)
        guard drive.waitForExistence(timeout: 25), drive.isHittable else {
            throw issue("The system picker did not expose its iCloud Drive location. Choose the dedicated test folder on the device.")
        }
        drive.tap()
        let target = item(folder)
        guard target.waitForExistence(timeout: 20) else { throw issue("iCloud Drive did not show the specified test folder.") }
        let icon = target.images.firstMatch
        if icon.exists { icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        else { target.tap() }

        // No parent or account root may be handed to the sync engine.
        let entered = app.navigationBars[folder].exists || (item("DeskLink").waitForExistence(timeout: 5) && !target.exists)
        guard entered || (target.exists && target.isSelected) else { throw issue("The picker did not enter or select the exact test folder.") }
        let choose = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开", "Choose", "选取", "選取"])).firstMatch
        guard choose.waitForExistence(timeout: 5), choose.isEnabled else { throw issue("The picker did not offer to open the selected folder.") }
        choose.tap()
    }

    private func issue(_ description: String) -> NSError {
        NSError(domain: "Telescope.CloudDriveTest", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#endif
