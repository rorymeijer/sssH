import Foundation
import SwiftData
import ssshCore

/// A saved connection.
///
/// ## Why every property has a default
///
/// CloudKit's private database is added in Phase 7, and `NSPersistentCloudKitContainer`
/// refuses a model with non-optional attributes that have no default, or with
/// unique constraints. Designing to those rules now costs nothing and avoids a
/// schema migration on every existing user's device later.
///
/// ## What is deliberately absent
///
/// No password, no private key, no passphrase. `secretReference` is an opaque
/// identifier into the Keychain; this record can sync freely because it carries
/// nothing worth stealing.
@Model
final class Host {
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""

    /// How to authenticate. Stored as a raw value so the enum can gain cases
    /// without a migration.
    var authenticationMethodRaw: String = HostAuthenticationMethod.askEveryTime.rawValue

    /// Opaque handle into the secrets store. `nil` means "ask every time".
    var secretReferenceRaw: String?

    var group: HostGroup?
    var tags: [String] = []
    /// A colour label, as a name rather than an RGB value, so it follows the
    /// system appearance instead of fighting it.
    var colorName: String?

    /// `ProxyJump`. A self-reference: a bastion is just another saved host.
    var jumpHost: Host?

    var startupCommand: String?
    /// Sent as `env` requests. Most servers ignore anything outside `AcceptEnv`.
    var environment: [String: String] = [:]

    var keepAliveIntervalSeconds: Int = 30
    var terminalProfile: TerminalProfile?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// For "recent hosts" and quick-connect ordering.
    var lastConnectedAt: Date?

    init(
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authenticationMethod: HostAuthenticationMethod = .askEveryTime,
        secretReference: SecretReference? = nil
    ) {
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authenticationMethodRaw = authenticationMethod.rawValue
        self.secretReferenceRaw = secretReference?.rawValue
    }
}

extension Host {
    var authenticationMethod: HostAuthenticationMethod {
        get { HostAuthenticationMethod(rawValue: authenticationMethodRaw) ?? .askEveryTime }
        set { authenticationMethodRaw = newValue.rawValue }
    }

    var secretReference: SecretReference? {
        get { secretReferenceRaw.map(SecretReference.init(rawValue:)) }
        set { secretReferenceRaw = newValue?.rawValue }
    }

    var endpoint: SSHEndpoint {
        SSHEndpoint(hostname: hostname, port: port)
    }

    /// What to show in the sidebar when the user has not named the host.
    var displayName: String {
        if !name.isEmpty { return name }
        if username.isEmpty { return hostname }
        return "\(username)@\(hostname)"
    }

    /// Whether this host has enough filled in to attempt a connection.
    var isConnectable: Bool {
        !hostname.isEmpty && !username.isEmpty && (1...65535).contains(port)
    }

    /// Builds the transport's destination, resolving the jump-host chain.
    ///
    /// - Parameters:
    ///   - credentials: this host's own credentials, already resolved. Passed
    ///     in rather than looked up here so that a prompt happens exactly once
    ///     — resolving them inside would ask the user twice for the same
    ///     password.
    ///   - resolveJumpCredentials: called once per bastion, because each hop
    ///     authenticates separately.
    func destination(
        credentials: [SSHCredential],
        resolveJumpCredentials: (Host) async -> [SSHCredential]
    ) async -> SSHDestination {
        var chain: [SSHDestination] = []

        // Walk outwards, guarding against a cycle: a host set as its own
        // bastion, directly or through a loop, would otherwise hang here rather
        // than failing.
        var visited: Set<PersistentIdentifier> = [persistentModelID]
        var hop = jumpHost
        while let current = hop, !visited.contains(current.persistentModelID) {
            visited.insert(current.persistentModelID)
            chain.append(SSHDestination(
                endpoint: current.endpoint,
                username: current.username,
                credentials: await resolveJumpCredentials(current),
                environment: current.environment,
                keepAlive: current.keepAlivePolicy
            ))
            hop = current.jumpHost
        }

        // `jumpHosts[0]` is dialled directly, so the outermost bastion — the
        // last one found walking the chain — comes first.
        return SSHDestination(
            endpoint: endpoint,
            username: username,
            credentials: credentials,
            jumpHosts: chain.reversed(),
            environment: environment,
            keepAlive: keepAlivePolicy
        )
    }

    var keepAlivePolicy: SSHKeepAlivePolicy {
        guard keepAliveIntervalSeconds > 0 else { return .disabled }
        return SSHKeepAlivePolicy(
            interval: .seconds(keepAliveIntervalSeconds),
            timeout: .seconds(15),
            missedProbesBeforeDisconnect: 3
        )
    }
}

enum HostAuthenticationMethod: String, CaseIterable, Sendable {
    case password
    case privateKey
    /// Nothing stored: prompt at connection time and keep it only for the
    /// lifetime of the session.
    case askEveryTime
}
