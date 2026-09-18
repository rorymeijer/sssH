import Foundation

/// Stores the things that must never reach the synced model.
///
/// The synced `Host` record holds an opaque ``SecretReference`` and nothing
/// else; this resolves it to a password, a private key or a passphrase at the
/// moment a connection is made, and the resolved value is dropped as soon as
/// the handshake finishes.
///
/// Declared here, next to ``SecretString``, so the session layer can depend on
/// the idea of a secrets store without depending on Keychain — which is what
/// lets it be tested, and what would let a future Linux build substitute
/// something else.
public protocol SecretsStore: Sendable {
    func store(_ secret: Secret, for reference: SecretReference) async throws
    func secret(for reference: SecretReference) async throws -> Secret?
    func delete(_ reference: SecretReference) async throws
    /// References the store holds, for reconciling against the model and
    /// deleting orphans.
    func allReferences() async throws -> [SecretReference]
}

/// An opaque handle to a secret. Safe to store in SwiftData and to sync: it
/// identifies a secret without being one.
public struct SecretReference: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func makeUnique() -> SecretReference {
        SecretReference(rawValue: UUID().uuidString)
    }
}

/// What a reference can resolve to.
public enum Secret: Sendable {
    case password(SecretString)
    case privateKey(openSSH: SecretString, passphrase: SecretString?)
}

extension Secret {
    /// Turns a stored secret into the credentials to offer, in order.
    ///
    /// A key with a passphrase is offered as one credential; sssh does not fall
    /// back to trying it without, because that only ever produces a confusing
    /// second failure.
    public func credentials() -> [SSHCredential] {
        switch self {
        case .password(let password):
            return [.password(password)]
        case .privateKey(let openSSH, let passphrase):
            return [.privateKey(SSHPrivateKeyMaterial(
                openSSHPrivateKey: openSSH,
                passphrase: passphrase
            ))]
        }
    }
}

/// A store that keeps nothing beyond the process.
///
/// For tests and previews. Using it in the app would be a bug, which is why it
/// says so in its name rather than being the default.
public actor InMemorySecretsStore: SecretsStore {
    private var secrets: [SecretReference: Secret] = [:]

    public init() {}

    public func store(_ secret: Secret, for reference: SecretReference) async throws {
        secrets[reference] = secret
    }

    public func secret(for reference: SecretReference) async throws -> Secret? {
        secrets[reference]
    }

    public func delete(_ reference: SecretReference) async throws {
        secrets[reference] = nil
    }

    public func allReferences() async throws -> [SecretReference] {
        Array(secrets.keys)
    }
}
