import Foundation
import SwiftData
import ssshCore

/// Host-key trust, backed by SwiftData.
///
/// `ModelContext` is not `Sendable` and the transport calls this from a network
/// thread, so every access hops to the main actor and uses the main context.
/// That is deliberate rather than lazy: known-hosts lookups happen once per
/// connection and touch a handful of rows, so there is nothing to gain from a
/// background context and a real risk of two contexts disagreeing about who is
/// trusted.
final class SwiftDataKnownHostsStore: SSHKnownHostsStore, @unchecked Sendable {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func trustedKeys(for endpoint: SSHEndpoint) async -> [SSHHostKey] {
        let key = endpoint.knownHostsKey
        return await MainActor.run {
            let context = container.mainContext
            let descriptor = FetchDescriptor<KnownHostEntry>(
                predicate: #Predicate { $0.hostKey == key }
            )
            let entries = (try? context.fetch(descriptor)) ?? []
            return entries.compactMap(\.sshHostKey)
        }
    }

    func remember(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws {
        let hostKey = endpoint.knownHostsKey
        let algorithm = key.algorithm

        try await MainActor.run {
            let context = container.mainContext

            // A host offers one key per algorithm, so replacing means replacing
            // the entry for *this* algorithm — not every entry for the host.
            let descriptor = FetchDescriptor<KnownHostEntry>(
                predicate: #Predicate { $0.hostKey == hostKey && $0.algorithm == algorithm }
            )
            let existing = (try? context.fetch(descriptor)) ?? []
            let replacedFingerprint = existing.first?.sha256Fingerprint
            for entry in existing {
                context.delete(entry)
            }

            let entry = KnownHostEntry(endpoint: endpoint, key: key)
            // Keeping what it replaced lets the UI say "this changed" later
            // rather than quietly forgetting that it ever did.
            entry.replacedKeyFingerprint = replacedFingerprint
            context.insert(entry)
            try context.save()
        }
    }

    func forget(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws {
        let hostKey = endpoint.knownHostsKey
        let algorithm = key.algorithm

        try await MainActor.run {
            let context = container.mainContext
            let descriptor = FetchDescriptor<KnownHostEntry>(
                predicate: #Predicate { $0.hostKey == hostKey && $0.algorithm == algorithm }
            )
            for entry in (try? context.fetch(descriptor)) ?? [] {
                context.delete(entry)
            }
            try context.save()
        }
    }
}
