import AVFAudio
import Speech
import XCTest
import rootshellVNC
@testable import DeskLink

@MainActor
final class DictationTests: XCTestCase {
    #if os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
    func testLiveMicrophoneRecognizesSpokenFixtureOnDevice() async throws {
        guard let value = ProcessInfo.processInfo.environment["DESKLINK_ACOUSTIC_RUN"],
              let run = UUID(uuidString: value) else { throw XCTSkip("Requires an attended microphone test.") }
        guard #available(iOS 26, *) else { throw XCTSkip("On-device dictation requires iOS 26.") }
        let module = try await LocalDictation.module(for: Locale(identifier: "en_US"))
        let status = await AssetInventory.status(forModules: [module])
        try XCTSkipUnless(status == .installed, "The English dictation resource must already be installed.")
        let preferred = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let format = try XCTUnwrap(preferred)
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard permitted else { return XCTFail("The microphone permission was declined.") }
        let marker = URL.cachesDirectory.appending(path: "DictationTest-" + run.uuidString + ".json")
        let recording = DictationRecording()
        defer {
            recording.discard()
            XCTAssertFalse(FileManager.default.fileExists(atPath: recording.file.path))
            try? FileManager.default.removeItem(at: marker)
        }
        try recording.start(format: format, maximumDuration: 8)
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portType.rawValue }
        let clock = ContinuousClock()
        let stop = clock.now + .seconds(8)
        try JSONEncoder().encode(Date.now.timeIntervalSince1970).write(to: marker, options: .atomic)
        try await clock.sleep(until: stop)
        recording.stop()
        let audio = try AVAudioFile(forReading: recording.file)
        guard audio.length > 0 else {
            return XCTFail("The recorder delivered zero audio frames. Input port types: " + inputs.joined(separator: ", "))
        }
        let peak = try peakAmplitude(in: audio)
        let input = "Recorded \(audio.length) frames at \(audio.fileFormat.sampleRate) Hz via " + inputs.joined(separator: ", ")
        guard peak > 0 else { return XCTFail(input + ". Every recorded sample was zero.") }
        let level = String(format: "%.1f dBFS", 20 * log10(peak))
        XCTContext.runActivity(named: input + ". Peak: " + level) { _ in }
        let text = try await LocalDictation.recognize(recording.file, using: module)
        let words = text.lowercased().split { !$0.isLetter }
        XCTAssertTrue(words == ["the", "remote", "desktop", "is", "ready"], "The recognized words did not match the fixture.")
    }

    func testRevokedMicrophoneAndInterruptedRecordingCleanupOnDevice() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let audio = environment["DESKLINK_FINISHED_AUDIO_ID"].flatMap(UUID.init(uuidString:)),
              let run = environment["DESKLINK_FINISHED_ACOUSTIC_RUN"].flatMap(UUID.init(uuidString:))
        else { throw XCTSkip("Requires a finished attended test.") }
        let marker = URL.cachesDirectory.appending(path: "DictationTest-" + run.uuidString + ".json")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        let file = FileManager.default.temporaryDirectory.appending(path: "DeskLink-dictation-" + audio.uuidString + ".caf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(AVAudioApplication.shared.recordPermission, .denied)
    }
    #endif

    private func peakAmplitude(in audio: AVAudioFile) throws -> Float {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096))
        var peak: Float = 0
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(buffer.format.channelCount) {
                for sample in UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)) {
                    peak = max(peak, abs(sample))
                }
            }
        }
        return peak
    }

    func testRecordingLevelDistinguishesSilentFramesFromSpeech() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let silent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: silent) }
        do {
            let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            samples.frameLength = samples.frameCapacity
            let channels = try XCTUnwrap(samples.floatChannelData)
            channels[0].update(repeating: 0, count: Int(samples.frameLength))
            try AVAudioFile(forWriting: silent, settings: format.settings).write(from: samples)
        }
        let silentFile = try AVAudioFile(forReading: silent)
        XCTAssertEqual(silentFile.length, 4096)
        XCTAssertEqual(try peakAmplitude(in: silentFile), 0)

        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "dictation-en", withExtension: "caf") ??
                                    bundle.url(forResource: "dictation-en", withExtension: "caf", subdirectory: "Fixtures"))
        let peak = try peakAmplitude(in: AVAudioFile(forReading: fixture))
        XCTAssertEqual(20 * log10(peak), -3.0, accuracy: 0.1)
    }

    func testInterruptedRecordingCleanupPreservesOtherFiles() throws {
        guard #available(iOS 26, macCatalyst 26, *) else { throw XCTSkip("Requires OS 26.") }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let target = directory.appending(path: "DeskLink-dictation-" + UUID().uuidString + ".caf")
        let untouched = directory.appending(path: "DeskLink-dictation-not-a-recording.caf")
        try Data().write(to: target)
        try Data().write(to: untouched)
        DictationRecording.removeInterruptedRecordings(in: directory)
        XCTAssertFalse(manager.fileExists(atPath: target.path))
        XCTAssertTrue(manager.fileExists(atPath: untouched.path))
    }

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

    func testEmptyAudioReturnsSilenceBeforeStartingRecognition() async throws {
        guard #available(iOS 26, macCatalyst 26, *) else { throw XCTSkip("Requires OS 26.") }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        _ = try AVAudioFile(forWriting: file, settings: format.settings)
        let module = try await LocalDictation.module(for: Locale(identifier: "en_US"))
        do {
            _ = try await LocalDictation.recognize(file, using: module)
            XCTFail("An empty file unexpectedly returned a transcription.")
        } catch LocalDictation.Problem.silence {}
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
