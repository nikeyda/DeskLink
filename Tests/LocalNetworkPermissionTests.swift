import Network
import NIOCore
import RFBProtocol
@testable import RFBTransport
import rootshellVNC
import XCTest
@testable import DeskLink

@MainActor
final class LocalNetworkPermissionTests: XCTestCase {
    func testOnlyTimeoutWithAnExplicitPermissionDenialGetsThePermissionError() {
        for timeout: any Error in [ChannelError.connectTimeout(.seconds(10)), NWError.posix(.ETIMEDOUT)] {
            XCTAssertEqual(TCPConnection.dialFailure(timeout, localNetworkAccessDenied: true), .localNetworkAccessDenied)
            guard case .ioError = TCPConnection.dialFailure(timeout, localNetworkAccessDenied: false) else {
                return XCTFail("An ordinary timeout must keep the existing transport error.")
            }
        }
        guard case .ioError = TCPConnection.dialFailure(NWError.posix(.ECONNREFUSED), localNetworkAccessDenied: true) else {
            return XCTFail("A refusal must remain actionable even after a prior permission wait.")
        }
    }

    func testPermissionFailureSurvivesSessionSetupAndOffersRetry() async {
        var configuration = VNCConfiguration()
        configuration.transportProvider = { _, _ in throw VNCProtocolError.localNetworkAccessDenied }
        let session = VNCSession(configuration: configuration)
        defer { session.disconnect() }
        do {
            try await session.connect(credentials: VNCCredentials(host: "permission.fixture.invalid", password: ""))
            XCTFail("The fixture must fail in setup.")
        } catch {
            XCTAssertEqual(session.lastError, .localNetworkAccessDenied)
            let failure = SessionConnectionFailure(session.lastError, setupRequiresEditing: false)
            XCTAssertEqual(failure, .localNetworkAccessDenied)
            XCTAssertFalse(failure.needsEditing)
            XCTAssertEqual(SupportDiagnostics.Failure.Reason(session.lastError), .transport)
        }
    }

    func testEnglishAndChinesePermissionCopyIsIncludedInTheApp() throws {
        let titleKey = "Local Network Access Is Off"
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(english.localizedString(forKey: titleKey, value: nil, table: "ConnectionPermission"), titleKey)
        let localized = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(localized.localizedString(forKey: titleKey, value: nil, table: "ConnectionPermission"), "本地网络访问未开启")
        let keys = [
            "In System Settings, go to Privacy & Security → Local Network, allow Telescope, then retry.",
            "In Settings, go to Privacy & Security → Local Network, allow Telescope, then retry."
        ]
        for key in keys {
            XCTAssertTrue(localized.localizedString(forKey: key, value: nil, table: "ConnectionPermission").contains("然后重试"))
        }
    }
}
