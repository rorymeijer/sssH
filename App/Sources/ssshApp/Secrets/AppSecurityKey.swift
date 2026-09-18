import CryptoKit
import Foundation
import Security

/// The device key every stored secret is wrapped with.
///
/// ## What this adds, and what it does not
///
/// The Keychain already protects an item at rest. This adds a second lock
/// whose key cannot be extracted at all: a P-256 key generated inside the
/// Secure Enclave, which can perform key agreement but can never be read out,
/// by this app or by anything else. A Keychain database lifted off a backup,
/// or read by a process that has somehow obtained the app's entitlements, is
/// still ciphertext without the Enclave that made the key.
///
/// It is **not** protection against someone using this app on an unlocked
/// device. That is what the app lock is for, and the two are different
/// problems.
///
/// ## When there is no Secure Enclave
///
/// Intel Macs without a T2 have none. The fallback is a software P-256 key
/// stored in the Keychain as `ThisDeviceOnly` — which is meaningfully weaker,
/// because that key *can* be read by anything that can read the Keychain. The
/// difference is reported rather than papered over: ``protection`` says which
/// one is in use, and the settings screen shows it.
///
/// ## Why not sealed with a symmetric key
///
/// The Enclave only holds P-256 keys, so the scheme is the standard one: a
/// fresh ephemeral key per secret, ECDH against the device key, HKDF to an
/// AES-GCM key. The ephemeral public key travels with the ciphertext. Nothing
/// here is novel, which is the point.
actor AppSecurityKey {
    enum Protection: String, Sendable {
        case secureEnclave
        case softwareKey

        var isHardwareBacked: Bool { self == .secureEnclave }
    }

    enum Failure: Error, LocalizedError {
        case keyUnavailable(String)
        case sealFailed(String)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .keyUnavailable(let detail): return detail
            case .sealFailed(let detail): return detail
            case .openFailed(let detail): return detail
            }
        }
    }

    /// A wrapped payload: the ephemeral public key that was agreed against,
    /// and the sealed box.
    struct Wrapped: Codable {
        var ephemeralPublicKey: Data
        var sealedBox: Data
    }

    private enum StoredKey {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)

        var publicKey: P256.KeyAgreement.PublicKey {
            switch self {
            case .enclave(let key): return key.publicKey
            case .software(let key): return key.publicKey
            }
        }

        func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            switch self {
            case .enclave(let key): return try key.sharedSecretFromKeyAgreement(with: ephemeral)
            case .software(let key): return try key.sharedSecretFromKeyAgreement(with: ephemeral)
            }
        }
    }

    private let service: String
    private let account: String
    private var loaded: StoredKey?
    private(set) var protection: Protection = .softwareKey

    init(service: String = "nl.rorymeijer.sssh.appkey", account: String = "device-key") {
        self.service = service
        self.account = account
    }

    /// Which protection is actually in use, loading or creating the key if
    /// needed.
    func currentProtection() throws -> Protection {
        _ = try key()
        return protection
    }

    // MARK: - Sealing

    func seal(_ plaintext: Data) throws -> Data {
        let deviceKey = try key()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try deviceKey.sharedSecret(with: ephemeral.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Self.salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )

        do {
            let box = try AES.GCM.seal(plaintext, using: symmetric)
            guard let combined = box.combined else {
                throw Failure.sealFailed("the sealed box could not be serialised")
            }
            let wrapped = Wrapped(
                ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                sealedBox: combined
            )
            return try JSONEncoder().encode(wrapped)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.sealFailed(String(describing: error))
        }
    }

    func open(_ wrapped: Data) throws -> Data {
        let deviceKey = try key()
        do {
            let envelope = try JSONDecoder().decode(Wrapped.self, from: wrapped)
            let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey)
            let shared = try deviceKey.sharedSecret(with: ephemeral)
            let symmetric = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Self.salt,
                sharedInfo: Data(),
                outputByteCount: 32
            )
            let box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
            return try AES.GCM.open(box, using: symmetric)
        } catch {
            // Deliberately one error for every cause. Which part of an
            // unwrapping failed is information about the key material, and
            // there is nothing a caller can usefully do differently.
            throw Failure.openFailed(String(describing: error))
        }
    }

    /// Fixed, and public in the sense that it is in the source: HKDF's salt is
    /// domain separation, not a secret, and a random one would have to be
    /// stored alongside the ciphertext for no benefit.
    private static let salt = Data("nl.rorymeijer.sssh.appkey.v1".utf8)

    // MARK: - The key itself

    private func key() throws -> StoredKey {
        if let loaded { return loaded }

        if let data = try storedRepresentation() {
            let key = try restore(from: data)
            loaded = key
            return key
        }

        let key = try create()
        loaded = key
        return key
    }

    private func restore(from data: Data) throws -> StoredKey {
        // An Enclave key's representation is an opaque blob that only the
        // Enclave can use; a software key's is the scalar. Trying the Enclave
        // first and falling back is how a key survives the device it was made
        // on being a different kind of device from the one reading it — which
        // happens when a Keychain is restored to new hardware.
        if SecureEnclave.isAvailable,
           let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data) {
            protection = .secureEnclave
            return .enclave(key)
        }
        guard let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            throw Failure.keyUnavailable("the stored device key could not be read")
        }
        protection = .softwareKey
        return .software(key)
    }

    private func create() throws -> StoredKey {
        if SecureEnclave.isAvailable {
            do {
                let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
                try store(key.dataRepresentation)
                protection = .secureEnclave
                return .enclave(key)
            } catch {
                // Fall through. An Enclave that exists and refuses is rare and
                // is not a reason to leave the app unable to store anything.
            }
        }

        let key = P256.KeyAgreement.PrivateKey()
        try store(key.rawRepresentation)
        protection = .softwareKey
        return .software(key)
    }

    // MARK: - Keychain

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func storedRepresentation() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.keyUnavailable("the device key could not be read (\(status))")
        }
    }

    private func store(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        // The device key never syncs and never leaves. An Enclave key could
        // not anyway; the software fallback must not either, or the weaker
        // path would also be the more exposed one.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw Failure.keyUnavailable("the device key could not be replaced (\(updateStatus))")
            }
        default:
            throw Failure.keyUnavailable("the device key could not be stored (\(status))")
        }
    }
}
