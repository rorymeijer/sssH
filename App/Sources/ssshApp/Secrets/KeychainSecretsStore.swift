import Foundation
import Security
import ssshCore

/// The Keychain-backed secrets store.
///
/// ## Choices worth knowing about
///
/// - **`ThisDeviceOnly` accessibility.** Secrets do not leave the device, which
///   is §7's default. Opt-in sync (Phase 7) will move to iCloud Keychain by
///   setting `kSecAttrSynchronizable` — never by putting anything in the app's
///   CloudKit database.
/// - **`WhenUnlocked`, not `AfterFirstUnlock`.** A background reconnect cannot
///   read a password while the device is locked. That is the point: an SSH
///   session should not be establishable with the phone in someone else's
///   pocket.
/// - **One generic-password item per reference**, with the payload as JSON in
///   the secret data. Key material and passphrase travel together because they
///   are useless apart, and a half-migrated pair would be worse than neither.
actor KeychainSecretsStore: SecretsStore {
    private let service: String

    init(service: String = "nl.rorymeijer.sssh.secrets") {
        self.service = service
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
        let payload = try JSONEncoder().encode(StoredSecret(secret))

        var query = baseQuery(for: reference)
        query[kSecValueData as String] = payload
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Replacing rather than failing: the caller asked for this
            // reference to hold this secret, and an edit is the common path.
            let update = [kSecValueData as String: payload] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery(for: reference) as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw Failure.unexpectedStatus(updateStatus)
            }
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    func secret(for reference: SecretReference) async throws -> Secret? {
        var query = baseQuery(for: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.corruptPayload }
            guard let stored = try? JSONDecoder().decode(StoredSecret.self, from: data) else {
                throw Failure.corruptPayload
            }
            return stored.secret
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    func delete(_ reference: SecretReference) async throws {
        let status = SecItemDelete(baseQuery(for: reference) as CFDictionary)
        // Deleting something that is not there is the state the caller wanted.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }

    func allReferences() async throws -> [SecretReference] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        query[kSecReturnData as String] = false

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            let attributes = items as? [[String: Any]] ?? []
            return attributes
                .compactMap { $0[kSecAttrAccount as String] as? String }
                .map(SecretReference.init(rawValue:))
        case errSecItemNotFound:
            return []
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    // MARK: - Helpers

    private func baseQuery(for reference: SecretReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
        ]
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
            return .privateKey(openSSH: SecretString(value), passphrase: passphrase.map(SecretString.init))
        }
    }
}
