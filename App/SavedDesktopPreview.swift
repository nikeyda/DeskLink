import ImageIO
import SwiftUI

struct SavedDesktopPreview: Identifiable, Equatable {
    let id = UUID()
    let computerID: UUID
    let url: URL
}

struct SavedDesktopImage: View {
    let preview: SavedDesktopPreview
    var thumbnail = false
    @State private var image: CGImage?
    @State private var unreadable = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if unreadable {
                Image(systemName: "photo").accessibilityLabel("无法读取桌面快照")
            } else {
                ProgressView()
            }
        }
        .privacySensitive()
        .task(id: preview.id) {
            let url = preview.url
            let small = thumbnail
            let loaded = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                if small {
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240
                    ] as CFDictionary)
                }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
            unreadable = loaded == nil
        }
    }
}

struct SavedDesktopPreviewSettings: View {
    let library: ConnectionLibrary
    let computerID: UUID?
    @Binding var capturesOnDisconnect: Bool
    @Environment(AppLock.self) private var privacy
    @State private var confirmsClear = false
    @State private var failure: String?

    var body: some View {
        Section("桌面快照") {
            Toggle("断开时保存桌面快照", isOn: $capturesOnDisconnect)
                .accessibilityIdentifier("connection.disconnectScreenshot")
            if !privacy.locked, let computerID, let preview = library.previews[computerID] {
                NavigationLink {
                    Group {
                        if !privacy.locked, let current = library.previews[computerID] {
                            SavedDesktopImage(preview: current).padding()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("上次桌面快照")
                } label: {
                    HStack {
                        Text("上次桌面快照")
                        Spacer()
                        SavedDesktopImage(preview: preview, thumbnail: true)
                            .frame(width: 74, height: 42)
                            .clipShape(.rect(cornerRadius: 5))
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("connection.desktopPreview")
                Button("清除桌面快照", role: .destructive) {
                    failure = nil
                    confirmsClear = true
                }
                .accessibilityIdentifier("connection.clearDesktopPreview")
                .alert("清除桌面快照？", isPresented: $confirmsClear) {
                    Button("取消", role: .cancel) {}
                    Button("清除快照", role: .destructive) {
                        guard !privacy.locked else { return }
                        do { try library.clearPreview(for: computerID) }
                        catch { failure = error.localizedDescription }
                    }
                } message: {
                    Text("这会删除此设备上保存的上次桌面快照。")
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
    }
}
