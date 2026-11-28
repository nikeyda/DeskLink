import SwiftUI
import UIKit

struct QuickConnectDevicePicker: View {
    let showsNearby: Bool
    let showsTailnet: Bool
    let select: (Computer, UInt16?) -> Void

    @Environment(TailnetDirectory.self) private var tailnet
    @Environment(AppLock.self) private var privacy
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var nearby = NearbyComputers()
    @State private var search = ""
    @FocusState private var editsSearch: Bool

    private var canBrowse: Bool { !privacy.locked && scenePhase != .background }
    private var query: LibrarySearchQuery { LibrarySearchQuery(search) }

    var body: some View {
        List {
            if !privacy.locked {
                searchRow
                if showsNearby { nearbySection }
                if showsTailnet, tailnet.account != nil { tailnetSection }
            }
        }
        .navigationTitle("选择电脑")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("connection.devicePicker")
        .onChange(of: canBrowse && showsNearby, initial: true) { _, browsing in
            if browsing { nearby.start() } else { nearby.stop() }
        }
        .onDisappear { nearby.stop() }
        .task(id: canBrowse && showsTailnet) {
            if canBrowse && showsTailnet && tailnet.devices.isEmpty { await tailnet.refresh() }
        }
    }

    private var searchRow: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索电脑", text: $search)
                .focused($editsSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { editsSearch = false }
                .accessibilityIdentifier("connection.deviceSearch")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除搜索")
            }
        }
    }

    private var nearbySection: some View {
        Section("附近") {
            let results = nearby.entries.filter { $0.matches(query) }
            if let error = nearby.searchError {
                Label(nearby.needsLocalNetworkAccess
                      ? String(localized: "请在系统设置中允许访问本地网络。")
                      : error.localizedDescription, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                #if !targetEnvironment(macCatalyst)
                if nearby.needsLocalNetworkAccess, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("打开系统设置") { openURL(url) }
                }
                #endif
                Button("重新查找") { nearby.retry() }
            } else if nearby.isResolvingSelection {
                ProgressView("正在获取电脑地址…")
            } else if let error = nearby.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                Button("重新查找") { nearby.retry() }
            } else if results.isEmpty {
                if nearby.isSearching { ProgressView("正在查找附近的电脑…") }
                else {
                    Text(nearby.entries.isEmpty ? "未找到附近的电脑" : "没有匹配的电脑")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(results) { entry in
                Button {
                    nearby.select(entry) { choose($0, sshPort: nil) }
                } label: {
                    computerLabel(entry.name, address: entry.address)
                }
                .disabled(nearby.isResolvingSelection)
                .accessibilityIdentifier("connection.device.nearby." + entry.id)
            }
        }
    }

    private var tailnetSection: some View {
        Section("Tailscale") {
            let results = tailnet.searchMatches(query)
            if tailnet.loading, results.isEmpty {
                ProgressView("正在读取设备…")
            } else if let error = tailnet.error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text(query.isEmpty ? "未找到可连接的设备" : "没有匹配的电脑")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { entry in
                Button {
                    choose(entry.computer, sshPort: entry.sshPort)
                } label: {
                    computerLabel(entry.computer.displayName, address: entry.system.details(address: entry.computer.endpoint.address),
                                  symbol: entry.system.symbol)
                }
                .accessibilityIdentifier("connection.device.tailscale." + entry.id)
            }
            Button("刷新设备", systemImage: "arrow.clockwise") { Task { await tailnet.refresh() } }
                .disabled(tailnet.loading)
        }
    }

    private func choose(_ computer: Computer, sshPort: UInt16?) {
        guard canBrowse else { return }
        editsSearch = false
        nearby.stop()
        select(computer, sshPort)
    }

    private func computerLabel(_ name: String, address: String?, symbol: String = "desktopcomputer") -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).foregroundStyle(.primary)
                if let address {
                    Text(verbatim: address).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: { Image(systemName: symbol) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
