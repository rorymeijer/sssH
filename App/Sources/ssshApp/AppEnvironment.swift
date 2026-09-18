import Foundation
import Observation
import SwiftData
import ssshCore
import ssshTransportNIOSSH

/// Wires the app together.
///
/// This is the only type that names a concrete SSH backend
/// (`NIOSSHTransportFactory`) or a concrete secrets store
/// (`KeychainSecretsStore`). Everything else takes the protocol, which is what
/// makes the transport swappable and the session layer testable.
@MainActor
@Observable
final class AppEnvironment {
    let modelContainer: ModelContainer
    let sessions: SessionManager
    /// Shared so the host editor writes to the same store the session layer
    /// reads from, rather than each making its own.
    let secretsStore: any SecretsStore
    let hostKeyPrompts: HostKeyPromptCoordinator
    let credentialPrompts: CredentialPromptCoordinator

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        let hostKeyPrompts = HostKeyPromptCoordinator()
        let credentialPrompts = CredentialPromptCoordinator()
        self.hostKeyPrompts = hostKeyPrompts
        self.credentialPrompts = credentialPrompts

        let secretsStore = KeychainSecretsStore()
        self.secretsStore = secretsStore

        self.sessions = SessionManager(
            transportFactory: NIOSSHTransportFactory(),
            secretsStore: secretsStore,
            knownHosts: SwiftDataKnownHostsStore(container: modelContainer),
            hostKeyPrompts: hostKeyPrompts,
            credentialPrompts: credentialPrompts
        )
    }

    /// In-memory everything, for previews and tests. Named so that using it by
    /// accident is obvious in a diff.
    static func ephemeral() -> AppEnvironment {
        let container = try! ModelContainer(
            for: Host.self, HostGroup.self, KnownHostEntry.self, TerminalProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AppEnvironment(modelContainer: container)
    }
}

enum ModelContainerFactory {
    /// The app's real store.
    ///
    /// No CloudKit yet — that is Phase 7 — but the schema is already written to
    /// CloudKit's rules (every attribute defaulted, no unique constraints) so
    /// turning it on will not need a migration.
    static func make() throws -> ModelContainer {
        try ModelContainer(
            for: Host.self, HostGroup.self, KnownHostEntry.self, TerminalProfile.self,
            configurations: ModelConfiguration("sssh")
        )
    }
}
