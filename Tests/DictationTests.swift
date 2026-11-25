import AVFAudio
import Speech
import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor
final class DictationTests: XCTestCase {
    func testConfirmedTextUsesUnicodeKeyEventsAndKeepsComposedCharacters() {
        var presses: [UInt32] = []
        var releases: [UInt32] = []
        let keyboard = KeyboardInputHandler { down, symbol in
            if down { presses.append(symbol) } else { releases.append(symbol) }
        }
        keyboard.typeText("e\u{301}好\r\n👩‍💻")
        XCTAssertEqual(presses, [0xe9, 0x0100597d, KeyboardInputHandler.keysymReturn, 0x0101f469, 0x0100200d, 0x0101f4bb])
        XCTAssertEqual(presses, releases)
    }

    func testOnDeviceDictationRecognizesTheSyntheticRemoteDesktopPhrase() async throws {
        guard #available(iOS 26, macCatalyst 26, *) else { throw XCTSkip("On-device dictation requires OS 26") }
        let module = try await LocalDictation.module(for: Locale(identifier: "en_US"))
        let status = await AssetInventory.status(forModules: [module])
        if status != .installed {
            let locales = await DictationTranscriber.installedLocales
            try XCTSkipUnless(status != .unsupported && locales.contains { $0.identifier(.bcp47) == "en-US" },
                              "The system English dictation asset is unavailable on this test device")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        let bundle = Bundle(for: Self.self)
        let file = try XCTUnwrap(bundle.url(forResource: "dictation-en", withExtension: "caf") ??
                                 bundle.url(forResource: "dictation-en", withExtension: "caf", subdirectory: "Fixtures"))
        let audio = try AVAudioFile(forReading: file)
        XCTAssertGreaterThan(audio.length, 16_000)
        let words = try await LocalDictation.recognize(file, using: module).lowercased().split { !$0.isLetter }
        XCTAssertEqual(words, ["the", "remote", "desktop", "is", "ready"])
    }
}
