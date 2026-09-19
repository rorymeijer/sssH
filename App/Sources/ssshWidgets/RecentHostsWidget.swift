import SwiftUI
import WidgetKit

@main
struct ssshWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentHostsWidget()
    }
}

struct RecentHostsEntry: TimelineEntry {
    let date: Date
    let hosts: [HostSnapshotItem]
}

/// The app writes the snapshot and asks for a reload when it changes, so the
/// timeline itself never expires: `.never` rather than polling a file that
/// only moves when the app says so.
struct RecentHostsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentHostsEntry {
        RecentHostsEntry(date: .now, hosts: [
            HostSnapshotItem(id: "demo@web:22", name: "webserver", connection: "demo@web"),
            HostSnapshotItem(id: "demo@db:22", name: "database", connection: "demo@db"),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentHostsEntry) -> Void) {
        completion(RecentHostsEntry(date: .now, hosts: HostSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentHostsEntry>) -> Void) {
        completion(Timeline(entries: [RecentHostsEntry(date: .now, hosts: HostSnapshotStore.load())], policy: .never))
    }
}

struct RecentHostsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentHosts", provider: RecentHostsProvider()) { entry in
            RecentHostsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text("Recente hosts", comment: "Display name of the recent-hosts widget"))
        .description(Text("Verbind met één tik met een recente host.", comment: "Description of the recent-hosts widget"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RecentHostsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentHostsEntry

    /// Small fits two rows, medium four. More is a list, and lists have an
    /// app for them.
    private var visibleHosts: [HostSnapshotItem] {
        Array(entry.hosts.prefix(family == .systemSmall ? 2 : 4))
    }

    var body: some View {
        if visibleHosts.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Geen opgeslagen hosts", comment: "Menu bar item shown when there are no connectable hosts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleHosts) { host in
                    row(host)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func row(_ host: HostSnapshotItem) -> some View {
        if let url = HostSnapshotStore.connectURL(for: host) {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: host.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if family != .systemSmall {
                            Text(verbatim: host.connection)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
