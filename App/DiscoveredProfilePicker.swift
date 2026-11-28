import SwiftUI
import Network

struct DiscoveredProfileSelection {
    enum Intent {
        case connect(PictureQuality?)
        case save

        var manualActionTitle: LocalizedStringKey {
            switch self {
            case .connect: "手动填写"
            case .save: "新建连接"
            }
        }
    }

    let computer: Computer
    let suggestedSSHPort: UInt16?
    let intent: Intent
    var resolvedAddresses: Set<Endpoint> = []

    @MainActor
    func request(in library: ConnectionLibrary) -> EditorRequest {
        let candidates = profiles(in: library)
        // A numeric address can be reassigned. Require a choice before using its saved profile.
        if candidates.count == 1, let named = library.profile(forDiscovered: computer.endpoint) {
            return editor(using: named)
        }
        var request = editor(using: nil)
        if !candidates.isEmpty { request.discoveredSelection = self }
        return request
    }

    @MainActor
    func profiles(in library: ConnectionLibrary) -> [Computer] {
        let named = library.profiles(forDiscovered: computer.endpoint)
        guard !resolvedAddresses.isEmpty else { return named }
        let namedIDs = Set(named.map(\.id))
        let resolved = library.archive.computers.filter {
            $0.saved && !namedIDs.contains($0.id) && matchesResolvedAddress($0.endpoint)
        }
        return named + resolved
    }

    private func matchesResolvedAddress(_ endpoint: Endpoint) -> Bool {
        if resolvedAddresses.contains(endpoint) { return true }
        // Keep interface scopes distinct but compare the binary IPv6 address.
        let parts = endpoint.host.split(separator: "%", maxSplits: 1)
        guard let first = parts.first, let address = IPv6Address(String(first)) else { return false }
        return resolvedAddresses.contains {
            guard $0.port == endpoint.port else { return false }
            let alias = $0.host.split(separator: "%", maxSplits: 1)
            return alias.dropFirst().elementsEqual(parts.dropFirst())
                && alias.first.flatMap { IPv6Address(String($0)) } == address
        }
    }

    @MainActor
    func editor(selecting profile: Computer?, in library: ConnectionLibrary) -> EditorRequest? {
        guard let profile else { return editor(using: nil) }
        guard let current = profiles(in: library).first(where: { $0.id == profile.id }),
              current.hasSameDestination(as: profile) else { return nil }
        return editor(using: current)
    }

    @MainActor
    private func editor(using profile: Computer?) -> EditorRequest {
        let source = profile?.withDiscoveredPlatform(from: computer) ?? computer
        switch intent {
        case .connect(let quality):
            let connection = quality.map { source.connecting(with: $0, on: .current) } ?? source
            return EditorRequest(purpose: .connect, computer: connection, suggestedSSHPort: suggestedSSHPort,
                                 loadsStoredCredentials: profile != nil)
        case .save:
            return EditorRequest(purpose: source.saved ? .edit : .new, computer: source,
                                 suggestedSSHPort: suggestedSSHPort, loadsStoredCredentials: profile != nil)
        }
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
                Button(selection.intent.manualActionTitle, systemImage: "square.and.pencil") { select(nil) }
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
            if profile.endpoint != selection.computer.endpoint {
                Text(verbatim: profile.endpoint.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
