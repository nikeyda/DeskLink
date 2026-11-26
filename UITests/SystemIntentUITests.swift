#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AppIntentsTesting)
import AppIntentsTesting
import XCTest

@MainActor final class SystemIntentUITests: XCTestCase {
    func testConnectIntentFindsSavedComputerAndOpensItsConnectionForm() async throws {
        guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing requires iPadOS 27.") }
        #if !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKLINK_SYSTEM_INTENT_ON_DEVICE"] == "1",
                          "Run explicitly on the test iPad to create and remove a fixture in the system-visible library.")
        #endif
        let app = XCUIApplication()
        app.launch()
        let tag = UUID().uuidString
        let name = "Intent " + tag
        let address = "intent-" + tag.lowercased() + ".fixture.invalid"
        let create = app.buttons["library.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 12))
        create.tap()
        let nameField = app.textFields["connection.name"]
        nameField.tap()
        nameField.typeText(name)
        let host = app.textFields["connection.host"]
        host.tap()
        host.typeText(address)
        app.buttons["connection.submit"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                  "library.computer.", tag)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        defer {
            let cancel = app.buttons["取消"].firstMatch
            if host.exists, cancel.isHittable { cancel.tap() }
            if row.isHittable {
                row.press(forDuration: 0.8)
                app.buttons["删除"].firstMatch.tap()
                let confirmation = app.alerts["删除"]
                if confirmation.staticTexts[name].exists { confirmation.buttons["删除"].tap() }
            }
            XCTAssertFalse(row.exists)
        }
        let definitions = IntentDefinitions(bundleIdentifier: "local.nikey.desklink")
        let entities = try await definitions.entities["ComputerEntity"].entities(matching: name)
        XCTAssertEqual(entities.count, 1)
        let selected = try XCTUnwrap(entities.first)
        _ = try await definitions.intents["ConnectToComputer"].makeIntent(target: selected).run()
        XCTAssertTrue(host.waitForExistence(timeout: 12))
        XCTAssertEqual(host.value as? String, address)
        XCTAssertTrue(app.buttons["connection.submit"].isEnabled)
    }
}
#endif
