import AVFAudio
import Speech
import SwiftUI
import rootshellVNC

struct RemoteDictationPresentation: ViewModifier {
    let session: VNCSession
    @Binding var presented: Bool
    let canControl: @MainActor () -> Bool
    @Environment(\.scenePhase) private var phase

    private var available: Bool { session.isReadyForDesktopInput && canControl() && phase != .background }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presented) {
                if #available(iOS 26, macCatalyst 26, *) {
                    DictationSheet(canSend: { available }) { text in
                        guard available else { return }
                        KeyboardInputHandler(sendKeyEvent: { session.sendKeyEvent(downFlag: $0, key: $1) }).typeText(text)
                    }
                }
            }
            .onChange(of: available) { if !available { presented = false } }
    }
}

@available(iOS 26, macCatalyst 26, *)
struct DictationSheet: View {
    let canSend: () -> Bool
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var action = Action.prepare
    @State private var phase = Phase.preparing
    @State private var recorder = DictationRecording()
    @State private var module: DictationTranscriber?

    private enum Action { case prepare, install, finish }
    private enum Phase: Equatable { case preparing, needsDownload, recording, recognizing, failed(String) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch phase {
                case .preparing: ProgressView("正在准备本机听写…")
                case .recognizing: ProgressView("正在识别…")
                case .needsDownload:
                    Text("首次使用此语言需要下载 Apple 的本机语音资源。")
                    Button("下载语音资源") { action = .install }.buttonStyle(.borderedProminent)
                case .recording:
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.red).accessibilityHidden(true)
                    Text("正在听写…").font(.headline)
                    Text("说完后点右上角的勾，文字将输入到远程电脑。").foregroundStyle(.secondary)
                case .failed(let message):
                    Text(verbatim: message)
                }
            }
            .multilineTextAlignment(.center).padding()
            .navigationTitle("听写").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { recorder.discard(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { action = .finish } label: { Label("输入到远程电脑", systemImage: "checkmark") }
                        .disabled(phase != .recording).accessibilityIdentifier("dictation.send")
                }
            }
        }
        .presentationDetents([.medium])
        .task(id: action) { await perform() }
        .onDisappear { recorder.discard() }
    }

    private func perform() async {
        do {
            switch action {
            case .prepare, .install:
                phase = .preparing
                let module = try await LocalDictation.module(for: Locale.current)
                self.module = module
                let status = await AssetInventory.status(forModules: [module])
                try Task.checkCancellation()
                if status == .unsupported { throw LocalDictation.Problem.language }
                if status != .installed {
                    guard action == .install else { phase = .needsDownload; return }
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await request.downloadAndInstall()
                    }
                }
                try Task.checkCancellation()
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw LocalDictation.Problem.language
                }
                guard await AVAudioApplication.requestRecordPermission() else { throw LocalDictation.Problem.microphone }
                try Task.checkCancellation()
                guard canSend() else { dismiss(); return }
                try recorder.start(format: format)
                phase = .recording
            case .finish:
                guard phase == .recording, let module else { return }
                phase = .recognizing
                recorder.stop()
                defer { recorder.discard() }
                let text = try await LocalDictation.recognize(recorder.file, using: module)
                try Task.checkCancellation()
                if canSend() { send(text) }
                dismiss()
            }
        } catch is CancellationError {
        } catch {
            recorder.discard()
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }
}
