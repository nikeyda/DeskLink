import SwiftUI

struct DiscoveredProfileSelection {
    let computer: Computer
    let suggestedSSHPort: UInt16?
    let quality: PictureQuality?

    @MainActor
    func editor(selecting profile: Computer?, in library: ConnectionLibrary) -> EditorRequest? {
        guard let profile else { return editor(using: nil) }
        guard let current = library.profiles(forDiscovered: computer.endpoint).first(where: { $0.id == profile.id }),
              current.hasSameDestination(as: profile) else { return nil }
        return editor(using: current)
    }

    @MainActor
    func editor(using profile: Computer?) -> EditorRequest {
        let source = profile ?? computer
        let connection = quality.map { source.connecting(with: $0, on: .current) } ?? source
        return EditorRequest(purpose: .connect, computer: connection, suggestedSSHPort: suggestedSSHPort,
                             loadsStoredCredentials: profile != nil)
    }
}

struct DiscoveredProfilePicker: View {
    let selection: DiscoveredProfileSelection
    let profiles: [Computer]
    let select: (Computer?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(profiles) { profile in
                        Button { select(profile) } label: {
                            profileLabel(profile)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("connection.profile." + profile.id.uuidString)
                    }
                } header: {
                    Text(verbatim: selection.computer.endpoint.address)
                        .textCase(nil)
                }
                Button("手动填写", systemImage: "square.and.pencil") { select(nil) }
                    .accessibilityIdentifier("connection.profile.manual")
            }
            .navigationTitle("选择连接配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
            }
            .accessibilityIdentifier("connection.profilePicker")
        }
    }

    private func profileLabel(_ profile: Computer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: profile.displayName)
                .foregroundStyle(.primary)
            if !profile.username.isEmpty {
                Text(verbatim: profile.username)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let ssh = profile.ssh {
                let host = ssh.server ?? profile.endpoint.host
                let address = host.contains(":") ? "[\(host)]:\(ssh.port)" : "\(host):\(ssh.port)"
                Label {
                    Text(verbatim: "SSH · \(ssh.username)@\(address)")
                } icon: { Image(systemName: "lock") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let folder = profile.folder {
                Label(folder, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
