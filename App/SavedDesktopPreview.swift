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
