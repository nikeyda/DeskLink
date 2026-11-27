#if targetEnvironment(macCatalyst)
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class MacAvailability {
    private let defaults: UserDefaults
    private var assertion: IdleSleepAssertion?
    private static let keepAwakeKey = "mac.keepAwake"
    static let hideDockKey = "mac.hideDockIcon"
    let remoteAccess: MacRemoteAccess
    let libraryStartup: MacLibraryStartup
    let statusMenu: MacStatusMenu
    private(set) var hidesDockIcon = false
    private(set) var dockVisibilityChangeFailed = false
    private var appliedDockPreference = false
    private var dockPolicyObservation: MacDockPolicyObservation?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        libraryStartup = MacLibraryStartup(defaults: defaults)
        statusMenu = MacStatusMenu(defaults: defaults)
        remoteAccess = MacRemoteAccess(defaults: defaults)
        if defaults.bool(forKey: Self.keepAwakeKey) { assertion = IdleSleepAssertion() }
    }

    var keepAwake: Bool {
        get { assertion != nil }
        set {
            guard newValue != keepAwake else { return }
            assertion = newValue ? IdleSleepAssertion() : nil
            defaults.set(newValue, forKey: Self.keepAwakeKey)
        }
    }

    func attachStatusMenu(library: ConnectionLibrary, privacy: AppLock) {
        statusMenu.attach(library: library, privacy: privacy)
        if !appliedDockPreference {
            appliedDockPreference = true
            setDockHidden(defaults.bool(forKey: Self.hideDockKey))
        } else { refreshStatusMenu() }
    }

    func setDockHidden(_ hidden: Bool) {
        guard hidden != hidesDockIcon else { refreshStatusMenu(); return }
        // Register the recovery menu before removing the Dock icon and the app menu.
        if hidden, !statusMenu.setVisible(true) {
            dockVisibilityChangeFailed = true
            return
        }
        let changed = MacApplication.setDockHidden(hidden)
        dockVisibilityChangeFailed = !changed
        if changed {
            hidesDockIcon = hidden
            // Finder and Launch Services can promote a Catalyst app on reopen.
            dockPolicyObservation = hidden ? MacDockPolicyObservation { [weak self] in self?.restoreDockPolicyIfNeeded() } : nil
            defaults.set(hidden, forKey: Self.hideDockKey)
        }
        refreshStatusMenu()
    }

    func refreshStatusMenu() {
        statusMenu.restoreDock = hidesDockIcon ? { [weak self] in self?.setDockHidden(false) } : nil
        statusMenu.setVisible(hidesDockIcon || defaults.bool(forKey: MacStatusMenu.preference))
    }

    func restoreDockPolicyIfNeeded() {
        if hidesDockIcon, !MacApplication.isDockHidden {
            dockVisibilityChangeFailed = !MacApplication.setDockHidden(true)
        }
    }

    private final class IdleSleepAssertion {
        private let token = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                                  reason: "Telescope remote access")
        deinit { ProcessInfo.processInfo.endActivity(token) }
    }
}

struct MacAvailabilityPreferences: View {
    @Environment(MacAvailability.self) private var availability
    @Environment(\.scenePhase) private var phase
    @AppStorage(MacLibraryStartup.preference) private var hideLibraryOnLaunch = false
    @AppStorage(MacStatusMenu.preference) private var showStatusMenu = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        @Bindable var availability = availability
        Section {
            Toggle("登录时打开应用", isOn: Binding(get: {
                loginStatus == .enabled || loginStatus == .requiresApproval
            }, set: setLoginItem))
            .accessibilityIdentifier("preferences.openAtLogin")
            if loginStatus == .requiresApproval {
                Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let loginError { Text(loginError).foregroundStyle(.red) }
            Toggle("启动时隐藏连接库", isOn: $hideLibraryOnLaunch)
                .accessibilityIdentifier("preferences.hideLibraryOnLaunch")
            Toggle("隐藏程序坞图标", isOn: Binding(get: { availability.hidesDockIcon }, set: availability.setDockHidden))
                .accessibilityIdentifier("preferences.hideDockIcon")
            Toggle("在菜单栏中显示", isOn: Binding(get: { availability.hidesDockIcon || showStatusMenu },
                                                set: { showStatusMenu = $0 }))
                .accessibilityIdentifier("preferences.showStatusMenu")
                .disabled(availability.hidesDockIcon)
                .onChange(of: showStatusMenu) { availability.refreshStatusMenu() }
            if availability.hidesDockIcon {
                Text("可从菜单栏打开连接库或恢复程序坞图标。").font(.footnote).foregroundStyle(.secondary)
            }
            if availability.dockVisibilityChangeFailed {
                Text("无法更改程序坞图标的显示状态。").font(.footnote).foregroundStyle(.red)
            }
            Toggle("保持这台 Mac 唤醒", isOn: $availability.keepAwake)
                .accessibilityIdentifier("preferences.keepMacAwake")
            NavigationLink("异网接入") { MacRemoteAccessPreferences(access: availability.remoteAccess) }
                .accessibilityIdentifier("preferences.remoteAccess")
        } header: { Text("这台 Mac") } footer: {
            Text("保持唤醒可让 Mac 在应用运行期间接受远程连接，显示器仍可自动关闭。")
        }
        .onChange(of: phase, initial: true) { _, phase in
            if phase == .active { loginStatus = SMAppService.mainApp.status }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        loginStatus = service.status
    }
}

private struct MacRemoteAccessPreferences: View {
    let access: MacRemoteAccess
    @State private var automatic = true
    @State private var service: MacAccessService = .ssh
    @State private var address = ""

    private var manualEndpoint: Endpoint? { try? Endpoint(address: address, defaultPort: service.port) }

    var body: some View {
        Form {
            Section {
                Picker("端口映射", selection: $automatic) {
                    Text("自动").tag(true)
                    Text("手动").tag(false)
                }
                Picker("接入方式", selection: $service) {
                    Text("SSH 隧道").tag(MacAccessService.ssh)
                    Text("屏幕共享直连").tag(MacAccessService.screenSharing)
                }
                if !automatic {
                    TextField("外部主机名或 IP 地址及端口", text: $address)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("remoteAccess.address")
                }
            } footer: {
                if automatic {
                    Text("启用后，应用会请求路由器将外部 TCP 端口转发到这台 Mac 的 \(Int(service.port)) 端口。关闭后会撤销请求。")
                } else {
                    Text("请填写路由器已转发到这台 Mac 的外部地址和端口。")
                }
            }
            .disabled(access.configuration != nil)
            Section {
                if access.configuration == nil {
                    Button(automatic ? "启用自动端口映射" : "使用手动地址") {
                        if automatic { access.apply(.automatic(service)) }
                        else if let manualEndpoint { access.apply(.manual(service, manualEndpoint)) }
                    }
                    .accessibilityIdentifier("remoteAccess.enable")
                    .disabled(!automatic && manualEndpoint == nil)
                } else {
                    switch access.status {
                    case .off: EmptyView()
                    case .waiting: ProgressView("正在等待路由器分配地址…")
                    case .unavailable(let code):
                        if let code { Text("未取得端口映射（\(String(code))）") }
                        else { Text("路由器未提供可用的地址和端口。") }
                        Button("重试") { access.apply(access.configuration) }
                    case .ready(let endpoint):
                        LabeledContent("外部主机", value: endpoint.host)
                        LabeledContent("外部端口", value: String(endpoint.port))
                        if let link = access.configuration?.service.link(to: endpoint) {
                            ShareLink("分享连接链接", item: link)
                                .accessibilityIdentifier("remoteAccess.share")
                        }
                    }
                    Button(automatic ? "关闭自动端口映射" : "停用手动地址") { access.apply(nil) }
                        .accessibilityIdentifier("remoteAccess.stop")
                }
            } footer: {
                if service == .ssh {
                    Text("在这台 Mac 的系统设置中开启「屏幕共享」和「远程登录」。连接时使用有权限的 Mac 账户。")
                } else {
                    Text("在这台 Mac 的系统设置中开启「屏幕共享」，并选择可以登录的账户。")
                }
            }
        }
        .navigationTitle("异网接入")
        .onChange(of: access.configuration, initial: true) { _, config in
            guard let config else { return }
            service = config.service
            switch config {
            case .automatic: automatic = true
            case .manual(_, let endpoint):
                automatic = false
                // Endpoint.address omits 5900, which is meaningful for an external SSH port.
                let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
                address = "\(host):\(endpoint.port)"
            }
        }
    }
}
#endif
