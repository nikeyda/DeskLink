import AppIntents
import SwiftUI
import WidgetKit

struct WidgetSelection: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "快速连接"
    @Parameter(title: "已存储的电脑") var computer: ComputerEntity?
    @Parameter(title: "输入地址") var address: String?
    @Parameter(title: "名称") var name: String?
}

struct ConnectionEntry: TimelineEntry {
    var date = Date()
    var title = "快速连接"
    var address: String?
    var url = ConnectionRoute.quickURL
}

struct ConnectionsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ConnectionEntry { ConnectionEntry() }
    func snapshot(for configuration: WidgetSelection, in context: Context) async -> ConnectionEntry { entry(configuration) }
    func timeline(for configuration: WidgetSelection, in context: Context) async -> Timeline<ConnectionEntry> {
        Timeline(entries: [entry(configuration)], policy: .never)
    }

    private func entry(_ configuration: WidgetSelection) -> ConnectionEntry {
        if let selected = configuration.computer {
            guard let current = WidgetCatalog.read().first(where: { $0.id == selected.id }) else { return ConnectionEntry() }
            return ConnectionEntry(title: current.name, address: current.address, url: ConnectionRoute.savedURL(current.id))
        }
        guard let input = configuration.address, let endpoint = try? Endpoint(address: input),
              let url = URL(string: "desklink://" + endpoint.address) else { return ConnectionEntry() }
        let name = configuration.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionEntry(title: name.flatMap { $0.isEmpty ? nil : $0 } ?? endpoint.host, address: endpoint.address, url: url)
    }
}

@main
struct ConnectionWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetCatalog.kind, intent: WidgetSelection.self, provider: ConnectionsProvider()) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "desktopcomputer").font(.title).foregroundStyle(.tint).accessibilityHidden(true)
                Spacer()
                Text(entry.title).font(.headline).lineLimit(2).privacySensitive()
                if let address = entry.address, address != entry.title {
                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(entry.url)
        }
        .configurationDisplayName("快速连接")
        .description("连接到电脑")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
