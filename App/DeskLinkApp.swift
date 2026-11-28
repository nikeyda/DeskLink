import AppIntents
import SwiftUI
import WidgetKit
import rootshellVNC

@main
struct DeskLinkApp: App {
    @UIApplicationDelegateAdaptor(TelescopeNotificationDelegate.self) private var notificationDelegate
    @State private var library: ConnectionLibrary
    @State private var tailnet: TailnetDirectory
    @State private var sync: LibrarySync
    @State private var computerSearch = ComputerSearchIndex()
    @State private var privacy: AppLock
    #if targetEnvironment(macCatalyst)
    @State private var monitorWindows = MacMonitorWindows()
    @State private var availability: MacAvailability
    #endif
    private let preferences: UserDefaults
    private let pasteboard: UIPasteboard
    @Environment(\.scenePhase) private var phase

    init() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            DictationRecording.removeInterruptedRecordings(in: FileManager.default.temporaryDirectory)
        }
        #endif
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--test-library"),
           arguments.indices.contains(flag + 1), let id = UUID(uuidString: arguments[flag + 1]) {
            let file = FileManager.default.temporaryDirectory.appending(path: "DeskLinkTests/\(id.uuidString).json")
            _library = State(initialValue: ConnectionLibrary(file: file))
            let defaults = UserDefaults(suiteName: "DeskLinkTests." + id.uuidString)!
            pasteboard = UIPasteboard(name: UIPasteboard.Name("local.nikey.desklink.tests." + id.uuidString), create: true)
                ?? .withUniqueName()
            preferences = defaults
            #if targetEnvironment(macCatalyst)
            _availability = State(initialValue: MacAvailability(defaults: defaults))
            #endif
            let testDirectory = TailnetDirectory(defaults: defaults)
            if let listing = ProcessInfo.processInfo.environment["DESKLINK_TEST_TAILNET_LISTING"] {
                testDirectory.installTestListing(listing)
            }
            _tailnet = State(initialValue: testDirectory)
            _privacy = State(initialValue: AppLock(defaults: defaults))
            _sync = State(initialValue: LibrarySync(settings: file.deletingPathExtension().appendingPathExtension("sync.json"), defaults: defaults))
            return
        }
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        VNCDownloadStore.shared.publishCompletedDownloads(in: URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory))
        #endif
        _library = State(initialValue: ConnectionLibrary())
        pasteboard = .general
        preferences = .standard
        #if targetEnvironment(macCatalyst)
        _availability = State(initialValue: MacAvailability(defaults: .standard))
        #endif
        _tailnet = State(initialValue: TailnetDirectory())
        _sync = State(initialValue: LibrarySync())
        _privacy = State(initialValue: AppLock())
    }

    var body: some Scene {
        libraryScene
        #if targetEnvironment(macCatalyst)
        WindowGroup("显示器", id: MonitorWindowID.scene, for: MonitorWindowID.self) { $window in
            MacMonitorWindow(id: window, windows: monitorWindows, privacy: privacy)
                .defaultAppStorage(preferences)
        }
        #endif
    }

    private var libraryScene: some Scene {
        WindowGroup(id: "desklink-library", for: LibraryWindowRequest.self) { $request in
            LibraryWindow(library: library, preferences: preferences, pasteboard: pasteboard, initialRequest: request)
                .environment(library)
                .environment(tailnet)
                .environment(sync)
                .environment(privacy)
                #if targetEnvironment(macCatalyst)
                .environment(monitorWindows)
                .environment(availability)
                .onAppear {
                    availability.attachStatusMenu(library: library, privacy: privacy)
                    refreshDockShortcuts()
                }
                .onChange(of: privacy.locked) { _, _ in refreshDockShortcuts() }
                #endif
                .defaultAppStorage(preferences)
                #if DEBUG && !targetEnvironment(macCatalyst)
                .task { await AppleClipboardPeer.runIfRequested(library: library, board: pasteboard) }
                #endif
                .allowsHitTesting(!privacy.locked)
                .accessibilityHidden(privacy.locked)
                .overlay { if privacy.locked { PrivacyGate(privacy: privacy) } }
                .background { PrivacyCover(privacy: privacy).frame(width: 0, height: 0) }
                .onChange(of: library.archive) {
                    #if targetEnvironment(macCatalyst)
                    refreshDockShortcuts()
                    #endif
                    if sync.folderName != nil { Task { await sync.refresh(library) } }
                }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    #if targetEnvironment(macCatalyst)
                    refreshDockShortcuts()
                    #endif
                    if sync.preferencesChanged { Task { await sync.refresh(library) } }
                }
                .onChange(of: library.archive.widgetComputers(including: tailnet.widgetComputers), initial: true) { _, entries in
                    #if DEBUG
                    guard !ProcessInfo.processInfo.arguments.contains("--test-library") else { return }
                    #endif
                    guard library.canSync else { return }
                    DeskLinkShortcuts.updateAppShortcutParameters()
                    Task { await computerSearch.refresh(entries) }
                    if WidgetCatalog.publish(entries) {
                        WidgetCenter.shared.reloadTimelines(ofKind: WidgetCatalog.kind)
                    }
                }
                .task(id: phase == .active && !privacy.locked) {
                    if phase == .active, !privacy.locked, tailnet.needsWidgetDirectoryRefresh {
                        await tailnet.refresh()
                    }
                }
                .task(id: phase) {
                    guard phase == .active else { return }
                    #if DEBUG
                    let indexesComputers = !ProcessInfo.processInfo.arguments.contains("--test-library")
                    #else
                    let indexesComputers = true
                    #endif
                    if indexesComputers, library.canSync {
                        await computerSearch.refresh(library.archive.widgetComputers(including: tailnet.widgetComputers))
                    }
                    while !Task.isCancelled {
                        if sync.folderName != nil { await sync.refresh(library) }
                        do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    }
                }
        }
        #if targetEnvironment(macCatalyst)
        .handlesExternalEvents(matching: ["*"])
        #endif
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .background { privacy.lock() }
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if phase == .active {
                Task {
                    guard UIApplication.shared.applicationState == .active else { return }
                    await privacy.unlockAutomatically()
                }
            }
            #endif
        }
        .commands {
            SharedClipboardCommands()
            #if targetEnvironment(macCatalyst)
            MacMenus()
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    private func refreshDockShortcuts() {
        let hidden = HiddenSidebarItems(rawValue: preferences.integer(forKey: HiddenSidebarItems.preferenceKey))
        UIApplication.shared.shortcutItems = MacDockShortcuts.items(in: library.archive, locked: privacy.locked,
                                                                     showsRecents: !hidden.contains(.recent))
    }
    #endif
}
