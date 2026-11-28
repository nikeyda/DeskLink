import AppKit
import SwiftUI

@main
struct TelescopeVNC: App {
    var body: some Scene {
        Window("VNC 链接默认应用", id: "vnc-settings") {
            if let telescope = telescopeApplication {
                VNCSettings(telescope: telescope)
            } else {
                ContentUnavailableView("找不到远程随航", systemImage: "link")
                    .frame(width: 360, height: 160)
            }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }

    private var telescopeApplication: MacVNCLinkHandler.Application? {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let application = MacVNCLinkHandler.Application(at: parent)
        return application.isTelescope ? application : nil
    }
}

private struct VNCSettings: View {
    @Environment(\.appearsActive) private var appearsActive
    @State private var model: MacVNCLinkPreferencesModel
    @State private var failed = false

    init(telescope: MacVNCLinkHandler.Application) {
        _model = State(initialValue: MacVNCLinkPreferencesModel(
            preferences: .standard,
            telescope: telescope,
            readDefault: { MacVNCLinkHandler.application() },
            findApplication: MacVNCLinkHandler.application(withBundleIdentifier:),
            writeDefault: { try await MacVNCLinkHandler.setDefault(applicationAt: $0) }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("当前默认应用") {
                if let application = model.application { Text(verbatim: application.name) }
                else { Text("未设置") }
            }
            Divider()
            HStack {
                Spacer()
                if model.isUpdating {
                    ProgressView().controlSize(.small)
                }
                if model.application?.isTelescope != true {
                    Button("设远程随航为默认应用") { Task { await change(restore: false) } }
                        .buttonStyle(.borderedProminent)
                } else if let previous = model.previousApplication {
                    Button("改用 \(previous.name)") { Task { await change(restore: true) } }
                }
            }
            .disabled(model.isUpdating)
        }
        .padding(24)
        .frame(minWidth: 380)
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { model.refresh() }
        }
        .alert("无法更改默认 VNC 应用", isPresented: $failed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("macOS 未确认更改 VNC 默认应用。")
        }
    }

    private func change(restore: Bool) async {
        do {
            if restore { try await model.restorePrevious() }
            else { try await model.makeDefault() }
        } catch {
            let systemError = error as NSError
            failed = !(systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
                && !(systemError.domain == NSOSStatusErrorDomain && systemError.code == -128)
        }
    }
}
