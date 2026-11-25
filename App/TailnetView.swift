import SwiftUI

struct TailnetView: View {
    @Bindable var directory: TailnetDirectory
    var search: String
    var select: (Computer) -> Void
    var save: (Computer) -> Void
    @State private var editing = false
    @State private var unlinking = false

    var body: some View {
        Group {
            if directory.account == nil {
                ContentUnavailableView {
                    Label("Tailscale", systemImage: "network")
                } actions: { Button("连接") { editing = true } }
            } else {
                List {
                    if let error = directory.error { Text(error).foregroundStyle(.red) }
                    ForEach(directory.devices.filter(matches)) { item in
                        if let computer = item.computer {
                            Button { select(computer) } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(computer.displayName)
                                        Text(computer.endpoint.address + " · " + item.os).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "desktopcomputer") }
                            }
                            .contextMenu { Button("保存到连接库") { save(computer) } }
                        }
                    }
                    if !directory.loading && directory.devices.filter(matches).isEmpty { Text("未找到匹配的连接") }
                }
                .refreshable { await directory.refresh() }
                .toolbar {
                    ToolbarItem { Button { Task { await directory.refresh() } } label: { Label("重试", systemImage: "arrow.clockwise") } }
                    ToolbarItem {
                        Menu {
                            Button("身份验证") { editing = true }
                            Button("断开连接", role: .destructive) { unlinking = true }
                        } label: { Label("Tailscale", systemImage: "network") }
                    }
                }
            }
        }
        .task { if directory.devices.isEmpty { await directory.refresh() } }
        .sheet(isPresented: $editing) { TailnetLogin(directory: directory) }
        .alert("断开连接", isPresented: $unlinking) {
            Button("取消", role: .cancel) {}
            Button("确认", role: .destructive) {
                do { try directory.unlink() } catch { directory.error = error.localizedDescription }
            }
        } message: { Text(verbatim: directory.account?.tailnet ?? "") }
    }

    private func matches(_ item: TailnetDevice) -> Bool {
        search.isEmpty || item.hostname.localizedCaseInsensitiveContains(search) || item.name.localizedCaseInsensitiveContains(search)
            || item.addresses.contains(where: { $0.localizedCaseInsensitiveContains(search) })
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
