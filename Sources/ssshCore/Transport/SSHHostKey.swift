import Foundation

/// A host key as presented by a server during the handshake.
///
/// `wireFormat` is the SSH wire encoding (the same bytes that appear
/// base64-encoded in `known_hosts`), which is what trust decisions compare —
/// fingerprints are for humans. Fingerprint strings are computed by the
/// transport backend, which has a crypto implementation; `ssshCore` stays free
/// of one so that it can be built and reasoned about on its own.
public struct SSHHostKey: Hashable, Sendable {
    /// e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`, `rsa-sha2-512`.
    public var algorithm: String
    public var wireFormat: [UInt8]
    /// OpenSSH's `SHA256:<base64 without padding>` form, or `nil` if it has not
    /// been computed yet (e.g. an entry just parsed out of a `known_hosts` file).
    public var sha256Fingerprint: String?

    public init(algorithm: String, wireFormat: [UInt8], sha256Fingerprint: String? = nil) {
        self.algorithm = algorithm
        self.wireFormat = wireFormat
        self.sha256Fingerprint = sha256Fingerprint
    }

    /// Trust identity: two keys are the same key when their wire bytes match.
    /// The fingerprint is excluded so a stored entry without a cached
    /// fingerprint still compares equal to the live one.
    public static func == (lhs: SSHHostKey, rhs: SSHHostKey) -> Bool {
        lhs.algorithm == rhs.algorithm && lhs.wireFormat == rhs.wireFormat
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(algorithm)
        hasher.combine(wireFormat)
    }

    /// `known_hosts` line body: `<algorithm> <base64 wire format>`.
    public var authorizedKeyRepresentation: String {
        "\(algorithm) \(Data(wireFormat).base64EncodedString())"
    }

    public var displayFingerprint: String {
        sha256Fingerprint ?? authorizedKeyRepresentation
    }
}

/// What the user (or a policy) decided about a host key.
public enum SSHHostKeyDecision: Sendable {
    /// Accept for this connection only; do not write it to the trust store.
    case trustOnce
    /// Accept and remember, so the next connection is silent.
    case trustAndRemember
    /// Refuse. The handshake fails and the connection is torn down.
    case reject
}

/// Why the transport is asking about a host key.
public enum SSHHostKeyPrompt: Sendable {
    /// No key is stored for this endpoint yet.
    case unknownHost(SSHEndpoint, SSHHostKey)
    /// A key *is* stored and it does not match. This is the loud case: it is
    /// what a man-in-the-middle looks like.
    case mismatch(SSHEndpoint, presented: SSHHostKey, trusted: [SSHHostKey])
}

/// Decides whether to trust a host key. The app implements this by prompting;
/// tests and the spike harness implement it non-interactively.
///
/// The transport **fails closed**: a verifier that throws, or returns
/// `.reject`, aborts the handshake, and so does a verifier that never answers
/// within the connect timeout.
public protocol SSHHostKeyVerifier: Sendable {
    func evaluate(_ prompt: SSHHostKeyPrompt) async -> SSHHostKeyDecision
}

/// Persisted host-key trust. Backed by SwiftData in the app (and synced via
/// CloudKit — fingerprints are not secrets, so trust follows the user), and by
/// a plain dictionary in tests.
public protocol SSHKnownHostsStore: Sendable {
    /// All keys currently trusted for `endpoint`. A host legitimately offers
    /// several (one per algorithm), so this is a list.
    func trustedKeys(for endpoint: SSHEndpoint) async -> [SSHHostKey]
    func remember(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws
    func forget(_ key: SSHHostKey, for endpoint: SSHEndpoint) async throws
}

/// The standard policy: trust what is stored, ask about what is not, and refuse
/// a mismatch unless the user explicitly overrides it.
///
/// Note the asymmetry — `.unknownHost` is a routine first connection, while
/// `.mismatch` is a security event. Both are routed to the verifier, but the
/// verifier is told which it is so the UI can be quiet about one and shout
/// about the other.
public struct SSHKnownHostsPolicy: Sendable {
    private let store: any SSHKnownHostsStore
    private let verifier: any SSHHostKeyVerifier

    public init(store: any SSHKnownHostsStore, verifier: any SSHHostKeyVerifier) {
        self.store = store
        self.verifier = verifier
    }

    /// - Returns: `true` when the handshake may continue.
    public func validate(_ presented: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool {
        let trusted = await store.trustedKeys(for: endpoint)

        if trusted.contains(presented) {
            return true
        }

        let prompt: SSHHostKeyPrompt = trusted.isEmpty
            ? .unknownHost(endpoint, presented)
            : .mismatch(endpoint, presented: presented, trusted: trusted)

        switch await verifier.evaluate(prompt) {
        case .reject:
            return false
        case .trustOnce:
            return true
        case .trustAndRemember:
            // A failure to persist must not silently downgrade to "trusted
            // once": the user asked for this to be remembered, and a store
            // that cannot record it is a bug worth surfacing next connection.
            try? await store.remember(presented, for: endpoint)
            return true
        }
    }
}

/// Refuses every key it has not been told about. Used as the default so that a
/// forgotten wiring step fails closed rather than trusting everything.
public struct RejectingHostKeyVerifier: SSHHostKeyVerifier {
    public init() {}
    public func evaluate(_ prompt: SSHHostKeyPrompt) async -> SSHHostKeyDecision { .reject }
}
