#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import rootshellVNC

struct PadLibraryMenuActions {
    let quickConnect: () -> Void
    let create: () -> Void
    let settings: () -> Void
    let transfers: () -> Void
}

struct PadSessionMenuActions {
    let session: VNCSession
    let controls: VNCDesktopControls
    let clipboard: VNCClipboardSynchronizer?
    let observing: Bool
    let toggleObservation: () -> Void
    let toggleFullScreen: () -> Void
    let disconnect: () -> Void
    let chooseMonitor: (VNCMonitorSelection) -> Void
    let captureScreenshot: () -> Void
    let allowsInput: () -> Bool
}

private struct PadLibraryMenuKey: FocusedValueKey { typealias Value = PadLibraryMenuActions }
private struct PadSessionMenuKey: FocusedValueKey { typealias Value = PadSessionMenuActions }

extension FocusedValues {
    var telescopePadLibrary: PadLibraryMenuActions? {
        get { self[PadLibraryMenuKey.self] }
        set { self[PadLibraryMenuKey.self] = newValue }
    }

    var telescopePadSession: PadSessionMenuActions? {
        get { self[PadSessionMenuKey.self] }
        set { self[PadSessionMenuKey.self] = newValue }
    }
}

struct PadMenus: Commands {
    @FocusedValue(\.telescopePadLibrary) private var library
    @FocusedValue(\.telescopePadSession) private var desktop

    private var connected: Bool { desktop?.session.connectionState.isConnected == true }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { library?.settings() }
                .disabled(library == nil)
        }
        CommandGroup(after: .newItem) {
            Button("新建连接…") { library?.create() }
                .disabled(library == nil)
            Button("快速连接…") { library?.quickConnect() }
                .disabled(library == nil)
        }
        CommandMenu("连接") {
            if let desktop {
                Button(desktop.observing ? "控制远程电脑" : "仅观察", action: desktop.toggleObservation)
                    .disabled(!connected)
                Button("切换全屏幕", action: desktop.toggleFullScreen)
                    .disabled(!connected)
                Button("保存屏幕快照…", action: desktop.captureScreenshot)
                    .disabled(!connected)
                if connected {
                    MonitorMenu(session: desktop.session, select: desktop.chooseMonitor)
                }
                Divider()
            }
            Button("文件传输") {
                if let desktop {
                    guard desktop.allowsInput() else { return }
                    desktop.controls.toggleFileTransfers()
                } else {
                    library?.transfers()
                }
            }
            .disabled(desktop.map { $0.observing || !connected } ?? (library == nil))
            if let desktop {
                Button("发送剪贴板") {
                    guard desktop.allowsInput() else { return }
                    desktop.clipboard?.sendClipboard()
                }
                .disabled(!connected || desktop.clipboard?.canSendClipboard != true)
                Button("接收剪贴板") {
                    guard desktop.allowsInput() else { return }
                    desktop.clipboard?.getClipboard()
                }
                .disabled(!connected || desktop.clipboard?.canGetClipboard != true)
                Divider()
                Button("断开连接", role: .destructive, action: desktop.disconnect)
            }
        }
        if let desktop, desktop.session.isReadyForDesktopInput, !desktop.observing {
            CommandMenu("远程输入") {
                RemoteCommandsMenu(session: desktop.session, allowsInput: desktop.allowsInput)
            }
        }
    }
}
#endif
