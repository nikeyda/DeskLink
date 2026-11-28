#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

@MainActor
enum MacVNCLinkHandler {
    static let vncURL = URL(string: "vnc://localhost")!

    struct Application {
        let url: URL
        let name: String
        let bundleIdentifier: String?

        init(at url: URL) {
            self.url = url
            let bundle = Bundle(url: url)
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            bundleIdentifier = bundle?.bundleIdentifier
        }

        var isTelescope: Bool { bundleIdentifier == "local.nikey.desklink" }
    }

    #if os(macOS)
    static func application(for url: URL = vncURL) -> Application? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map(Application.init(at:))
    }

    static func application(withBundleIdentifier identifier: String) -> Application? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let application = Application(at: url)
        return application.bundleIdentifier == identifier ? application : nil
    }

    static func setDefault(applicationAt url: URL, scheme: String = "vnc") async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme)
    }
    #else
    // Mac Catalyst cannot import AppKit. These selectors use public NSWorkspace APIs.
    private static var workspace: NSObject? {
        (NSClassFromString("NSWorkspace") as? NSObject.Type)?
            .perform(NSSelectorFromString("sharedWorkspace"))?.takeUnretainedValue() as? NSObject
    }

    static func application(for url: URL = vncURL) -> Application? {
        let selector = NSSelectorFromString("URLForApplicationToOpenURL:")
        guard let workspace, workspace.responds(to: selector),
              let applicationURL = workspace.perform(selector, with: url)?.takeUnretainedValue() as? URL else {
            return nil
        }
        return Application(at: applicationURL)
    }

    static func openSettings() -> Bool {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/TelescopeVNC.app", directoryHint: .isDirectory)
        let selector = NSSelectorFromString("openURL:")
        guard FileManager.default.isExecutableFile(atPath: tool.appending(path: "Contents/MacOS/TelescopeVNC").path),
              let workspace, workspace.responds(to: selector), let implementation = workspace.method(for: selector) else {
            return false
        }
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL) -> Bool
        return unsafeBitCast(implementation, to: OpenURL.self)(workspace, selector, tool as NSURL)
    }
    #endif
}

@MainActor @Observable
final class MacVNCLinkPreferencesModel {
    typealias Application = MacVNCLinkHandler.Application
    private static let previousAppKey = "mac.vncLink.previousApplication"
    private let preferences: UserDefaults
    private let telescope: Application
    private let readDefault: @MainActor () -> Application?
    private let findApplication: @MainActor (String) -> Application?
    private let writeDefault: @MainActor (URL) async throws -> Void
    private(set) var application: Application?
    private(set) var previousApplication: Application?
    private(set) var isUpdating = false

    init(preferences: UserDefaults, telescope: Application,
         readDefault: @escaping @MainActor () -> Application?,
         findApplication: @escaping @MainActor (String) -> Application?,
         writeDefault: @escaping @MainActor (URL) async throws -> Void) {
        self.preferences = preferences
        self.telescope = telescope
        self.readDefault = readDefault
        self.findApplication = findApplication
        self.writeDefault = writeDefault
        refresh()
    }

    func refresh() {
        application = readDefault()
        previousApplication = isSelectedApp(application) ? restorableApplication() : nil
    }

    func makeDefault() async throws {
        guard !isUpdating else { return }
        let previous = readDefault()
        guard !isSelectedApp(previous) else { refresh(); return }
        try await apply(telescope) {
            preferences.set(previous?.bundleIdentifier, forKey: Self.previousAppKey)
        }
    }

    func restorePrevious() async throws {
        guard !isUpdating else { return }
        guard isSelectedApp(readDefault()), let previous = restorableApplication() else {
            refresh()
            throw CocoaError(.fileNoSuchFile)
        }
        try await apply(previous) {
            preferences.removeObject(forKey: Self.previousAppKey)
        }
    }

    private func restorableApplication() -> Application? {
        guard let identifier = preferences.string(forKey: Self.previousAppKey),
              let previous = findApplication(identifier), !isSelectedApp(previous) else {
            return findApplication("com.apple.ScreenSharing")
        }
        return previous
    }

    private func isSelectedApp(_ application: Application?) -> Bool {
        guard let identifier = application?.bundleIdentifier else { return false }
        return identifier == telescope.bundleIdentifier
    }

    private func apply(_ target: Application, onSuccess: () -> Void) async throws {
        guard let expected = target.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
        isUpdating = true
        defer {
            isUpdating = false
            refresh()
        }
        do { try await writeDefault(target.url) }
        catch {
            guard readDefault()?.bundleIdentifier == expected else { throw error }
        }
        guard readDefault()?.bundleIdentifier == expected else { throw CocoaError(.fileWriteUnknown) }
        onSuccess()
    }
}

#if targetEnvironment(macCatalyst)
struct MacVNCLinkPreferences: View {
    @Environment(\.scenePhase) private var phase
    @State private var application: MacVNCLinkHandler.Application?
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

        Button("更改 VNC 默认应用…") { failed = !MacVNCLinkHandler.openSettings() }
            .accessibilityIdentifier("preferences.changeDefaultVNCHandler")
            .alert("无法打开 VNC 默认应用设置", isPresented: $failed) {
                Button("好", role: .cancel) {}
            }
    }
}
#endif
#endif
