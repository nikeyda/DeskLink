import Network
import XCTest

#if !targetEnvironment(macCatalyst)
@MainActor
final class SupportDiagnosticsUITests: XCTestCase {
    func testFailedConnectionAppearsInDiagnosticsAndCanBeExported() async throws {
        continueAfterFailure = false
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "Telescope.test-diagnostics")
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(content: Data("RFB 002.000\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { ready.resume(returning: port.rawValue) }
                    else { ready.resume(throwing: URLError(.cannotCreateFile)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    ready.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let app = XCUIApplication()
        app.launchArguments = ["--test-library", UUID().uuidString]
        app.launch()
        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "vnc://127.0.0.1:\(port)")))
        let connect = app.buttons["connection.submit"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        XCTAssertTrue(app.buttons["session.editConnection"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        app.buttons["设置"].firstMatch.tap()
        let link = app.buttons["preferences.diagnostics"].firstMatch
        let form = app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable }) ?? app.collectionViews.firstMatch
        for _ in 0..<8 {
            if link.exists && link.isHittable { break }
            form.swipeUp()
        }
        XCTAssertTrue(link.isHittable)
        link.tap()
        let failure = app.descendants(matching: .any).matching(identifier: "diagnostics.failure").firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        let view = XCTAttachment(screenshot: app.screenshot())
        view.name = "Connection diagnostics"
        view.lifetime = .keepAlways
        add(view)

        app.buttons["diagnostics.export"].firstMatch.tap()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["存储", "储存", "保存", "Save"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 12), "The system file exporter must open.")
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "System diagnostics exporter"
        picker.lifetime = .keepAlways
        add(picker)

        let local = app.cells.containing(NSPredicate(format: "label IN %@", ["我的 iPad", "在我的 iPad 上", "On My iPad"])).firstMatch
        let sidebar = app.buttons["ToggleSideBar"].firstMatch
        if !local.isHittable, sidebar.isHittable { sidebar.tap() }
        if local.isHittable {
            local.tap()
            let folder = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                        "远程随航,", "Telescope,")).firstMatch
            if folder.isHittable { folder.tap() }
        }
        XCTAssertTrue(save.isEnabled, "The system exporter must have a writable folder.")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 12))
    }
}
#endif
