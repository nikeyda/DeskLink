import SwiftUI
import UIKit

struct TailnetView: View {
    @Bindable var directory: TailnetDirectory
    var search: String
    var select: (Computer, UInt16?) -> Void
    var save: (Computer, UInt16?) -> Void
    @State private var editing = false
    @State private var unlinking = false
    @State private var managingHiddenDevices = false
    @State private var portsEditor: TailnetPortsEditor.Request?

    var body: some View {
        Group {
            if directory.account == nil {
                ContentUnavailableView {
                    Label("Tailscale", systemImage: "network")
                } actions: { Button("连接") { editing = true } }
            } else {
                let results = directory.visibleDevices.filter(matches)
                List {
                    if let error = directory.error { Text(error).foregroundStyle(.red) }
                    ForEach(results) { item in
                        if let computer = directory.computer(for: item) {
                            let id = directory.directoryID(for: item)
                            let ports = id.flatMap { directory.ports(for: $0) }
                            Button { select(computer, ports?.ssh) } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(computer.displayName)
                                        Text(computer.endpoint.address + " · " + item.os).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "desktopcomputer") }
                            }
                            .contextMenu {
                                Button("保存到连接库") { save(computer, ports?.ssh) }
                                if let id {
                                    Button("端口设置", systemImage: "network") {
                                        portsEditor = .init(id: id, name: computer.displayName, ports: ports)
                                    }
                                    Button("隐藏设备", systemImage: "eye.slash") { directory.setHidden(true, device: item) }
                                }
                            }
                        }
                    }
                    if !directory.loading && results.isEmpty {
                        if search.isEmpty && !directory.hiddenDevices.isEmpty {
                            Button("查看隐藏的设备") { managingHiddenDevices = true }
                        } else {
                            Text("未找到匹配的连接")
                        }
                    }
                }
                .refreshable { await directory.refresh() }
                .toolbar {
                    ToolbarItem { Button { Task { await directory.refresh() } } label: { Label("重试", systemImage: "arrow.clockwise") } }
                    ToolbarItem {
                        Menu {
                            Button("隐藏的设备", systemImage: "eye.slash") { managingHiddenDevices = true }
                                .disabled(directory.hiddenDevices.isEmpty)
                            Button("身份验证") { editing = true }
                            Button("断开连接", role: .destructive) { unlinking = true }
                        } label: { Label("Tailscale", systemImage: "network") }
                    }
                }
            }
        }
        .task { if directory.devices.isEmpty { await directory.refresh() } }
        .sheet(isPresented: $editing) { TailnetLogin(directory: directory) }
        .sheet(item: $portsEditor) { TailnetPortsEditor(request: $0, directory: directory) }
        .sheet(isPresented: $managingHiddenDevices) { hiddenDeviceList }
        .alert("断开连接", isPresented: $unlinking) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .destructive) {
                do { try directory.unlink() } catch { directory.error = error.localizedDescription }
            }
        } message: { Text(verbatim: directory.account?.tailnet ?? "") }
    }

    private var hiddenDeviceList: some View {
        NavigationStack {
            List(directory.hiddenDevices) { device in
                if let computer = directory.computer(for: device) {
                    LabeledContent {
                        Button("恢复显示") { directory.setHidden(false, device: device) }
                            .accessibilityLabel(Text("恢复显示：\(computer.displayName)"))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(computer.displayName)
                            Text(computer.endpoint.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if directory.hiddenDevices.isEmpty {
                    ContentUnavailableView("没有隐藏的设备", systemImage: "eye")
                }
            }
            .navigationTitle("隐藏的设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { managingHiddenDevices = false } } }
        }
    }

    private func matches(_ item: TailnetDevice) -> Bool {
        search.isEmpty || item.hostname.localizedCaseInsensitiveContains(search) || item.name.localizedCaseInsensitiveContains(search)
            || item.addresses.contains(where: { $0.localizedCaseInsensitiveContains(search) })
            || directory.computer(for: item)?.endpoint.address.localizedCaseInsensitiveContains(search) == true
    }
}

private struct TailnetPortsEditor: View {
    struct Request: Identifiable {
        let id: UUID
        let name: String
        let ports: TailnetDevicePorts?
    }

    let request: Request
    let directory: TailnetDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var vnc: String
    @State private var ssh: String
    @State private var error: String?

    init(request: Request, directory: TailnetDirectory) {
        self.request = request
        self.directory = directory
        _vnc = State(initialValue: request.ports?.vnc.map(String.init) ?? "")
        _ssh = State(initialValue: request.ports?.ssh.map(String.init) ?? "")
    }

    private var validated: TailnetDevicePorts? { try? .init(vnc: vnc, ssh: ssh) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    portField("VNC 端口", value: $vnc, placeholder: "5900", id: "vnc")
                    portField("SSH 端口", value: $ssh, placeholder: "22", id: "ssh")
                    if let error { Text(error).foregroundStyle(.red) }
                } header: { Text(verbatim: request.name) } footer: {
                    Text("留空使用默认端口。仅在启用安全连接时使用 SSH 端口。")
                }
            }
            .navigationTitle("端口设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let validated else { return }
                        do {
                            try directory.setPorts(validated, for: request.id)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("tailnet.ports.save")
                    .disabled(validated == nil)
                }
            }
        }
    }

    private func portField(_ title: LocalizedStringKey, value: Binding<String>, placeholder: String, id: String) -> some View {
        LabeledContent {
            TextField(title, text: value, prompt: Text(verbatim: placeholder))
                // iPadOS can place the floating number pad over the sheet's Save button.
                .keyboardType(UIDevice.current.userInterfaceIdiom == .pad ? .numbersAndPunctuation : .numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("tailnet.ports." + id)
        } label: { Text(title) }
    }
}

private struct TailnetLogin: View {
    let directory: TailnetDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var tailnet = ""
    @State private var identifier = ""
    @State private var secret = ""
    @State private var remember = false
    @State private var error: String?
    @State private var login: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Tailnet ID", text: $tailnet)
                TextField("Client ID", text: $identifier)
                SecureField("Client Secret", text: $secret)
                Toggle("记住密码", isOn: $remember)
                if directory.loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Tailscale")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        login = Task {
                            do {
                                let account = try TailnetAccount(tailnet: tailnet, clientID: identifier)
                                try await directory.link(account, secret: secret, remember: remember)
                                dismiss()
                            } catch is CancellationError {
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(directory.loading || secret.isEmpty || (try? TailnetAccount(tailnet: tailnet, clientID: identifier)) == nil)
                }
            }
        }
        .onAppear { tailnet = directory.account?.tailnet ?? ""; identifier = directory.account?.clientID ?? "" }
        .onDisappear { login?.cancel() }
    }
}
