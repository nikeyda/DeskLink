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
        let name = "Studio " + String(tag.prefix(8))
        let renamed = "Office " + String(tag.prefix(8))
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
                                                  "library.computer.", address)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        func removeFixture() {
            let cancel = app.buttons["取消"].firstMatch
            if host.exists, cancel.isHittable { cancel.tap() }
            if row.isHittable {
                row.press(forDuration: 0.8)
                app.buttons["删除"].firstMatch.tap()
                let confirmation = app.alerts["删除"]
                if confirmation.staticTexts[name].exists || confirmation.staticTexts[renamed].exists {
                    confirmation.buttons["删除"].tap()
                }
            }
            XCTAssertFalse(row.exists)
        }
        defer { if row.exists || host.exists { removeFixture() } }
        let definitions = IntentDefinitions(bundleIdentifier: "local.nikey.desklink")
        let computers = definitions.entities["ComputerEntity"]
        let entities = try await computers.entities(matching: name)
        XCTAssertEqual(entities.count, 1)
        let selected = try XCTUnwrap(entities.first)
        let initialSuggestions = try await computers.suggestedEntities()
        XCTAssertTrue(initialSuggestions.contains { $0.identifier == selected.identifier })
        row.press(forDuration: 0.8)
        app.buttons["编辑连接"].tap()
        nameField.tap()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(renamed)
        app.buttons["connection.submit"].tap()
        let renamedMatches = try await computers.entities(matching: renamed)
        let oldMatches = try await computers.entities(matching: name)
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(renamedMatches.count, 1)
        let renamedComputer = try XCTUnwrap(renamedMatches.first)
        XCTAssertEqual(renamedComputer.identifier, selected.identifier)
        let renamedSuggestions = try await computers.suggestedEntities()
        XCTAssertTrue(renamedSuggestions.contains { $0.identifier == renamedComputer.identifier })
        _ = try await definitions.intents["ConnectToComputer"].makeIntent(target: renamedComputer).run()
        XCTAssertTrue(host.waitForExistence(timeout: 12))
        XCTAssertEqual(host.value as? String, address)
        XCTAssertTrue(app.buttons["connection.submit"].isEnabled)
        removeFixture()
        let remaining = try await computers.suggestedEntities()
        XCTAssertFalse(remaining.contains { $0.identifier == selected.identifier })
    }
}
#endif
