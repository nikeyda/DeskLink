import Security
import SwiftUI
import UniformTypeIdentifiers

struct SSHKeyImportFields: View {
    @Binding var key: String?
    @Binding var pending: Bool
    var onSelection: (String?) -> Void
    var onError: (String?) -> Void
    @State private var choosing = false
    @State private var encrypted: String?
    @State private var passphrase = ""
    @State private var opening = false

    var body: some View {
        Button { choosing = true } label: {
            Label("选择密钥文件", systemImage: key == nil ? "key" : "checkmark.circle")
        }.disabled(opening)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { selection in
            do {
                let url = try selection.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1024 * 1024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                read(try String(contentsOf: url, encoding: .utf8), filename: url.lastPathComponent)
            } catch let error as CocoaError where error.code == .userCancelled {
            } catch { onError(error.localizedDescription) }
        }
        PasteButton(payloadType: String.self) { values in
            if let text = values.first { read(text, filename: nil) }
        }
        .accessibilityLabel("粘贴 SSH 密钥")
        .disabled(opening)
        if encrypted != nil {
            SecureField("密钥口令", text: $passphrase).textContentType(.password)
            Button("解锁密钥", action: unlock).disabled(passphrase.isEmpty || opening)
            if opening { ProgressView() }
        }
    }

    private func read(_ text: String, filename: String?) {
        key = nil
        encrypted = nil
        passphrase = ""
        pending = false
        onSelection(filename)
        onError(nil)
        do {
            guard text.utf8.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            key = try SSHKeyFile.opened(text)
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == Int(errSecPassphraseRequired) {
            encrypted = text
            pending = true
        } catch { onError(error.localizedDescription) }
    }

    private func unlock() {
        guard let selected = encrypted, !passphrase.isEmpty, !opening else { return }
        let secret = passphrase
        opening = true
        Task { @MainActor in
            defer { opening = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyFile.opened(selected, passphrase: secret)
                }.value
                guard encrypted == selected else { return }
                key = result
                encrypted = nil
                passphrase = ""
                pending = false
                onError(nil)
            } catch { onError(error.localizedDescription) }
        }
    }
}

struct SSHKeyPreferences: View {
    @AppStorage("credentials.synchronize") private var synchronize = false
    @State private var names: [String] = []
    @State private var importing = false
    @State private var removing: String?
    @State private var error: String?

    var body: some View {
        List {
            if names.isEmpty { Text("尚未添加密钥").foregroundStyle(.secondary) }
            ForEach(names, id: \.self) { name in
                HStack {
                    Label(name, systemImage: "key")
                    Spacer()
                    Button(role: .destructive) { removing = name } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("删除密钥 " + name)
                }
            }
            Button("添加密钥") { importing = true }.accessibilityIdentifier("keys.add")
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("SSH 密钥")
        .onAppear(perform: refresh)
        .sheet(isPresented: $importing, onDismiss: refresh) { AddSSHKey(synchronize: synchronize) }
        .alert("删除 SSH 密钥", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { name in
            Button("删除", role: .destructive) {
                do { try PasswordStore.removeNamedKey(name, synchronize: synchronize); refresh() }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { name in Text("使用「\(name)」的连接将需要重新选择密钥。") }
    }

    private func refresh() {
        do { names = try PasswordStore.keyNames(synchronize: synchronize); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct AddSSHKey: View {
    let synchronize: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key: String?
    @State private var pending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("密钥名称", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                SSHKeyImportFields(key: $key, pending: $pending, onSelection: { filename in
                    if name.isEmpty, let filename { name = filename }
                }, onError: { error = $0 })
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("添加 SSH 密钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let key else { return }
                        do {
                            try PasswordStore.addNamedKey(key, name: name.trimmingCharacters(in: .whitespacesAndNewlines), synchronize: synchronize)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key == nil || pending)
                }
            }
        }
    }
}
