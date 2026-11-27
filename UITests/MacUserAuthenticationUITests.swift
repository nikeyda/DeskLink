#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class MacUserAuthenticationUITests: XCTestCase {
    func testQuickConnectionRequiresAMacUsernameWhenExplicitlySelected() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].firstMatch.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://mac-account.fixture.invalid")))

        let picker = app.buttons["connection.authentication"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let option = app.buttons["Mac 用户"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()

        let submit = app.buttons["connection.submit"].firstMatch
        XCTAssertFalse(submit.isEnabled)
        let username = app.textFields["connection.username"].firstMatch
        XCTAssertTrue(username.exists)
        XCTAssertTrue(app.secureTextFields["connection.password"].firstMatch.exists)
        username.tap()
        username.typeText("fixture-mac")
        XCTAssertTrue(submit.isEnabled)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Mac user authentication on iPad"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
