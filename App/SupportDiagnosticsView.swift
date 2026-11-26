import SwiftUI
import UniformTypeIdentifiers

struct SupportDiagnosticsView: View {
    @Environment(ConnectionLibrary.self) private var library
    @Environment(AppLock.self) private var privacy
    @State private var report: SupportDiagnostics?
    @State private var selected: ConnectionReport?
    @State private var export: DiagnosticsDocument?
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                Button {
                    do {
                        let snapshot = library.supportDiagnostics()
                        export = DiagnosticsDocument(data: try snapshot.encoded())
                        report = snapshot
                        exporting = true
                    } catch { exportError = error.localizedDescription }
                } label: {
                    Label("导出诊断报告", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("diagnostics.export")
            } footer: {
                Text("诊断记录保存在这台设备。导出的报告包含应用版本、系统版本和连接诊断。")
            }

            if let report {
                if report.connections.isEmpty && report.failures.isEmpty {
                    Section {
                        Text("暂无连接诊断").foregroundStyle(.secondary)
                            .accessibilityIdentifier("diagnostics.empty")
                    }
                }
                if !report.connections.isEmpty {
                    Section("最近的连接记录") {
                        ForEach(report.connections) { record in
                            Button { selected = record } label: {
                                LabeledContent {
                                    Text(record.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                } label: {
                                    Text(record.usesVideo ? "高性能屏幕共享" : "标准屏幕共享")
                                }
                            }
                            .accessibilityIdentifier("diagnostics.connection")
                        }
                    }
                }
                if !report.failures.isEmpty {
                    Section("最近的连接失败") {
                        ForEach(report.failures) { failure in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(failure.reason.title)
                                Text(failure.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("diagnostics.failure")
                        }
                    }
                }
            }
        }
        .accessibilityHidden(privacy.locked)
        .allowsHitTesting(!privacy.locked)
        .opacity(privacy.locked ? 0 : 1)
        .navigationTitle("连接诊断")
        .onAppear { report = library.supportDiagnostics() }
        .onChange(of: privacy.locked) { _, locked in
            if locked {
                selected = nil
                exporting = false
                export = nil
            } else { report = library.supportDiagnostics() }
        }
        .sheet(item: $selected) { ConnectionDetails(report: $0, historical: true) }
        .fileExporter(isPresented: $exporting, document: export, contentTypes: [.json],
                      defaultFilename: "Telescope-Diagnostics", onCompletion: { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
            export = nil
        }, onCancellation: { export = nil })
        .alert("无法导出诊断报告", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(verbatim: exportError ?? "")
        }
    }
}

private struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes = [UTType.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension SupportDiagnostics.Failure.Reason {
    var title: LocalizedStringKey {
        switch self {
        case .authentication: "认证失败"
        case .unsupportedVersion: "不支持此协议版本"
        case .unsupportedEncoding: "不支持此画面编码"
        case .protocolError: "协议错误"
        case .closed: "连接已关闭"
        case .timeout: "连接超时"
        case .transport: "传输错误"
        case .unknown: "连接失败"
        }
    }
}
