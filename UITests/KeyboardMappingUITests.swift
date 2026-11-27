#if !targetEnvironment(macCatalyst)
import UIKit
import XCTest

@MainActor
final class KeyboardMappingUITests: XCTestCase {
    func testTheConnectionShowsIndependentKeyboardMappingControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["library.quick"].firstMatch.waitForExistence(timeout: 8))
        app.open(try XCTUnwrap(URL(string: "vnc://keyboard-mapping.fixture.invalid")))

        let form = app.collectionViews["connection.form"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 8))
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 {
                if element.exists, element.isHittable,
                   form.frame.insetBy(dx: 0, dy: 18).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                    return
                }
                let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.78))
                let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.38))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("Could not reveal \(element.identifier).")
        }

        let display = app.buttons["显示器"].firstMatch
        reveal(display)
        display.tap()
        let hardware = app.buttons["connection.hardwareKeyboard"].firstMatch
        reveal(hardware)
        hardware.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        let option = app.buttons["旧版键盘映射"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()

        let software = app.buttons["connection.softwareKeyboard"].firstMatch
        reveal(software)

        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Independent keyboard mappings in connection settings"
        evidence.lifetime = .keepAlways
        add(evidence)

        func displays(_ selection: String, on picker: XCUIElement) -> Bool {
            picker.label.contains(selection)
                || (picker.value as? String) == selection
                || app.staticTexts[selection].firstMatch.isHittable
        }
        XCTAssertTrue(displays("旧版键盘映射", on: hardware), hardware.debugDescription)
        XCTAssertTrue(displays("发送本地字符", on: software), software.debugDescription)
    }
}
#endif
