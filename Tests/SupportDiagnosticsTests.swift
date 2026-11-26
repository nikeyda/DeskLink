import XCTest
@testable import DeskLink

@MainActor
final class SupportDiagnosticsTests: XCTestCase {
    func testExportKeepsSessionMetricsAndOmitsIdentifyingConnectionData() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        var desktop = Computer(name: "Private Desk", endpoint: try Endpoint(address: "private-desk.invalid"))
        desktop.username = "private-account"
        XCTAssertTrue(library.save(desktop))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(12)
        let session = ConnectionReport(id: UUID(), startedAt: start, capturedAt: end,
                                       version: "RFB 3.8", encryption: "TLS", width: 1440, height: 900,
                                       usesVideo: false, encodings: ["ZRLE"], frames: 40, audioPackets: nil,
                                       receiveRate: 250, pointerEvents: 6, keyEvents: 2)
        library.keepReport(session, for: desktop)
        library.recordDiagnosticFailure(.init(date: end, reason: .init(.authenticationFailed("private-server-response")),
                                              usesSSH: true, requestsHighPerformance: false,
                                              version: "RFB 3.8", securityType: 19))

        let reopened = ConnectionLibrary(file: file)
        let report = reopened.supportDiagnostics(now: end)
        XCTAssertEqual(report.connections, [session])
        XCTAssertEqual(report.failures.map(\.reason), [.authentication])
        let data = try report.encoded()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(root["connections"] as? [[String: Any]])
        let failures = try XCTUnwrap(root["failures"] as? [[String: Any]])
        XCTAssertEqual(root["formatVersion"] as? Int, 1)
        XCTAssertEqual(root["exportedAt"] as? String, "2023-11-14T22:13:32Z")
        XCTAssertEqual(records.first?["frames"] as? Int, 40)
        XCTAssertEqual(failures.first?["securityType"] as? Int, 19)
        let json = String(decoding: data, as: UTF8.self)
        for value in [desktop.name, desktop.endpoint.address, desktop.username, "private-server-response", desktop.id.uuidString] {
            XCTAssertFalse(json.contains(value), "The report included private connection data.")
        }
    }

    func testFailureHistoryRetainsTheMostRecentEntriesAcrossLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        for offset in 0...SupportDiagnostics.recordLimit {
            library.recordDiagnosticFailure(.init(date: Date(timeIntervalSince1970: Double(offset)),
                                                  reason: .init(.timeout), usesSSH: false, requestsHighPerformance: true,
                                                  version: nil, securityType: nil))
        }
        let failures = ConnectionLibrary(file: file).supportDiagnostics().failures
        XCTAssertEqual(failures.count, SupportDiagnostics.recordLimit)
        XCTAssertEqual(failures.first?.date.timeIntervalSince1970, Double(SupportDiagnostics.recordLimit))
        XCTAssertEqual(failures.last?.date.timeIntervalSince1970, 1)
    }

    func testTheSpecificFailureReplacesTheGenericStateForTheSameAttempt() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ConnectionLibrary(file: directory.appending(path: "library.json"))
        let id = UUID()
        let generic = SupportDiagnostics.Failure(id: id, date: .now, reason: .unknown,
                                                 usesSSH: false, requestsHighPerformance: false,
                                                 version: nil, securityType: nil)
        let specific = SupportDiagnostics.Failure(id: id, date: .now, reason: .closed,
                                                  usesSSH: false, requestsHighPerformance: false,
                                                  version: "RFB 3.8", securityType: nil)
        library.recordDiagnosticFailure(generic)
        library.recordDiagnosticFailure(specific)
        library.recordDiagnosticFailure(generic)
        XCTAssertEqual(library.supportDiagnostics().failures, [specific])
    }
}
