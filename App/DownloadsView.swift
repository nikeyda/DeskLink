import SwiftUI
import rootshellVNC

struct DownloadsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = VNCDownloadStore.shared
    @State private var toMove: VNCStoredDownload?
    @State private var toDelete: VNCStoredDownload?
    @State private var movePresented = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if !store.hasLoaded {
                    ProgressView()
                } else if store.downloads.isEmpty {
                    ContentUnavailableView("没有传输", systemImage: "tray")
                } else {
                    List(store.downloads) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { toMove = item; movePresented = true } label: {
                                Label("保存", systemImage: "square.and.arrow.down")
                            }.buttonStyle(.borderless).labelStyle(.iconOnly)
                            ShareLink(item: item.url).buttonStyle(.borderless).labelStyle(.iconOnly)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { toDelete = item }
                        }
                        .contextMenu {
                            Button("保存") { toMove = item; movePresented = true }
                            Button("删除", role: .destructive) { toDelete = item }
                        }
                    }
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle("文件传输")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .task { await store.refresh() }
        }
        .fileMover(isPresented: $movePresented, file: toMove?.url) { result in
            defer { toMove = nil }
            switch result {
            case .success: if let item = toMove { store.downloadWasMoved(item) }
            case .failure(let problem as CocoaError) where problem.code == .userCancelled: break
            case .failure(let problem): error = problem.localizedDescription
            }
        }
        .alert("删除", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
               presenting: toDelete) { item in
            Button("删除", role: .destructive) { Task { await store.delete(item) } }
            Button("取消", role: .cancel) {}
        } message: { item in Text(item.name) }
        .alert("文件传输失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("关闭", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}
