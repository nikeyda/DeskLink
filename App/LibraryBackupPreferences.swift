import SwiftUI

struct LibraryBackupPreferences: View {
    @Environment(ConnectionLibrary.self) private var library
    @State private var backups: [LibraryBackup] = []
    @State private var selection: LibraryBackup?
    @State private var error: String?
    @State private var restored: Date?

    var body: some View {
        List {
            Section {
                if backups.isEmpty {
                    Text("暂无备份").foregroundStyle(.secondary)
                }
                ForEach(backups) { backup in
                    Button { selection = backup } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.created.formatted(date: .abbreviated, time: .standard))
                            Text("\(backup.computers) 个连接 · \(backup.folders) 个文件夹")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("backup." + backup.id.uuidString)
                }
            } footer: {
                Text("连接库变更时自动备份。此设备保留最近 10 份连接和文件夹记录。密码和密钥保存在钥匙串中。")
            }
            if let restored {
                Label("已恢复 \(restored.formatted(date: .abbreviated, time: .standard)) 的备份", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("backup.restored")
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
        .navigationTitle("连接库备份")
        .onAppear(perform: refresh)
        .onChange(of: library.archive) { refresh() }
        .alert("恢复连接库备份？", isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }),
               presenting: selection) { backup in
            Button("取消", role: .cancel) {}
            Button("恢复备份", role: .destructive) {
                do {
                    try library.restore(backup)
                    restored = backup.created
                    refresh()
                } catch { self.error = error.localizedDescription }
            }
        } message: { backup in
            Text("当前连接和文件夹将替换为所选备份。恢复前会保留这台设备上的当前数据。")
        }
    }

    private func refresh() {
        do { backups = try library.backups.list(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
