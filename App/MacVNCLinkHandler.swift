#if targetEnvironment(macCatalyst)
import Foundation
import SwiftUI

@MainActor
enum MacVNCLinkHandler {
    struct Application {
        let name: String
        let bundleIdentifier: String?

        init(at url: URL) {
            let bundle = Bundle(url: url)
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            bundleIdentifier = bundle?.bundleIdentifier
        }

        var isTelescope: Bool { bundleIdentifier == "local.nikey.desklink" }
    }

    // AppKit cannot be imported in a Catalyst target. Both selectors are
    // public NSWorkspace APIs on every macOS release supported by this app.
    private static var workspace: NSObject? {
        (NSClassFromString("NSWorkspace") as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedWorkspace"))?.takeUnretainedValue() as? NSObject
    }

    static func application(for url: URL = URL(string: "vnc://localhost")!) -> Application? {
        let selector = NSSelectorFromString("URLForApplicationToOpenURL:")
        guard let workspace, workspace.responds(to: selector),
              let url = workspace.perform(selector, with: url)?.takeUnretainedValue() as? URL else { return nil }
        return Application(at: url)
    }

    static func setDefault(applicationAt url: URL = Bundle.main.bundleURL, scheme: String = "vnc") async throws {
        let selector = NSSelectorFromString("setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:")
        guard let workspace, workspace.responds(to: selector),
              let implementation = workspace.method(for: selector) else { throw CocoaError(.featureUnsupported) }

        typealias Completion = @convention(block) (NSError?) -> Void
        typealias SetDefault = @convention(c) (AnyObject, Selector, NSURL, NSString, @escaping Completion) -> Void
        let set = unsafeBitCast(implementation, to: SetDefault.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            set(workspace, selector, url as NSURL, scheme as NSString) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

struct MacVNCLinkPreferences: View {
    @Environment(\.scenePhase) private var phase
    @State private var application: MacVNCLinkHandler.Application?
    @State private var confirmsChange = false
    @State private var isUpdating = false
    @State private var failed = false

    var body: some View {
        LabeledContent("VNC 链接默认应用") {
            if let application { Text(verbatim: application.name) }
            else { Text("未设置") }
        }
        .accessibilityIdentifier("preferences.vncLinkHandler")
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .active { application = MacVNCLinkHandler.application() }
        }

        if application?.isTelescope != true {
            Button("设为默认 VNC 应用") { confirmsChange = true }
                .disabled(isUpdating)
                .accessibilityIdentifier("preferences.makeDefaultVNCHandler")
                .confirmationDialog("设为默认 VNC 应用？", isPresented: $confirmsChange, titleVisibility: .visible) {
                    Button("设为默认应用") { Task { await makeDefault() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("在此 Mac 上，VNC 链接将默认用远程随航打开。")
                }
                .alert("无法设置默认 VNC 应用", isPresented: $failed) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text("macOS 未将远程随航设为默认应用。")
                }
        }
    }

    private func makeDefault() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await MacVNCLinkHandler.setDefault()
            application = MacVNCLinkHandler.application()
            failed = application?.isTelescope != true
        } catch {
            application = MacVNCLinkHandler.application()
            let systemError = error as NSError
            let cancelled = (systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
                || (systemError.domain == NSOSStatusErrorDomain && systemError.code == -128)
            failed = !cancelled && application?.isTelescope != true
        }
    }
}
#endif
