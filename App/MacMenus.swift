#if targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

extension RemoteViewportSizing {
    var macTitle: LocalizedStringKey {
        switch self {
        case .fit: "适合窗口"
        case .fill: "填满窗口"
        case .actualSize: "实际大小"
        }
    }
}

struct MacPictureSizingMenu: View {
    @Binding var viewport: RemoteViewportState

    var body: some View {
        Menu {
            ForEach(RemoteViewportSizing.allCases, id: \.rawValue) { mode in
                Button(mode.macTitle) { viewport.reset(sizing: mode) }
            }
        } label: {
            Label("画面缩放", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
        }
        .accessibilityIdentifier("session.pictureSizing")
    }
}

struct MacLibraryMenuActions {
    let quickConnect: () -> Void
    let create: () -> Void
    let settings: () -> Void
    let transfers: () -> Void
    let diagnostics: () -> Void
    let toolbarVisible: Binding<Bool>
}

struct MacSessionMenuActions {
    let session: VNCSession
    let controls: VNCDesktopControls
    let clipboard: VNCClipboardSynchronizer?
    let clipboardSharing: Binding<Bool>?
    let observing: Bool
    let toggleObservation: () -> Void
    let toggleFullScreen: () -> Void
    let disconnect: () -> Void
    let chooseMonitor: (VNCMonitorSelection) -> Void
    let splitMonitors: () -> Void
    let isSplit: Bool
    var viewport: Binding<RemoteViewportState>?
    var startDictation: (() -> Void)?
    var captureScreenshot: (() -> Void)?
    var isFullScreen = false
}

private struct MacLibraryMenuKey: FocusedValueKey { typealias Value = MacLibraryMenuActions }
private struct MacSessionMenuKey: FocusedValueKey { typealias Value = MacSessionMenuActions }

extension FocusedValues {
    var deskLinkLibrary: MacLibraryMenuActions? {
        get { self[MacLibraryMenuKey.self] }
        set { self[MacLibraryMenuKey.self] = newValue }
    }

    var deskLinkSession: MacSessionMenuActions? {
        get { self[MacSessionMenuKey.self] }
        set { self[MacSessionMenuKey.self] = newValue }
    }
}

struct MacMenus: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.deskLinkLibrary) private var library
    @FocusedValue(\.deskLinkSession) private var desktop

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("连接诊断…") { library?.diagnostics() }
                .disabled(library == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { library?.settings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(library == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("新建连接…") { library?.create() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(library == nil)
            Button("新建窗口") { openWindow(id: "desklink-library") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("快速连接…") { library?.quickConnect() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(library == nil)
        }
        CommandMenu("连接") {
            Button(desktop?.observing == true ? "控制远程电脑" : "仅观察") { desktop?.toggleObservation() }
                .disabled(desktop?.session.connectionState.isConnected != true)
            Button(desktop?.isFullScreen == true ? "退出全屏幕" : "进入全屏幕") { desktop?.toggleFullScreen() }
                .disabled(desktop?.session.connectionState.isConnected != true)
            Button("保存屏幕快照…") { desktop?.captureScreenshot?() }
                .disabled(desktop?.session.connectionState.isConnected != true)
            Divider()
            Button("文件传输") {
                if let desktop { desktop.controls.toggleFileTransfers() }
                else { library?.transfers() }
            }
            .disabled(desktop.map { $0.observing || !$0.session.connectionState.isConnected } ?? (library == nil))
            Button("发送剪贴板") { desktop?.clipboard?.sendClipboard() }
                .disabled(desktop?.clipboard?.canSendClipboard != true)
            Button("接收剪贴板") { desktop?.clipboard?.getClipboard() }
                .disabled(desktop?.clipboard?.canGetClipboard != true)
            Divider()
            Button("屏幕帘幕…") { desktop?.controls.requestCurtainPrompt() }
                .disabled(desktop?.observing != false || desktop?.session.supportsCurtainMode != true)
            Button("断开连接") { desktop?.disconnect() }
                .disabled(desktop == nil)
        }
        CommandGroup(after: .toolbar) {
            if let library {
                Button("切换连接库工具栏") {
                    library.toolbarVisible.wrappedValue.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
            if let desktop {
                if let viewport = desktop.viewport, desktop.session.connectionState.isConnected {
                    MacPictureSizingMenu(viewport: viewport)
                }
                MonitorMenu(session: desktop.session, shortcuts: true, select: desktop.chooseMonitor,
                            split: desktop.splitMonitors, isSplit: desktop.isSplit)
            }
        }
        CommandMenu("远程输入") {
            if let desktop, !desktop.observing, desktop.session.isReadyForDesktopInput {
                RemoteCommandsMenu(session: desktop.session)
                if #available(macCatalyst 26, *), let start = desktop.startDictation {
                    Button("听写…", action: start)
                }
                Divider()
                Button("输入用户密码…") { desktop.controls.requestPasswordPrompt() }
                    .disabled(!desktop.session.canSendLoginPassword)
                Button("仅输入用户密码") { desktop.controls.requestPasswordOnlyPrompt() }
                    .disabled(!desktop.session.canSendLoginPassword)
            } else { Button("输入用户密码…") {}.disabled(true) }
        }
    }
}
#endif
