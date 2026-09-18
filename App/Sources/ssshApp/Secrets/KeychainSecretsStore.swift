import Foundation
import Security
import ssshCore

/// Where a secret lives.
///
/// The two are genuinely different, and the difference cannot be hidden:
///
/// - **`.thisDeviceOnly`** wraps the payload with the device key — Secure
///   Enclave where there is one — and marks the item `ThisDeviceOnly`. It
///   cannot leave, and a copy of the Keychain database is useless without the
///   hardware that made the key.
/// - **`.iCloudKeychain`** cannot be wrapped, because the device key is
///   device-bound and would not be there to unwrap it on the other machine.
///   The protection is iCloud Keychain's own end-to-end encryption, which is
///   real but is Apple's rather than ours.
///
/// Nothing ever goes into the app's CloudKit database. That is where host
/// names, fingerprints, tunnels and snippets sync; it is not end-to-end
/// encrypted, and a private key in it would be a private key in a database
/// Apple can read.
enum SecretStorageScope: String, Sendable, CaseIterable {
    case thisDeviceOnly
    case iCloudKeychain
}

/// The Keychain-backed secrets store.
///
/// ## Choices worth knowing about
///
/// - **`WhenUnlocked`, not `AfterFirstUnlock`.** A background reconnect cannot
///   read a password while the device is locked. That is the point: an SSH
///   session should not be establishable with the phone in someone else's
///   pocket.
/// - **One generic-password item per reference**, with the payload as JSON in
///   the secret data. Key material and passphrase travel together because they
///   are useless apart, and a half-migrated pair would be worse than neither.
/// - **Reads look in both scopes.** A secret stored before sync was turned on
///   must still open afterwards, and vice versa; a store that only looked
///   where it currently prefers would lose keys on a settings change.
actor KeychainSecretsStore: SecretsStore {
    private let service: String
    private let appKey: AppSecurityKey
    /// Where new secrets go. Existing ones are found wherever they are.
    private var scope: SecretStorageScope

    init(
        service: String = "nl.rorymeijer.sssh.secrets",
        appKey: AppSecurityKey = AppSecurityKey(),
        scope: SecretStorageScope = .thisDeviceOnly
    ) {
        self.service = service
        self.appKey = appKey
        self.scope = scope
    }

    enum Failure: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case corruptPayload

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            case .corruptPayload:
                return "The stored secret could not be read."
            }
        }
    }

    // MARK: - SecretsStore

    func store(_ secret: Secret, for reference: SecretReference) async throws {
        try await store(secret, for: reference, in: scope)
    }

    private func store(_ secret: Secret, for reference: SecretReference, in scope: SecretStorageScope) async throws {
        let payload = try await encode(secret, for: scope)

        var query = baseQuery(for: reference, scope: scope)
        query[kSecValueData as String] = payload
        query[kSecAttrAccessible as String] = scope == .thisDeviceOnly
            ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            // `ThisDeviceOnly` and synchronisable are contradictory, and the
            // Keychain refuses the combination rather than quietly picking one.
            : kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Replacing rather than failing: the caller asked for this
            // reference to hold this secret, and an edit is the common path.
            let update = [kSecValueData as String: payload] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery(for: reference, scope: scope) as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw Failure.unexpectedStatus(updateStatus)
            }
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    func secret(for reference: SecretReference) async throws -> Secret? {
        // Preferred scope first, then the other one. A secret stored before a
        // settings change has to keep opening afterwards.
        for candidate in [scope] + SecretStorageScope.allCases.filter({ $0 != scope }) {
            guard let data = try read(reference, scope: candidate) else { continue }
            return try await decode(data)
        }
        return nil
    }

    func delete(_ reference: SecretReference) async throws {
        // Both scopes: a reference is gone when it is gone everywhere, and a
        // copy left behind in the other one is a secret the user believes they
        // deleted.
        for candidate in SecretStorageScope.allCases {
            let status = SecItemDelete(baseQuery(for: reference, scope: candidate) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.unexpectedStatus(status)
            }
        }
    }

    func allReferences() async throws -> [SecretReference] {
        var seen = Set<String>()
        var result: [SecretReference] = []
        for candidate in SecretStorageScope.allCases {
            for raw in try accounts(in: candidate) where seen.insert(raw).inserted {
                result.append(SecretReference(rawValue: raw))
            }
        }
        return result
    }

    // MARK: - Sync

    /// Moves every stored secret to `newScope` and makes it the destination
    /// for new ones.
    ///
    /// Each secret is written to the new scope *before* the old copy is
    /// removed. An interruption then leaves a duplicate, which reads fine and
    /// is cleaned up by the next pass; the other order leaves nothing at all,
    /// which loses a key.
    func setScope(_ newScope: SecretStorageScope) async throws {
        guard newScope != scope else { return }
        let previous = scope
        scope = newScope

        for reference in try await allReferences() {
            guard let data = try read(reference, scope: previous) else { continue }
            let secret = try await decode(data)
            try await store(secret, for: reference, in: newScope)
            let status = SecItemDelete(baseQuery(for: reference, scope: previous) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.unexpectedStatus(status)
            }
        }
    }

    var currentScope: SecretStorageScope { scope }

    // MARK: - Payload

    private func encode(_ secret: Secret, for scope: SecretStorageScope) async throws -> Data {
        let plaintext = try JSONEncoder().encode(StoredSecret(secret))
        switch scope {
        case .thisDeviceOnly:
            let sealed = try await appKey.seal(plaintext)
            return try JSONEncoder().encode(Envelope(sealed: sealed))
        case .iCloudKeychain:
            // Not sealed, and it cannot be: the device key is device-bound, so
            // the other machine would have nothing to open it with. iCloud
            // Keychain's own end-to-end encryption is the protection here.
            return try JSONEncoder().encode(Envelope(plaintext: plaintext))
        }
    }

    private func decode(_ data: Data) async throws -> Secret {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.corruptPayload
        }
        let plaintext: Data
        if let sealed = envelope.sealed {
            plaintext = try await appKey.open(sealed)
        } else if let raw = envelope.plaintext {
            plaintext = raw
        } else {
            throw Failure.corruptPayload
        }
        guard let stored = try? JSONDecoder().decode(StoredSecret.self, from: plaintext) else {
            throw Failure.corruptPayload
        }
        return stored.secret
    }

    // MARK: - Keychain plumbing

    private func read(_ reference: SecretReference, scope: SecretStorageScope) throws -> Data? {
        var query = baseQuery(for: reference, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.corruptPayload }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    private func accounts(in scope: SecretStorageScope) throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: scope == .iCloudKeychain,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            return (items as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    private func baseQuery(for reference: SecretReference, scope: SecretStorageScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
            // Not optional. Left out, a query matches items of either kind and
            // the two scopes become indistinguishable — which is how a
            // "device only" secret ends up being updated in iCloud.
            kSecAttrSynchronizable as String: scope == .iCloudKeychain,
        ]
    }
}

/// What actually sits in the Keychain item: either a sealed blob or the
/// plaintext JSON, never both.
private struct Envelope: Codable {
    var sealed: Data?
    var plaintext: Data?

    init(sealed: Data) {
        self.sealed = sealed
        self.plaintext = nil
    }

    init(plaintext: Data) {
        self.sealed = nil
        self.plaintext = plaintext
    }
}

/// The on-disk shape of a stored secret.
///
/// Explicit `Codable` rather than a synthesised conformance on ``Secret``:
/// `SecretString` deliberately has no `Codable`, so that nothing can be
/// serialised into a log, a crash report or the synced store by accident. The
/// one place that genuinely must serialise a secret is here, and it is
/// conspicuous.
private struct StoredSecret: Codable {
    enum Kind: String, Codable {
        case password
        case privateKey
    }

    var kind: Kind
    var value: String
    var passphrase: String?

    init(_ secret: Secret) {
        switch secret {
        case .password(let password):
            kind = .password
            value = password.reveal()
            passphrase = nil
        case .privateKey(let openSSH, let phrase):
            kind = .privateKey
            value = openSSH.reveal()
            passphrase = phrase?.reveal()
        }
    }

    var secret: Secret {
        switch kind {
        case .password:
            return .password(SecretString(value))
        case .privateKey:
            return .privateKey(openSSH: SecretString(value), passphrase: passphrase.map(SecretString.init(_:)))
        }
    }
}
