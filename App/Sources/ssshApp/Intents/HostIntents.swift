import AppIntents
import Foundation
import SwiftData

/// A saved host, as Shortcuts, Siri and Spotlight see it.
///
/// Snippets deliberately have no intent: a `Snippet` record has no identifier
/// that survives launches and devices, and an id that goes stale breaks every
/// shortcut built on it. The host's connection triple is the one identity in
/// the model that is durable by construction.
struct HostEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Host")
    static let defaultQuery = HostEntityQuery()

    /// ``Host/restoreIdentifier`` — `user@hostname:port`. A SwiftData
    /// `PersistentIdentifier` is stable across neither launches nor devices,
    /// and this id is persisted into saved shortcuts on both.
    var id: String
    @Property(title: "Naam")
    var name: String

    /// For the picker row; plain `var`, it only feeds the display.
    var connection: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(connection)")
    }

    @MainActor
    init(host: Host) {
        // The plain properties first: `name` is behind the @Property wrapper,
        // whose storage already has a value, so assigning it is a mutation of
        // `self` — legal only once everything else is initialized.
        self.id = host.restoreIdentifier
        self.connection = "\(host.username)@\(host.hostname)"
        self.name = host.displayName
    }
}

struct HostEntityQuery: EntityStringQuery {
    @Dependency private var environment: AppEnvironment

    func entities(for identifiers: [String]) async throws -> [HostEntity] {
        await MainActor.run {
            let wanted = Set(identifiers)
            return Self.connectableHosts(in: environment)
                .filter { wanted.contains($0.restoreIdentifier) }
                .map(HostEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [HostEntity] {
        await MainActor.run {
            Self.connectableHosts(in: environment)
                .filter {
                    $0.displayName.localizedCaseInsensitiveContains(string)
                        || $0.hostname.localizedCaseInsensitiveContains(string)
                }
                .map(HostEntity.init)
        }
    }

    func suggestedEntities() async throws -> [HostEntity] {
        await MainActor.run {
            Self.connectableHosts(in: environment).prefix(10).map(HostEntity.init)
        }
    }

    @MainActor
    private static func connectableHosts(in environment: AppEnvironment) -> [Host] {
        let hosts = (try? environment.modelContainer.mainContext.fetch(
            FetchDescriptor<Host>(sortBy: [SortDescriptor(\Host.lastConnectedAt, order: .reverse)])
        )) ?? []
        return hosts.filter(\.isConnectable)
    }
}

struct ConnectToHostIntent: AppIntent {
    static let title: LocalizedStringResource = "Verbind met host"
    static let description = IntentDescription("Opent een nieuwe terminalsessie naar een opgeslagen host.")
    /// The point of the intent is a terminal you can see, so the app comes to
    /// the foreground. Authentication prompts also need somewhere to appear.
    static let openAppWhenRun = true

    @Parameter(title: "Host")
    var host: HostEntity

    @Dependency private var environment: AppEnvironment

    @MainActor
    func perform() async throws -> some IntentResult {
        let hosts = (try? environment.modelContainer.mainContext.fetch(FetchDescriptor<Host>())) ?? []
        guard let match = hosts.first(where: { $0.restoreIdentifier == host.id && $0.isConnectable }) else {
            throw HostIntentError.hostNotFound
        }
        environment.sessions.open(match)
        return .result()
    }
}

enum HostIntentError: Error, CustomLocalizedStringResourceConvertible {
    case hostNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .hostNotFound:
            return "Deze host bestaat niet meer in sssH."
        }
    }
}

struct ssshShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToHostIntent(),
            phrases: [
                "Verbind met \(\.$host) in \(.applicationName)",
                "Connect to \(\.$host) in \(.applicationName)",
            ],
            shortTitle: "Verbind",
            systemImageName: "terminal"
        )
    }
}
