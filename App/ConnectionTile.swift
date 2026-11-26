import SwiftUI

struct ConnectionTile: View {
    let name: String
    let address: String?
    let symbol: String
    var folder: String?
    var favorite = false
    var usesSSH = false
    var preview: SavedDesktopPreview?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 23, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(usesSSH ? Color.teal : Color.accentColor)
                    .frame(width: 46, height: 39)
                    .background((usesSSH ? Color.teal : Color.accentColor).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                if usesSSH {
                    Label("SSH", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let preview {
                    SavedDesktopImage(preview: preview, thumbnail: true)
                        .frame(width: 74, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: name)
                        .font(.headline).foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    if favorite {
                        Image(systemName: "star.fill").font(.caption2)
                            .foregroundStyle(.secondary).accessibilityLabel("收藏")
                    }
                }
                if let address, address != name {
                    Text(verbatim: address)
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
                }
            }
            if let folder {
                Label { Text(verbatim: folder) } icon: { Image(systemName: "folder") }
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(uiColor: contrast == .increased ? .opaqueSeparator : .separator),
                              lineWidth: contrast == .increased ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
