import Foundation

/// One host as the widget shows it: a name, a connection string and the
/// durable identifier a tap sends back to the app.
///
/// This file is compiled into both the app and the widget extension. The
/// widget deliberately does not read the SwiftData store — sharing that store
/// would mean moving it into the app group container, a migration of every
/// existing installation for the sake of four table rows. The app writes this
/// snapshot instead, and the widget only ever reads.
struct HostSnapshotItem: Codable, Identifiable, Hashable {
    /// `Host.restoreIdentifier` — `user@hostname:port`. The same identifier
    /// the App Intents use, for the same reason: it survives launches, sync
    /// and reinstalls, where a database row id does not.
    var id: String
    var name: String
    var connection: String
}

enum HostSnapshotStore {
    /// Team-prefixed on macOS: `group.*` identifiers there require a
    /// provisioning profile, and the release flow signs with Developer ID and
    /// an existing profile. iOS uses the conventional `group.*` form, which
    /// automatic signing registers on its own.
    static var appGroupID: String {
        #if os(macOS)
        "GPYS6SK835.nl.rorymeijer.sssh"
        #else
        "group.nl.rorymeijer.sssh"
        #endif
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("recent-hosts.json")
    }

    /// The scheme the widget uses to ask the app to connect.
    static func connectURL(for item: HostSnapshotItem) -> URL? {
        var components = URLComponents()
        components.scheme = "sssh"
        components.host = "connect"
        components.queryItems = [URLQueryItem(name: "id", value: item.id)]
        return components.url
    }

    static func hostID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "sssh", url.host?.lowercased() == "connect" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "id" }?
            .value
    }

    static func save(_ items: [HostSnapshotItem]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(items) else { return }
        // Atomic, because the widget can read at any moment and a torn file
        // would show an empty widget until the next write.
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> [HostSnapshotItem] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HostSnapshotItem].self, from: data)) ?? []
    }
}
