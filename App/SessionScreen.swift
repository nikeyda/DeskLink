import SwiftUI
import UIKit
import rootshellVNC

struct SessionScreen: View {
    let request: SessionRequest
    let library: ConnectionLibrary
    private let pasteboard: UIPasteboard
    @State private var sharesClipboard: Bool
    let close: (Bool) -> Void
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var phase
    @Environment(\.appearsActive) private var appearsActive
    @State private var keyWindowFocused = false
    @Environment(AppLock.self) private var privacy
    @State private var session: VNCSession
    @State private var clipboard: VNCClipboardSynchronizer?
    @State private var observing: Bool
    @State private var fullscreen = false
    @State private var recorded = false
    @State private var recordedVideoPause = false
    @State private var stopped = false
    @State private var closing = false
    @State private var confirmClose = false
    @State private var showsConnectionDetails = false
    @State private var reportStartedAt = Date()
    @State private var liveReport: ConnectionReport?
    @State private var diagnosticAttemptID = UUID()
    @State private var lastReportWrite: Date?
    @State private var showsDictation = false
    @State private var screenshot = ScreenshotExport()
    @State private var controls = VNCDesktopControls()
    @State private var monitorError: String?
    @AppStorage("keyboard.localOptionKey") private var localOptionKey = VNCLocalOptionKey.off
    private struct DisplayLayoutState: Equatable {
        let topology: VNCMonitorTopology
        let ids: [UInt32]
    }
    #if targetEnvironment(macCatalyst)
    @State private var macKeyboard = VNCKeyboardCapture()
    @Environment(MacMonitorWindows.self) private var monitorWindows
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var monitorGroup: MacMonitorWindows.Group? { monitorWindows.groups[request.id] }
    #endif
    #if !targetEnvironment(macCatalyst)
    @State private var mirrorAvailable = false
    @State private var mirrorEnabled = false
    @State private var toolbar = DeskToolbarState()
    @State private var toolbarBeforeFullScreen = true
    @AppStorage("toolbar.style") private var toolbarStyle = DeskToolbarStyle.docked
    @AppStorage("pencil.doubleTap") private var pencilDoubleTap = RemotePencilAction.secondaryClick
    @AppStorage("pencil.squeeze") private var pencilSqueeze = RemotePencilAction.toggleToolbar
    @AppStorage("toolbar.twoFingerToggle") private var twoFingerToggle = true
    @AppStorage("gesture.holdDuration") private var holdDuration = RemoteTouchGestureConfiguration.defaultHoldDuration
    @AppStorage("keyboard.repeat") private var repeatKeys = true
    @AppStorage("keyboard.commandReturnSwitchesApps") private var commandReturnSwitchesApps = false
    @AppStorage("keyboard.delay") private var keyDelay = VNCKeyRepeat().delay
    @AppStorage("keyboard.interval") private var keyInterval = VNCKeyRepeat().interval
    #endif
    @State private var hostTrust: HostTrust
    @AppStorage("connection.files") private var transfers = true
    @AppStorage("connection.reconnect") private var reconnect = true
    @State private var pointerMode: RemotePointerMode
    @State private var cursorTrackingSpeed: Double?
    @AppStorage("pointer.speed") private var pointerSpeed = 1.0
    @AppStorage("gesture.upFingers") private var upFingers = RemoteSwipeFingers.three
    @AppStorage("gesture.downFingers") private var downFingers = RemoteSwipeFingers.three
    @AppStorage("gesture.horizontalFingers") private var horizontalFingers = RemoteSwipeFingers.three

    private var gestures: RemoteTouchGestureConfiguration {
        var result = RemoteTouchGestureConfiguration.standard
        result.scrollSpeed = request.computer.scrollSpeed(forMac: session.serverUsesAppleModifierConvention)
        result.upFingers = upFingers
        result.downFingers = downFingers
        result.horizontalFingers = horizontalFingers
        #if !targetEnvironment(macCatalyst)
        result.holdDuration = request.computer.touchHoldDuration ?? holdDuration
        result.allowsMomentumScrolling = request.computer.momentumScrolling != false || !session.serverUsesAppleModifierConvention
        result.pencilDoubleTap = pencilDoubleTap
        result.pencilSqueeze = pencilSqueeze
        result.togglesToolbarWithTwoFingerDoubleTap = twoFingerToggle
        #endif
        return result
    }

    private var pointerMenuExtras: VNCHUDMenuExtras {
        #if targetEnvironment(macCatalyst)
        return VNCHUDMenuExtras()
        #else
        return VNCHUDMenuExtras(display: {
            CursorTrackingSpeedPicker(selection: Binding(get: { cursorTrackingSpeed }, set: setCursorTrackingSpeed))
                .accessibilityIdentifier("session.cursorTrackingSpeed")
        })
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func setCursorTrackingSpeed(_ speed: Double?) {
        guard session.connectionState.isConnected, !observing, !privacy.locked else { return }
        if var saved = library.existingComputer(matching: request.computer), saved.saved,
           saved.id == request.computer.id, saved.hasSameDestination(as: request.computer),
           saved.cursorTrackingSpeed != speed {
            saved.cursorTrackingSpeed = speed
            guard library.save(saved) else { return }
        }
        cursorTrackingSpeed = speed
    }
    #endif

    private var sessionKeyboard: VNCKeyboardCapture {
        #if targetEnvironment(macCatalyst)
        macKeyboard
        #else
        toolbar.keyboard
        #endif
    }

    private var remoteDesktop: RemoteDesktopView {
        #if targetEnvironment(macCatalyst)
        let remoteActivity: (@MainActor () -> Void)? = nil
        let initialSizing = RemoteViewportSizing.fit
        #else
        let initialSizing = request.computer.initialViewportSizing ?? .fit
        let remoteActivity: (@MainActor () -> Void)? = toolbarStyle == .carousel ? toolbar.noteRemoteActivity : nil
        #endif
        let desktop = RemoteDesktopView(session: session, keyboardCapture: sessionKeyboard, isFullScreen: fullscreen,
                                 toggleFullScreen: toggleFullScreen, clipboardSynchronizer: clipboard,
                                 initialViewportSizing: initialSizing,
                                 pointerSpeed: cursorTrackingSpeed ?? pointerSpeed, touchGestures: gestures, onRemoteInput: remoteActivity,
                                 onSharedClipboardUserChange: setClipboardSharing, hudMenuExtras: pointerMenuExtras)
            .controllingPointerMode($pointerMode)
            .desktopControls(controls)
            .onMonitorShortcut(chooseMonitor)
            .onScreenshotShortcut(captureScreenshot)
        if #available(iOS 26, macCatalyst 26, *) { return desktop.onDictation { showsDictation = true } }
        return desktop
    }

    init(request: SessionRequest, library: ConnectionLibrary, preferences: UserDefaults, pasteboard: UIPasteboard, close: @escaping (Bool) -> Void) {
        self.request = request
        self.library = library
        self.pasteboard = pasteboard
        let clipboardEnabled = preferences.object(forKey: "connection.sharedClipboard") as? Bool ?? true
        _sharesClipboard = State(initialValue: clipboardEnabled && request.computer.automaticallySharesClipboard != false)
        self.close = close
        let trust = HostTrust(defaults: preferences)
        _hostTrust = State(initialValue: trust)
        var configuration = request.computer.configuration(preferences: preferences,
            streamingPaused: library.videoRetryDate(for: request.computer) != nil)
        configuration.rsaHostValidationHandler = { host, port, fingerprint in
            await trust.verify(host: host, port: port, fingerprint: fingerprint, kind: .rsa)
        }
        configuration.certificateValidationHandler = { await trust.verifyCertificate($0) }
        if request.computer.viewOnly { configuration.allowsFileTransfers = false }
        if let ssh = request.computer.ssh {
            let proof = request.sshProof
            configuration.transportProvider = { host, port in
                guard let proof else { throw URLError(.userAuthenticationRequired) }
                return DesktopSSH(host: host, desktopPort: port, settings: ssh, proof: proof, trust: trust)
            }
        }
        _session = State(initialValue: VNCSession(configuration: configuration))
        _observing = State(initialValue: request.computer.viewOnly)
        _pointerMode = State(initialValue: request.computer.pointerMode(using: preferences))
        _cursorTrackingSpeed = State(initialValue: CursorTrackingSpeed.validated(request.computer.cursorTrackingSpeed))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if !fullscreen || observing || !session.connectionState.isConnected {
                    HStack(spacing: 14) {
                        Button { finish(edit: false) } label: { Label("返回", systemImage: "chevron.backward") }
                            .labelStyle(.iconOnly)
                        Button { liveReport = nil; showsConnectionDetails = true } label: {
                            VStack(alignment: .leading) {
                                HStack(spacing: 4) {
                                    Text(request.computer.displayName).font(.headline).lineLimit(1)
                                    if session.connectionState.isConnected {
                                        Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if request.computer.displayName != request.computer.endpoint.address {
                                    Text(request.computer.endpoint.address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.connectionState.isConnected)
                        .accessibilityLabel("连接信息")
                        .accessibilityValue(request.computer.displayName)
                        .accessibilityIdentifier("session.info")
                        Spacer()
                        if session.connectionState.isConnected {
                            if session.isCurtained {
                                Label("屏幕帘幕已开启", systemImage: "eye.slash.fill")
                                    .labelStyle(.iconOnly)
                                    .accessibilityIdentifier("session.curtainActive")
                            }
                            Button { toggleObservation() } label: {
                                Label(observing ? "仅观察" : "控制", systemImage: observing ? "eye" : "cursorarrow")
                            }
                            .accessibilityIdentifier("session.mode")
                            #if targetEnvironment(macCatalyst)
                            MonitorMenu(session: session, select: chooseMonitor, split: showAllMonitorWindows,
                                        isSplit: monitorGroup != nil).labelStyle(.iconOnly)
                            if !observing, session.canSendLoginPassword {
                                PasswordTypingButton(controls: controls) {
                                    Label("输入用户密码", systemImage: "key.fill").labelStyle(.iconOnly)
                                }
                                .accessibilityIdentifier("session.password")
                            }
                            if #available(macCatalyst 26, *), !observing {
                                Button { showsDictation = true } label: { Label("听写", systemImage: "mic").labelStyle(.iconOnly) }
                                    .accessibilityIdentifier("session.dictation")
                            }
                            #else
                            MonitorMenu(session: session, shortcuts: true, select: chooseMonitor).labelStyle(.iconOnly)
                            #endif
                            #if !targetEnvironment(macCatalyst)
                            if !observing {
                                Button { toolbar.visible.toggle() } label: {
                                    Label(toolbar.visible ? "隐藏工具栏" : "显示工具栏", systemImage: "rectangle.bottomthird.inset.filled")
                                        .labelStyle(.iconOnly)
                                }.accessibilityIdentifier("toolbar.toggle")
                            }
                            if mirrorAvailable {
                                Toggle(isOn: $mirrorEnabled) {
                                    Label("镜像到外部显示器", systemImage: "airplayvideo").labelStyle(.iconOnly)
                                }.toggleStyle(.button)
                            }
                            #endif
                            Button(action: captureScreenshot) {
                                Label("保存屏幕快照", systemImage: "camera").labelStyle(.iconOnly)
                            }.accessibilityIdentifier("session.screenshot")
                            #if !targetEnvironment(macCatalyst)
                            .keyboardShortcut("r", modifiers: [.shift, .control, .command])
                            #endif
                            if !observing, let clipboard {
                                Menu {
                                    if let sharing = clipboardSharing {
                                        Toggle("自动共享剪贴板", isOn: sharing).accessibilityIdentifier("session.sharedClipboard")
                                        Divider()
                                    }
                                    Button("发送剪贴板") { clipboard.sendClipboard() }
                                        .disabled(!clipboard.canSendClipboard)
                                    Button("接收剪贴板") { clipboard.getClipboard() }
                                        .disabled(!clipboard.canGetClipboard)
                                } label: { Label("共享剪贴板", systemImage: "list.clipboard").labelStyle(.iconOnly) }
                                .accessibilityIdentifier("session.clipboard")
                            }
                            Button { toggleFullScreen() } label: {
                                Label("切换全屏幕", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(.iconOnly)
                            }
                            Button { finish(edit: false) } label: {
                                Label("断开连接", systemImage: "xmark.circle").labelStyle(.iconOnly)
                            }
                            .accessibilityIdentifier("session.close")
                            #if !targetEnvironment(macCatalyst)
                            .keyboardShortcut("c", modifiers: [.shift, .control, .command])
                            #endif
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                    Divider()
                }
                switch session.connectionState {
                case .connected, .reconnecting:
                    if privacy.locked {
                        Color.clear
                    } else {
                        #if targetEnvironment(macCatalyst)
                        if let group = monitorGroup {
                            if let region = session.windowMonitorRegion(for: group.primary) {
                                if observing { VNCMonitorPicture(session: session, region: region) }
                                else { remoteDesktop.showingMonitor(in: region).ignoresSafeArea(.keyboard) }
                            } else { ProgressView("等待远程画面…") }
                        } else if observing { ObservedPicture(session: session) }
                        else { remoteDesktop.ignoresSafeArea(.keyboard) }
                        #else
                        if observing {
                            ObservedPicture(session: session, sizing: request.computer.initialViewportSizing ?? .fit)
                        } else {
                            InteractiveDesktop(desktop: remoteDesktop, session: session, controls: controls, bar: toolbar,
                                               chooseMonitor: chooseMonitor, startDictation: { showsDictation = true },
                                               captureScreenshot: captureScreenshot)
                                .ignoresSafeArea(.keyboard)
                        }
                        #endif
                    }
                case .failed(let reason):
                    ContentUnavailableView {
                        Label("连接失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(reason).textSelection(.enabled)
                    } actions: { retryActions("重试") }
                case .disconnected:
                    ContentUnavailableView {
                        Label("已断开", systemImage: "rectangle.slash")
                    } actions: { retryActions("重新连接") }
                case .idle, .connecting, .disconnecting:
                    ProgressView(session.connectionPhaseDescription ?? "正在连接…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task {
                session.userDisconnectHandler = { finish(edit: false) }
                session.authorizePasswordSend = {
                    guard !observing, !stopped, !closing, !privacy.locked else { return false }
                    let permitted = await privacy.approvePasswordSend()
                    return permitted && !observing && !stopped && !closing && !privacy.locked
                }
                session.updateRemoteDisplaySize(viewSize: geometry.size, displayScale: scale)
                let item = request.computer
                do {
                    let tunnelUserPassword: String?
                    if case let .password(value) = request.sshProof { tunnelUserPassword = value } else { tunnelUserPassword = nil }
                    try await session.connect(credentials: VNCCredentials(host: item.endpoint.host, port: item.endpoint.port,
                        password: request.password, username: item.username.isEmpty ? nil : item.username,
                        tunnelUserPassword: tunnelUserPassword))
                } catch is CancellationError {
                } catch {
                    if session.connectionState == .idle { session.connectionState = .failed(error.localizedDescription) }
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                if observing { session.updateRemoteDisplaySize(viewSize: newSize, displayScale: scale) }
            }
        }
        #if !targetEnvironment(macCatalyst)
        .onChange(of: VNCKeyRepeat(enabled: repeatKeys, delay: keyDelay, interval: keyInterval), initial: true) { _, value in
            toolbar.keyboard.keyRepeat = value
        }
        .onChange(of: commandReturnSwitchesApps, initial: true) { _, value in
            toolbar.keyboard.usesReturnForRemoteAppSwitcher = value
        }
        .background {
            if #available(iOS 27.0, *), session.connectionState.isConnected {
                ExternalDisplayMirror(session: session, privacy: privacy, enabled: mirrorEnabled && !privacy.locked && phase == .active) {
                    mirrorAvailable = $0
                    if !$0 { mirrorEnabled = false }
                }
                .frame(width: 0, height: 0)
            }
        }
        #endif
        .onChange(of: localOptionKey, initial: true) { _, value in
            sessionKeyboard.localOptionKey = value
        }
        .onChange(of: session.connectionState) { _, state in
            if case .failed = state {
                let diagnostics = session.getDiagnostics()
                library.recordDiagnosticFailure(.init(id: diagnosticAttemptID, date: .now, reason: .init(session.lastError),
                                                      usesSSH: request.computer.ssh != nil,
                                                      requestsHighPerformance: session.configuration.enableHighPerformanceMode,
                                                      version: diagnostics.clientVersion?.description,
                                                      securityType: diagnostics.selectedSecurityType?.rawValue))
            } else if state.isConnecting || state.isConnected { diagnosticAttemptID = UUID() }
            if !state.isConnected {
                if let liveReport { library.keepReport(liveReport, for: request.computer) }
                showsConnectionDetails = false
                liveReport = nil
                lastReportWrite = nil
            } else { reportStartedAt = .now }
            #if !targetEnvironment(macCatalyst)
            if !state.isConnected { mirrorAvailable = false; mirrorEnabled = false }
            #endif
            if state.isConnected, !recorded {
                recorded = true
                library.recordSuccess(request.computer)
                if request.rememberPassword {
                    do {
                        try PasswordStore.write(request.password, for: request.computer, synchronize: request.synchronizeCredentials)
                        if let ssh = request.computer.ssh, let secret = request.sshSecretToRemember {
                            try PasswordStore.write(secret, for: request.computer, kind: ssh.usesKey ? .sshKey : .sshPassword,
                                                    synchronize: request.synchronizeCredentials)
                        }
                    }
                    catch { library.errorMessage = error.localizedDescription }
                }
                if !observing { attachClipboard() }
            }
            recordVideoFallback()
        }
        .onChange(of: session.highPerformanceFallbackReason) { _, _ in recordVideoFallback() }
        .onChange(of: transfers, initial: true, syncTransferPermission)
        .task(id: DisplayLayoutState(topology: session.monitorTopology, ids: session.selectableMonitorIDs)) {
            guard !stopped, !closing else { return }
            #if targetEnvironment(macCatalyst)
            if let group = monitorGroup, group.topology != session.monitorTopology || session.selectableMonitorIDs.isEmpty {
                closeMonitorWindows()
            }
            #endif
            guard !session.selectableMonitorIDs.isEmpty else { return }
            let saved = (library.existingComputer(matching: request.computer) ?? request.computer).display(for: .current)
            #if targetEnvironment(macCatalyst)
            let restoreWindows = saved.rememberMonitor != false && session.monitorTopology == .standard
            if let windows = monitorGroup?.children ?? (restoreWindows ? saved.windowedMonitors : nil), !windows.isEmpty {
                await openMonitorWindows(windows, remember: false)
                return
            }
            #endif
            guard session.monitorTopology != .virtualVideo, saved.rememberMonitor != false, let choice = saved.lastMonitor else { return }
            do { try await session.selectMonitor(choice) } catch { if !Task.isCancelled { monitorError = error.localizedDescription } }
        }
        .alert("切换显示器失败", isPresented: Binding(get: { monitorError != nil }, set: { if !$0 { monitorError = nil } })) {
            Button("好") { monitorError = nil }
        } message: { Text(monitorError ?? "") }
        .onChange(of: reconnect, initial: true) { session.configuration.reconnectionPolicy.isEnabled = reconnect }
        .onChange(of: observing, syncTransferPermission)
        #if targetEnvironment(macCatalyst)
        .focusedSceneValue(\.deskLinkSession, macMenu)
        #endif
        .background { SessionWindowFocus { keyWindowFocused = $0 }.frame(width: 0, height: 0) }
        .focusedSceneValue(\.deskLinkClipboardSharing, clipboardSharing)
        .onChange(of: windowIsActive) { _, active in clipboard?.setHostWindowActive(active) }
        .onChange(of: privacy.locked) { _, locked in
            syncTransferPermission()
            if locked { showsConnectionDetails = false; clipboard?.invalidate(); clipboard = nil }
            else if !observing, session.connectionState.isConnected { attachClipboard() }
        }
        .sheet(isPresented: $showsConnectionDetails) {
            if !privacy.locked { ConnectionDetails(report: liveReport) }
        }
        .task(id: reportSampling) { await sampleConnection() }
        .modifier(RemoteDictationPresentation(session: session, presented: $showsDictation,
                                              canControl: { !observing && !closing && !stopped && !privacy.locked }))
        .modifier(ScreenshotExporter(export: screenshot))
        .onDisappear { closeSession(allowAction: phase != .background) {} }
        .confirmationDialog("文件传输进行中", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { closeSession(allowAction: true) { close(false) } }
            Button("取消", role: .cancel) {}
        }
        .alert(hostTrust.prompt?.kind == .tls ? "TLS" : "主机指纹", isPresented: Binding(get: { hostTrust.prompt != nil }, set: { _ in }), presenting: hostTrust.prompt) { identity in
            Button("取消", role: .cancel) { hostTrust.answer(false) }
            Button("确认") { hostTrust.answer(true, remember: identity.kind == .ssh) }
            if identity.kind == .tls { Button("记住证书") { hostTrust.answer(true) } }
            if identity.kind == .rsa { Button("记住主机指纹") { hostTrust.answer(true) } }
        } message: { identity in
            Text(verbatim: (identity.kind == .ssh ? "请核对远程计算机的 SSH 指纹。\n" : identity.kind == .rsa ? "请核对远程计算机的 RSA 公钥指纹。\n" : "") + identity.displayAddress + "\n" + identity.fingerprint)
        }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
    }

    @ViewBuilder private func retryActions(_ title: String) -> some View {
        Button(title) {
            if !recorded || !session.retryConnection() { finish(edit: true) }
        }
        .accessibilityIdentifier("session.reconnect")
        if recorded {
            Button("编辑连接") { finish(edit: true) }
                .accessibilityIdentifier("session.editConnection")
        }
    }

    private func syncTransferPermission() {
        session.configuration.allowsFileTransfers = transfers && !observing && !privacy.locked
        session.configuration.automaticCurtainMessage = observing || privacy.locked ? nil : request.computer.automaticCurtainMessage
    }

    private func recordVideoFallback() {
        guard !recordedVideoPause, session.highPerformanceFallbackReason != nil else { return }
        recordedVideoPause = library.pauseStreaming(for: request.computer)
    }

    private enum ReportSampling: Hashable { case idle, periodic, visible }
    private var reportSampling: ReportSampling {
        guard session.connectionState.isConnected, phase != .background, !privacy.locked else { return .idle }
        return showsConnectionDetails ? .visible : .periodic
    }

    private func sampleConnection() async {
        if reportSampling == .idle {
            if let liveReport { library.keepReport(liveReport, for: request.computer) }
            return
        }
        while !Task.isCancelled {
            if let value = await ConnectionReport.capture(session: session, usesSSH: request.computer.ssh != nil,
                                                          id: request.id, startedAt: reportStartedAt), !Task.isCancelled {
                let firstPicture = value.frames > 0 && (liveReport?.frames ?? 0) == 0
                let firstSound = (value.audioPackets ?? 0) > 0 && (liveReport?.audioPackets ?? 0) == 0
                let mediaChanged = value.videoCodec != liveReport?.videoCodec || value.audioPlayback != liveReport?.audioPlayback
                let periodicWriteDue = value.capturedAt.timeIntervalSince(lastReportWrite ?? .distantPast) >= 60
                liveReport = value
                if firstPicture || firstSound || mediaChanged || periodicWriteDue {
                    library.keepReport(value, for: request.computer)
                    lastReportWrite = value.capturedAt
                }
            }
            do { try await Task.sleep(for: .seconds(showsConnectionDetails ? 1 : 5)) } catch { return }
        }
    }

    private func captureScreenshot() {
        guard !stopped, !closing, !privacy.locked, phase != .background else { return }
        withScreenshotRegion { screenshot.capture(session, region: $0) }
    }

    private func withScreenshotRegion(_ capture: (CGRect?) -> Void) {
        #if targetEnvironment(macCatalyst)
        if let group = monitorGroup {
            guard let region = session.windowMonitorRegion(for: group.primary) else { return }
            capture(region)
            return
        }
        #endif
        capture(nil)
    }

    #if targetEnvironment(macCatalyst)
    private var macMenu: MacSessionMenuActions? {
        guard !privacy.locked, hostTrust.prompt == nil, !confirmClose, !closing, !stopped else { return nil }
        return MacSessionMenuActions(session: session, controls: controls, clipboard: clipboard, clipboardSharing: clipboardSharing,
                                     observing: observing, toggleObservation: toggleObservation,
                                     toggleFullScreen: toggleFullScreen, disconnect: { finish(edit: false) },
                                     chooseMonitor: chooseMonitor, splitMonitors: showAllMonitorWindows,
                                     isSplit: monitorGroup != nil, startDictation: { showsDictation = true },
                                     captureScreenshot: captureScreenshot)
    }

    private func showAllMonitorWindows() {
        let children = Array(session.selectableMonitorIDs.dropFirst())
        Task { await openMonitorWindows(children, remember: true) }
    }

    private func openMonitorWindows(_ displays: [UInt32], remember: Bool) async {
        let topology = session.monitorTopology
        let available = session.selectableMonitorIDs
        let children = available.dropFirst().filter { displays.contains($0) }
        guard !privacy.locked, !closing, !stopped, let primary = available.first, !children.isEmpty else {
            if children.isEmpty { closeMonitorWindows() }
            return
        }
        do {
            guard try await session.selectMonitor(.all), !Task.isCancelled, !privacy.locked,
                  !closing, !stopped, session.connectionState.isConnected,
                  topology == session.monitorTopology, available == session.selectableMonitorIDs else { return }
            let previous = monitorGroup?.children ?? []
            let group = MacMonitorWindows.Group(session: session, computer: request.computer, library: library,
                                                primary: primary, children: children, observing: observing,
                                                focusedChild: monitorGroup?.focusedChild, sessionMenu: { macMenu }, topology: topology)
            monitorWindows.set(group, for: request.id)
            for id in previous where !children.contains(id) {
                dismissWindow(id: MonitorWindowID.scene, value: group.window(id, connection: request.id))
            }
            for id in children where remember || !previous.contains(id) {
                openWindow(id: MonitorWindowID.scene, value: group.window(id, connection: request.id))
            }
            if remember, topology == .standard { library.rememberMonitor(.all, for: request.computer, windowed: children) }
        } catch { if !Task.isCancelled { monitorError = error.localizedDescription } }
    }

    private func closeMonitorWindows() {
        guard let group = monitorGroup else { return }
        for id in monitorWindows.remove(request.id) {
            dismissWindow(id: MonitorWindowID.scene, value: group.window(id, connection: request.id))
        }
    }
    #endif

    private var windowIsActive: Bool {
        #if targetEnvironment(macCatalyst)
        if monitorGroup?.focusedChild != nil { return !privacy.locked }
        #endif
        return keyWindowFocused && appearsActive && phase == .active
    }

    private func chooseMonitor(_ choice: VNCMonitorSelection) {
        guard !stopped, !closing, !privacy.locked else { return }
        Task {
            do {
                if try await session.selectMonitor(choice) {
                    #if targetEnvironment(macCatalyst)
                    closeMonitorWindows()
                    #endif
                    if session.monitorTopology != .virtualVideo { library.rememberMonitor(choice, for: request.computer) }
                }
            } catch { monitorError = error.localizedDescription }
        }
    }

    private var clipboardSharing: Binding<Bool>? {
        guard clipboard != nil, !observing, !privacy.locked, !closing, !stopped, session.connectionState.isConnected else { return nil }
        return Binding(get: { sharesClipboard }, set: setClipboardSharing)
    }

    private func setClipboardSharing(_ value: Bool) {
        guard !observing, !privacy.locked, !closing, !stopped else { return }
        sharesClipboard = value
        clipboard?.sharedClipboardEnabled = value
    }

    private func attachClipboard() {
        guard !privacy.locked, !closing, !stopped else { return }
        let controller = VNCClipboardSynchronizer(session: session, pasteboard: pasteboard)
        controller.setHostWindowActive(windowIsActive)
        controller.sharedClipboardEnabled = sharesClipboard
        clipboard = controller
    }

    private func toggleObservation() {
        if observing {
            attachClipboard()
        } else {
            clipboard?.sharedClipboardEnabled = false
            clipboard?.invalidate()
            clipboard = nil
        }
        observing.toggle()
        #if targetEnvironment(macCatalyst)
        monitorWindows.setObserving(observing, for: request.id)
        #endif
    }

    private func toggleFullScreen() {
        #if targetEnvironment(macCatalyst)
        if UIApplication.shared.sendAction(NSSelectorFromString("toggleFullScreen:"), to: nil, from: nil, for: nil) {
            fullscreen.toggle()
        }
        #else
        if fullscreen { toolbar.visible = toolbarBeforeFullScreen }
        else {
            toolbarBeforeFullScreen = toolbar.visible
            toolbar.visible = false
        }
        fullscreen.toggle()
        #endif
    }

    private func finish(edit: Bool) {
        if !edit, session.fileTransfers.hasActiveTransfers { confirmClose = true; return }
        closeSession(allowAction: !edit) { close(edit) }
    }

    private func closeSession(allowAction: Bool, completion: @escaping @MainActor () -> Void) {
        guard !closing, !stopped else { return }
        closing = true
        if let liveReport { library.keepReport(liveReport, for: request.computer) }
        guard allowAction, !privacy.locked, session.connectionState.isConnected else {
            tearDown()
            completion()
            return
        }
        let action = observing ? nil : request.computer.disconnectAction
        if request.computer.savesDisconnectScreenshot == true, phase != .background,
           let frame = session.presentedFrame {
            withScreenshotRegion { library.saveDisconnectScreenshot(for: request.computer, frame: frame, region: $0) }
        }
        action?.send(to: session)
        // A desktop that stopped reading must still let its window close.
        let timeout = Task { @MainActor in
            try await Task.sleep(for: .seconds(2))
            if !stopped { tearDown(); completion() }
        }
        Task { @MainActor in
            if action != nil { await session.flushPendingInput() }
            if !stopped, let final = await ConnectionReport.capture(session: session, usesSSH: request.computer.ssh != nil,
                                                                    id: request.id, startedAt: reportStartedAt) {
                library.keepReport(final, for: request.computer)
            }
            timeout.cancel()
            if !stopped { tearDown(); completion() }
        }
    }

    private func tearDown() {
        guard !stopped else { return }
        stopped = true
        #if targetEnvironment(macCatalyst)
        closeMonitorWindows()
        #endif
        hostTrust.cancel()
        clipboard?.invalidate()
        clipboard = nil
        session.userDisconnectHandler = nil
        session.authorizePasswordSend = nil
        session.disconnect()
    }
}

/// Observe mode owns no input responder, clipboard controller or file drop target.
struct ObservedPicture: View {
    let session: VNCSession
    var sizing: RemoteViewportSizing = .fit

    var body: some View {
        ZStack {
            Color.black
            if session.isHighPerformanceMode || (sizing != .fit && session.hasPresentedStandardPicture) {
                VNCMonitorPicture(session: session, sizing: sizing)
            } else if case let .image(image) = session.presentedFrame {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .accessibilityLabel("观察")
    }
}
