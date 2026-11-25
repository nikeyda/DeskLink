import AVFAudio
import Foundation
import Speech

@available(iOS 26, macCatalyst 26, *)
enum LocalDictation {
    enum Problem: LocalizedError {
        case language, microphone, capture, silence
        var errorDescription: String? {
            switch self {
            case .language: "当前设备无法使用所选语言进行听写。"
            case .microphone: "请在系统设置中允许「屏幕连线」使用麦克风。"
            case .capture: "无法开始录音，请检查麦克风后重试。"
            case .silence: "没有识别到文字，请重试。"
            }
        }
    }

    static func module(for locale: Locale) async throws -> DictationTranscriber {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { throw Problem.language }
        return DictationTranscriber(locale: supported, preset: .longDictation)
    }

    static func recognize(_ audio: URL, using module: DictationTranscriber) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            async let transcript: String = recognizedText(from: module)
            do {
                try Task.checkCancellation()
                try await analyzer.start(inputAudioFile: AVAudioFile(forReading: audio), finishAfterFile: true)
                let text = try await transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty else { throw Problem.silence }
                return text
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func recognizedText(from module: DictationTranscriber) async throws -> String {
        var text = ""
        var pending = ""
        for try await result in module.results {
            let words = String(result.text.characters)
            if result.isFinal {
                text += words
                pending = ""
            } else {
                // The file can end one audio sample beyond the last finalization time.
                pending = words
            }
        }
        return text + pending
    }
}

@available(iOS 26, macCatalyst 26, *)
@MainActor
final class DictationRecording {
    let file = FileManager.default.temporaryDirectory.appending(path: "DeskLink-dictation-" + UUID().uuidString + ".caf")
    private var recorder: AVAudioRecorder?
    #if !targetEnvironment(macCatalyst)
    private var previousAudioMode: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    #endif

    func start(format: AVAudioFormat) throws {
        do {
            #if !targetEnvironment(macCatalyst)
            let audio = AVAudioSession.sharedInstance()
            previousAudioMode = (audio.category, audio.mode, audio.categoryOptions)
            try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try audio.setActive(true)
            #endif
            let recorder = try AVAudioRecorder(url: file, settings: format.settings)
            self.recorder = recorder
            guard recorder.record() else { throw LocalDictation.Problem.capture }
        } catch {
            discard()
            throw error
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        #if !targetEnvironment(macCatalyst)
        if let previousAudioMode {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(previousAudioMode.0, mode: previousAudioMode.1, options: previousAudioMode.2)
            if previousAudioMode.0 == .ambient || previousAudioMode.0 == .soloAmbient {
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            }
            self.previousAudioMode = nil
        }
        #endif
    }

    func discard() { stop(); try? FileManager.default.removeItem(at: file) }
}
