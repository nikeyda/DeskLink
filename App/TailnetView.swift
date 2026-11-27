import SwiftUI
import UIKit

struct TailnetView: View {
    @Bindable var directory: TailnetDirectory
    let archiveFolders: [ScreensDirectoryFolder]
    var search: String
    var listLayout: Bool
    var gridColumns: [GridItem]
    var select: (Computer, UInt16?) -> Void
    var save: (Computer, UInt16?) -> Void
    @State private var selectedDevice: String?
    @State private var editing = false
    @State private var unlinking = false
    @State private var managingHiddenDevices = false
    @State private var portsEditor: TailnetPortsEditor.Request?
    @State private var folderEditor: TailnetFolderEditor.Request?
    @State private var deletingFolder: TailnetFolder?
    @State private var archiveImportAccount: TailnetAccount?
    @State private var archiveImportResult: TailnetFolderImportResult?

    var body: some View {
        Group {
            if directory.account == nil {
                ContentUnavailableView {
                    Label("访问 Tailscale 设备", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("关联 Tailscale 账户以发现设备。连接前，请让两台设备加入同一网络，并在远端开启屏幕共享或 VNC。")
                } actions: {
                    Button("关联账户") { editing = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("tailnet.linkAccount")
                }
            } else {
                devicesCollection
                    .refreshable { await directory.refresh() }
                .toolbar {
                    ToolbarItem {
                        Button { Task { await directory.refresh() } } label: {
                            Label("刷新设备", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("tailnet.refresh")
                        .disabled(directory.loading)
                    }
                    ToolbarItem {
                        Menu {
                            Button("新建文件夹", systemImage: "folder.badge.plus") {
                                folderEditor = .init(folder: nil)
                            }
                            if !archiveFolders.isEmpty {
                                Button("导入归档分组", systemImage: "square.and.arrow.down") {
                                    archiveImportAccount = directory.account
                                }
                                .accessibilityIdentifier("tailnet.folder.import")
                                .disabled(!directory.canImportArchiveFolders)
                            }
                            if let folder = directory.selectedFolder {
                                Button("重命名文件夹", systemImage: "pencil") {
                                    folderEditor = .init(folder: folder)
                                }
                                Button(role: .destructive) { deletingFolder = folder } label: {
                                    Label("删除文件夹", systemImage: "trash")
                                }
                            }
                            Divider()
                            Button("隐藏的设备", systemImage: "eye.slash") { managingHiddenDevices = true }
                                .disabled(directory.hiddenDevices.isEmpty)
                            Button("身份验证") { editing = true }
                            Button("断开连接", role: .destructive) { unlinking = true }
                        } label: { Label("Tailscale", systemImage: "network") }
                            .accessibilityIdentifier("tailnet.menu")
                    }
                }
            }
        }
        .task { if directory.devices.isEmpty { await directory.refresh() } }
        .onChange(of: directory.selectedFolder?.id) { selectedDevice = nil }
        .onChange(of: directory.account) { archiveImportResult = nil }
        .sheet(isPresented: $editing) { TailnetLogin(directory: directory) }
        .sheet(item: $portsEditor) { TailnetPortsEditor(request: $0, directory: directory) }
        .sheet(item: $folderEditor) { TailnetFolderEditor(request: $0, directory: directory) }
        .sheet(isPresented: $managingHiddenDevices) { hiddenDeviceList }
        .alert("删除文件夹", isPresented: Binding(
            get: { deletingFolder != nil },
            set: { if !$0 { deletingFolder = nil } }
        ), presenting: deletingFolder) { folder in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { directory.removeFolder(folder.id) }
        } message: { _ in
            Text("文件夹中的设备仍可在「所有设备」查看。")
        }
        .alert("导入归档分组", isPresented: Binding(
            get: { archiveImportAccount != nil },
            set: { if !$0 { archiveImportAccount = nil } }
        ), presenting: archiveImportAccount) { account in
            Button("取消", role: .cancel) {}
            Button("导入") {
                do { archiveImportResult = try directory.importArchiveFolders(archiveFolders, into: account) }
                catch { directory.error = error.localizedDescription }
            }
        } message: { account in
            Text("将归档分组应用到 \(account.tailnet)。已有分组的设备保留原位置。")
        }
        .alert("断开连接", isPresented: $unlinking) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .destructive) {
                do { try directory.unlink() } catch { directory.error = error.localizedDescription }
            }
        } message: { Text(verbatim: directory.account?.tailnet ?? "") }
    }

    private var devicesCollection: some View {
        let results = directory.devicesInSelectedFolder.filter(matches)
        return Group {
            if listLayout {
                List {
                    directoryStatus
                    if !directory.folders.isEmpty { folderPicker }
                    devices(results)
                    if results.isEmpty { emptyDirectory }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("tailnet.list")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        directoryStatus
                        if !directory.folders.isEmpty { folderPicker }
                        if results.isEmpty {
                            emptyDirectory
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 14) { devices(results) }
                        }
                    }
                    .padding(24)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .accessibilityIdentifier("tailnet.grid")
            }
        }
    }

    @ViewBuilder private var directoryStatus: some View {
        if let error = directory.error {
            Label {
                Text(verbatim: error)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("tailnet.refreshError")
        }
        if let result = archiveImportResult {
            Text("新增文件夹 \(result.foldersAdded) 个，归组设备 \(result.devicesAssigned) 台，未应用分组 \(result.groupsSkipped) 个。")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tailnet.folder.importResult")
        }
    }

    @ViewBuilder private var emptyDirectory: some View {
        if directory.loading {
            ProgressView("正在查找 Tailscale 设备…")
        } else if directory.error == nil {
            if !search.isEmpty {
                Text("未找到匹配的连接").foregroundStyle(.secondary)
            } else if directory.selectedFolder != nil {
                Text("此文件夹没有设备").foregroundStyle(.secondary)
            } else if !directory.hiddenDevices.isEmpty {
                Button("查看隐藏的设备") { managingHiddenDevices = true }
            } else {
                ContentUnavailableView("未找到其他设备", systemImage: "desktopcomputer")
            }
        }
    }

    private func devices(_ results: [TailnetDevice]) -> some View {
        ForEach(results) { item in
            if let computer = directory.computer(for: item) {
                deviceItem(item, computer: computer)
            }
        }
    }

    private var folderPicker: some View {
        Picker("文件夹", selection: Binding(get: { directory.selectedFolder?.id }, set: directory.selectFolder)) {
            Text("所有设备").tag(nil as UUID?)
            ForEach(directory.folders) { folder in
                Text(verbatim: folder.name).tag(folder.id as UUID?)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("tailnet.folder.selection")
    }

    private func deviceItem(_ device: TailnetDevice, computer: Computer) -> some View {
        let id = directory.directoryID(for: device)
        let ports = id.flatMap { directory.ports(for: $0) }
        let membership = directory.folderID(for: device)
        let folderName = directory.folders.first { $0.id == membership }?.name
        return DiscoveredConnectionItem(id: "tailnet.device." + device.id, selection: $selectedDevice,
                                        cornerRadius: listLayout ? 8 : 16, endpoint: computer.endpoint) {
            select(computer, ports?.ssh)
        } label: {
            if listLayout {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: computer.displayName)
                        Text(verbatim: [computer.endpoint.address, device.os, folderName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "desktopcomputer").foregroundStyle(Color.accentColor) }
            } else {
                ConnectionTile(name: computer.displayName, address: computer.endpoint.address,
                               symbol: "desktopcomputer", folder: folderName)
            }
        } actions: {
            Button("保存到连接库") { save(computer, ports?.ssh) }
            if let id {
                let destinations = directory.folders.filter { $0.id != membership }
                if !destinations.isEmpty {
                    Menu("移到文件夹", systemImage: "folder") {
                        ForEach(destinations) { folder in
                            Button { directory.moveDevice(id, to: folder.id) } label: { Text(verbatim: folder.name) }
                        }
                    }
                }
                if membership != nil {
                    Button("移出文件夹", systemImage: "folder.badge.minus") { directory.moveDevice(id, to: nil) }
                }
                Button("端口设置", systemImage: "network") {
                    portsEditor = .init(id: id, name: computer.displayName, ports: ports)
                }
                Button("隐藏设备", systemImage: "eye.slash") { directory.setHidden(true, device: device) }
            }
        }
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

private struct TailnetFolderEditor: View {
    struct Request: Identifiable {
        let id = UUID()
        let folder: TailnetFolder?
    }

    let request: Request
    let directory: TailnetDirectory
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(request: Request, directory: TailnetDirectory) {
        self.request = request
        self.directory = directory
        _name = State(initialValue: request.folder?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("文件夹名称", text: $name)
                    .accessibilityIdentifier("tailnet.folder.name")
            }
            .navigationTitle(request.folder == nil ? "新建文件夹" : "重命名文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let folder = request.folder { directory.renameFolder(folder.id, to: name) }
                        else { directory.addFolder(name) }
                        dismiss()
                    }
                    .disabled(!directory.canNameFolder(name, excluding: request.folder?.id))
                    .accessibilityIdentifier("tailnet.folder.save")
                }
            }
        }
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
                Section {
                    TextField("Tailnet ID", text: $tailnet)
                    TextField("Client ID", text: $identifier)
                    SecureField("Client Secret", text: $secret)
                    Toggle("记住凭据", isOn: $remember)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("请在 Tailscale 管理控制台创建具有设备基本信息读取权限的 OAuth 客户端。")
                        Link("查看 Tailscale 设置说明", destination: URL(string: "https://tailscale.com/docs/features/oauth-clients")!)
                    }
                }
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
                            } catch { self.error = TailnetDirectory.authErrorMessage(error) }
                        }
                    }.disabled(directory.loading || secret.isEmpty || (try? TailnetAccount(tailnet: tailnet, clientID: identifier)) == nil)
                }
            }
        }
        .onAppear { tailnet = directory.account?.tailnet ?? ""; identifier = directory.account?.clientID ?? "" }
        .onDisappear { login?.cancel() }
    }
}
