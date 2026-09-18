import SwiftData
import SwiftUI

/// The sidebar: saved hosts, searchable, with quick-connect.
///
/// Groups and tags get their own structure in Phase 6; for now hosts are shown
/// flat with their group as a subtitle, which is honest about what exists
/// rather than pretending at a hierarchy that cannot yet be edited.
struct HostListView: View {
    @Binding var selection: Host?
    let onConnect: (Host) -> Void
    let onEdit: (Host) -> Void
    let onCreate: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Host.name), SortDescriptor(\Host.hostname)])
    private var hosts: [Host]
    @State private var searchText = ""

    var body: some View {
        List(selection: $selection) {
            if filteredHosts.isEmpty {
                emptyState
            } else {
                ForEach(filteredHosts) { host in
                    HostRow(host: host)
                        .tag(host)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onConnect(host) }
                        .contextMenu {
                            Button {
                                onConnect(host)
                            } label: {
                                Label {
                                    Text("Verbinden", comment: "Context menu: open a connection to this host")
                                } icon: {
                                    Image(systemName: "bolt.horizontal")
                                }
                            }
                            Button {
                                onEdit(host)
                            } label: {
                                Label {
                                    Text("Bewerken", comment: "Context menu: edit this host's settings")
                                } icon: {
                                    Image(systemName: "pencil")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                delete(host)
                            } label: {
                                Label {
                                    Text("Verwijderen", comment: "Context menu: delete this host")
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                }
                .onDelete(perform: deleteAt)
            }
        }
        .searchable(
            text: $searchText,
            prompt: Text("Zoek hosts", comment: "Placeholder in the host search field")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onCreate) {
                    Label {
                        Text("Nieuwe host", comment: "Toolbar button: add a new host")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var filteredHosts: [Host] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return hosts }

        // Matching the tags and the group as well as the name is what makes
        // search usable once there are more than a handful of hosts.
        return hosts.filter { host in
            host.name.lowercased().contains(query)
                || host.hostname.lowercased().contains(query)
                || host.username.lowercased().contains(query)
                || host.tags.contains { $0.lowercased().contains(query) }
                || (host.group?.name.lowercased().contains(query) ?? false)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("Nog geen hosts", comment: "Empty state title when no hosts are saved")
                } icon: {
                    Image(systemName: "server.rack")
                }
            } description: {
                Text("Voeg een host toe om een verbinding te maken.",
                     comment: "Empty state body when no hosts are saved")
            } actions: {
                Button(action: onCreate) {
                    Text("Nieuwe host", comment: "Button in the empty state that adds a host")
                }
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func deleteAt(_ offsets: IndexSet) {
        for index in offsets {
            delete(filteredHosts[index])
        }
    }

    private func delete(_ host: Host) {
        if selection == host { selection = nil }
        modelContext.delete(host)
        // Note: the host's Keychain secret is intentionally left alone here.
        // Reaping orphaned secrets is a single reconciliation pass against
        // `allReferences()`, which is safer than deleting on every edit where a
        // half-finished change could take a still-referenced secret with it.
        try? modelContext.save()
    }
}

private struct HostRow: View {
    let host: Host

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !host.tags.isEmpty {
                Text(host.tags.first ?? "")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(Text("Label: \(host.tags.first ?? "")",
                                             comment: "Accessibility label for a host's tag chip"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !host.username.isEmpty { parts.append(host.username) }
        parts.append(host.port == 22 ? host.hostname : "\(host.hostname):\(host.port)")
        if let group = host.group?.name, !group.isEmpty { parts.append(group) }
        return parts.joined(separator: " · ")
    }
}
