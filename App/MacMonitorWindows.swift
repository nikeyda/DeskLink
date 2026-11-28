#if targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

struct MonitorWindowID: Codable, Hashable {
    static let scene = "desklink-monitor"
    let connection: UUID
    let display: UInt32
    var virtual: Bool? = nil
}

@MainActor @Observable
final class MacMonitorWindows {
    struct Group {
        let session: VNCSession
        let computer: Computer
        let library: ConnectionLibrary
        let pointer: SessionPointerControl
        var primary: UInt32
        var children: [UInt32]
        var observing: Bool
        var focusedChild: UInt32?
        var sessionMenu: (() -> MacSessionMenuActions?)?
        var topology = VNCMonitorTopology.standard

        @MainActor func region(for display: UInt32) -> CGRect? {
            guard topology == session.monitorTopology else { return nil }
            return session.windowMonitorRegion(for: display)
        }

        func window(_ display: UInt32, connection: UUID) -> MonitorWindowID {
            let virtual: Bool? = switch topology {
            case .standard: nil
            case .physicalVideo: false
            case .virtualVideo: true
            }
            return MonitorWindowID(connection: connection, display: display, virtual: virtual)
        }
    }

    private(set) var groups: [UUID: Group] = [:]

    /// Nil defers changes until the replacement connection has published its layout.
    static func desiredChildren(session: VNCSession, locked: Bool, group: Group?,
                                saved: DesktopDisplayPreferences) -> [UInt32]? {
        guard session.connectionState.isConnected, session.hasReportedMonitorLayout, !locked else { return nil }
        if let group, group.topology != session.monitorTopology { return [] }
        let restoresSavedWindows = saved.rememberMonitor != false && session.monitorTopology == .standard
        guard let requested = group?.children ?? (restoresSavedWindows ? saved.windowedMonitors : nil),
              !requested.isEmpty else { return nil }
        return splitLayout(availableDisplays: session.selectableMonitorIDs, preferredPrimary: group?.primary,
                           requestedChildren: requested)?.children ?? []
    }

    static func splitLayout(availableDisplays: [UInt32], preferredPrimary: UInt32?,
                            requestedChildren: [UInt32]) -> (primary: UInt32, children: [UInt32])? {
        let childIDs = Set(requestedChildren)
        let existingPrimary = preferredPrimary.flatMap { availableDisplays.contains($0) ? $0 : nil }
        // Keep the current main window on its display. If it vanished, prefer
        // a display without an existing child window before promoting one.
        guard let primary = existingPrimary ?? availableDisplays.first(where: { !childIDs.contains($0) })
                ?? availableDisplays.first else { return nil }
        let children = availableDisplays.filter { $0 != primary && childIDs.contains($0) }
        return (primary, children)
    }

    func set(_ group: Group, for connection: UUID) { groups[connection] = group }

    @discardableResult
    func remove(_ connection: UUID) -> [UInt32] {
        groups.removeValue(forKey: connection)?.children ?? []
    }

    func setObserving(_ observing: Bool, for connection: UUID) {
        groups[connection]?.observing = observing
    }

    func focus(_ window: MonitorWindowID, active: Bool) {
        guard let group = groups[window.connection], group.children.contains(window.display),
              group.window(window.display, connection: window.connection) == window else { return }
        if active { groups[window.connection]?.focusedChild = window.display }
        else if group.focusedChild == window.display { groups[window.connection]?.focusedChild = nil }
    }

    func closed(_ window: MonitorWindowID) {
        guard var group = groups[window.connection], group.children.contains(window.display),
              group.window(window.display, connection: window.connection) == window else { return }
        group.children.removeAll { $0 == window.display }
        if group.focusedChild == window.display { group.focusedChild = nil }
        groups[window.connection] = group.children.isEmpty ? nil : group
        if group.topology == .standard {
            group.library.rememberMonitor(.all, for: group.computer, windowed: group.children)
        }
    }
}

struct MacMonitorWindow: View {
    let id: MonitorWindowID?
    let windows: MacMonitorWindows
    let privacy: AppLock
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("pointer.speed") private var pointerSpeed = 1.0
    @AppStorage("keyboard.localOptionKey") private var localOptionKey = VNCLocalOptionKey.off
    private var gesturePreferences = SessionGesturePreferences()
    @State private var viewport: RemoteViewportState
    @State private var keyboard = VNCKeyboardCapture()
    @State private var controls = VNCDesktopControls()
    @State private var windowSource = MacWindowSceneSource()
    @State private var showsDictation = false
    @State private var screenshot = ScreenshotExport()

    init(id: MonitorWindowID?, windows: MacMonitorWindows, privacy: AppLock) {
        self.id = id
        self.windows = windows
        self.privacy = privacy
        let sizing = id.flatMap { windows.groups[$0.connection]?.computer.initialViewportSizing } ?? .fit
        _viewport = State(initialValue: RemoteViewportState(sizing: sizing))
    }

    private var group: MacMonitorWindows.Group? {
        guard let id, let group = windows.groups[id.connection], group.children.contains(id.display),
              group.window(id.display, connection: id.connection) == id else { return nil }
        return group
    }

    private var title: String {
        guard let id, let group, let index = group.session.selectableMonitorIDs.firstIndex(of: id.display) else {
            return "显示器"
        }
        return "\(group.computer.displayName) · 显示器 \(index + 1)"
    }

    private var menu: MacSessionMenuActions? {
        guard !privacy.locked, let source = group?.sessionMenu?() else { return nil }
        return MacSessionMenuActions(session: source.session, controls: controls, clipboard: source.clipboard,
                                     clipboardSharing: source.clipboardSharing,
                                     observing: source.observing, toggleObservation: source.toggleObservation,
                                     toggleFullScreen: { windowSource.toggleFullScreen() },
                                     disconnect: source.disconnect, chooseMonitor: source.chooseMonitor,
                                     splitMonitors: source.splitMonitors, isSplit: true, viewport: $viewport,
                                     startDictation: { showsDictation = true },
                                     captureScreenshot: captureScreenshot, isFullScreen: windowSource.isFullScreen)
    }

    private func captureScreenshot() {
        guard !privacy.locked, let id, let group, let region = group.region(for: id.display) else { return }
        screenshot.capture(group.session, region: region)
    }

    private func desktop(_ group: MacMonitorWindows.Group, region: CGRect) -> RemoteDesktopView {
        @Bindable var pointer = group.pointer
        let gestures = gesturePreferences.configuration(for: group.computer,
                                                        usesAppleModifiers: group.session.serverUsesAppleModifierConvention)
        let view = RemoteDesktopView(session: group.session, keyboardCapture: keyboard,
                                     isFullScreen: windowSource.isFullScreen,
                                     toggleFullScreen: { windowSource.toggleFullScreen() },
                                     pointerSpeed: CursorTrackingSpeed.validated(group.computer.cursorTrackingSpeed) ?? pointerSpeed,
                                     touchGestures: gestures, hostOwnsRecoveryChrome: true)
            .controllingPointerMode($pointer.mode)
            .controllingViewport($viewport)
            .showingMonitor(in: region).desktopControls(controls)
            .onMonitorShortcut { group.sessionMenu?()?.chooseMonitor($0) }
            .hidesHUD(true)
        if #available(macCatalyst 26, *) { return view.onDictation { showsDictation = true } }
        return view
    }

    var body: some View {
        Group {
            if privacy.locked {
                PrivacyGate(privacy: privacy)
            } else if let id, let group {
                if group.session.connectionState.isConnected, let region = group.region(for: id.display) {
                    if group.observing {
                        VNCMonitorPicture(session: group.session, region: region, viewport: $viewport)
                    } else {
                        desktop(group, region: region)
                            .modifier(RemoteDictationPresentation(session: group.session, presented: $showsDictation,
                                                                 canControl: { self.group?.observing == false && !privacy.locked }))
                    }
                } else if group.session.connectionState.canConnect {
                    ContentUnavailableView("已断开", systemImage: "rectangle.slash")
                } else if group.session.connectionState.isConnected, group.session.hasPresentedCurrentPicture,
                          !group.session.hasReportedMonitorLayout {
                    ContentUnavailableView("显示器暂不可用", systemImage: "display")
                } else { ProgressView("等待远程画面…") }
            } else {
                ContentUnavailableView("连接已结束", systemImage: "display")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
        .background { MacWindowSceneCapture(source: windowSource, title: title) }
        .modifier(ScreenshotExporter(export: screenshot))
        .onChange(of: localOptionKey, initial: true) { _, value in
            keyboard.localOptionKey = value
        }
        .focusedSceneValue(\.deskLinkSession, menu)
        .focusedSceneValue(\.deskLinkClipboardSharing, menu?.clipboardSharing)
        .background { PrivacyCover(privacy: privacy).frame(width: 0, height: 0) }
        .background {
            SessionWindowFocus { focused in
                if let id { windows.focus(id, active: focused) }
            }.frame(width: 0, height: 0)
        }
        .task(id: group == nil) {
            if let id, group == nil { dismissWindow(id: MonitorWindowID.scene, value: id) }
        }
        .onDisappear { if let id { windows.closed(id) } }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
#endif
